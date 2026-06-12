// SPDX-License-Identifier: GPL-3.0-only

import Darwin
import Foundation

/// Facts about the process on the other end of a proxy connection, used to label
/// the approval prompt and to spot non-interactive probes.
struct RequestingProgram: Sendable, Equatable {
    /// The name to show the user (the user-facing tool, e.g. "git", when `ssh`
    /// was spawned by it; otherwise the connecting process).
    let name: String
    /// The command line worth showing, e.g. "git fetch" or "ssh git@github.com".
    let command: String?
    /// Whether `command` should be displayed. False when we can't make sense of
    /// it, so the prompt stays clean.
    let showCommand: Bool
    /// The connecting process carried `-o BatchMode=yes`: a scripted probe that
    /// will time out before any prompt can be answered, so it must be denied fast.
    let batchMode: Bool

    static let unknown = RequestingProgram(
        name: "an unknown program", command: nil, showCommand: false, batchMode: false
    )
}

/// Raw, OS-sourced facts about a pid. Behind a protocol so tests can drive
/// `ProcessInspector` without spawning real processes.
struct PeerProcessInfo: Sendable, Equatable {
    let pid: pid_t
    let name: String
    let arguments: [String]
    let parentPID: pid_t
}

protocol PeerProcessInfoProviding: Sendable {
    func info(for pid: pid_t) -> PeerProcessInfo?
}

/// Derives an `RequestingProgram` from the connecting pid, walking one level up so a
/// `git`/`rsync` that spawned `ssh` is what the user sees named.
struct ProcessInspector: Sendable {
    private static let sshNames: Set<String> = ["ssh"]
    private static let wrapperNames: Set<String> = ["git", "git-remote-http", "rsync", "scp", "sftp", "hg", "jj"]
    private static let shellNames: Set<String> = ["sh", "bash", "zsh", "fish", "dash", "tcsh", "csh", "login"]

    let provider: PeerProcessInfoProviding

    init(provider: PeerProcessInfoProviding = SystemPeerProcessInfo()) {
        self.provider = provider
    }

    func identify(pid: pid_t) -> RequestingProgram {
        guard let process = provider.info(for: pid) else { return .unknown }
        let batchMode = Self.isBatchMode(process.arguments)

        // When ssh was launched by a higher-level tool (git, rsync, …), name and
        // show that tool instead; it's what the user actually ran.
        if Self.sshNames.contains(process.name),
           let parent = provider.info(for: process.parentPID),
           Self.wrapperNames.contains(parent.name) {
            return RequestingProgram(
                name: parent.name,
                command: Self.cleanCommand(parent.arguments) ?? parent.name,
                showCommand: true,
                batchMode: batchMode
            )
        }

        let showable = !Self.shellNames.contains(process.name)
        return RequestingProgram(
            name: process.name,
            command: Self.cleanCommand(process.arguments),
            showCommand: showable,
            batchMode: batchMode
        )
    }

    /// True if the argument list asks for `BatchMode=yes` in any of the forms ssh
    /// accepts (`-oBatchMode=yes`, `-o BatchMode=yes`, `-o BatchMode yes`).
    static func isBatchMode(_ arguments: [String]) -> Bool {
        let joined = arguments.joined(separator: " ").lowercased()
        guard joined.contains("batchmode") else { return false }
        return joined.contains("batchmode=yes") || joined.contains("batchmode yes")
    }

    /// A short, human command string: the program plus a couple of meaningful
    /// arguments, with option noise trimmed.
    private static func cleanCommand(_ arguments: [String]) -> String? {
        guard let program = arguments.first.map(lastPathComponent) else { return nil }
        let rest = arguments.dropFirst().filter { argument in
            // Drop flags and their inline values; keep destinations / subcommands.
            !argument.hasPrefix("-")
        }
        let shown = ([program] + rest.prefix(2)).joined(separator: " ")
        return shown.isEmpty ? program : shown
    }

    private static func lastPathComponent(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }
}

/// Reads process facts from the kernel: the connecting pid's executable name,
/// full argument vector (`KERN_PROCARGS2`) and parent pid (`kinfo_proc`).
struct SystemPeerProcessInfo: PeerProcessInfoProviding {
    /// The pid connected to `fd`, from `LOCAL_PEERPID`. Returns `nil` if the
    /// kernel won't vouch for a peer pid.
    static func peerPID(of fd: Int32) -> pid_t? {
        var pid: pid_t = -1
        var length = socklen_t(MemoryLayout<pid_t>.size)
        let result = getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &length)
        guard result == 0, pid > 0 else { return nil }
        return pid
    }

    func info(for pid: pid_t) -> PeerProcessInfo? {
        guard pid > 0 else { return nil }
        let arguments = Self.arguments(of: pid)
        let name = Self.name(of: pid, fallbackArguments: arguments)
        return PeerProcessInfo(
            pid: pid,
            name: name,
            arguments: arguments,
            parentPID: Self.parentPID(of: pid) ?? 0
        )
    }

    private static func name(of pid: pid_t, fallbackArguments: [String]) -> String {
        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &pathBuffer, UInt32(MAXPATHLEN))
        if length > 0 {
            let path = String(cString: pathBuffer)
            return (path as NSString).lastPathComponent
        }
        return fallbackArguments.first.map { ($0 as NSString).lastPathComponent } ?? "process \(pid)"
    }

    private static func parentPID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let result = sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0)
        guard result == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }

    /// Parses `KERN_PROCARGS2`: a leading `argc`, the executable path, then the
    /// NUL-separated argv (and the environment, which we ignore).
    private static func arguments(of pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return [] }

        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, UInt32(mib.count), &buffer, &size, nil, 0) == 0 else { return [] }
        guard size >= MemoryLayout<Int32>.size else { return [] }

        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        var index = MemoryLayout<Int32>.size

        // Skip the executable path string, then the NULs padding to the first arg.
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }

        var arguments: [String] = []
        var current = [UInt8]()
        while index < size, arguments.count < Int(argc) {
            let byte = buffer[index]
            if byte == 0 {
                arguments.append(String(decoding: current, as: UTF8.self))
                current.removeAll(keepingCapacity: true)
            } else {
                current.append(byte)
            }
            index += 1
        }
        return arguments
    }
}
