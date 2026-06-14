// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import Foundation

/// Runs Proton's web login without a terminal. `pass-cli login` is a browser-based
/// flow: it prints an auth URL and waits on a local callback while the user signs
/// in. Run headless, it doesn't open the browser itself, so this spawns it as a
/// child, plucks the URL from its output, and opens it directly. Session arrival
/// is detected separately by `SessionRecovery` polling.
@MainActor
final class WebLogin {
    private let executable: URL
    private var process: Process?
    private var readHandle: FileHandle?

    init(executable: URL) {
        self.executable = executable
    }

    /// Starts the login and opens the auth URL in the browser when it appears.
    func start() {
        cancel()

        let process = Process()
        process.executableURL = executable
        process.arguments = ["login"]
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        let pipe = Pipe()
        process.standardOutput = pipe
        let readHandle = pipe.fileHandleForReading

        let scanner = URLScanner()
        readHandle.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil  // process closed its output
                return
            }
            if let url = scanner.appendAndFindURL(data) {
                Task { @MainActor in NSWorkspace.shared.open(url) }
            }
        }

        do {
            try process.run()
            self.process = process
            self.readHandle = readHandle
        } catch {
            readHandle.readabilityHandler = nil
        }
    }

    /// Stops a login in progress (cancel or timeout). Clearing the read handler
    /// first makes sure a late read can't open the browser after a cancel.
    func cancel() {
        readHandle?.readabilityHandler = nil
        readHandle = nil
        process?.terminate()
        process = nil
    }
}

/// Accumulates the login's output and extracts the first complete `https://` URL.
/// Thread-safe: the pipe's read handler runs off the main thread.
private final class URLScanner: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""
    private var found = false

    func appendAndFindURL(_ data: Data) -> URL? {
        lock.withLock {
            guard !found else { return nil }
            text += String(decoding: data, as: UTF8.self)
            guard let start = text.range(of: "https://")?.lowerBound else { return nil }
            let tail = text[start...]
            // Wait for whitespace after the URL so a split read can't truncate it.
            guard let end = tail.firstIndex(where: { $0.isWhitespace }) else { return nil }
            guard let url = URL(string: String(tail[tail.startIndex..<end])) else { return nil }
            found = true
            return url
        }
    }
}
