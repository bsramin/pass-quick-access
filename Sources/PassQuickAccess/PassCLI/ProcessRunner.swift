// SPDX-License-Identifier: GPL-3.0-only

import Foundation

struct ProcessResult: Sendable {
    let status: Int32
    let stdout: Data
    let stderr: Data
}

/// Abstraction over spawning a child process, so `PassCLIClient` can be driven
/// by a fake in tests instead of touching the real `pass-cli` binary.
protocol ProcessRunning: Sendable {
    func run(executable: URL, arguments: [String], timeout: Duration) async throws -> ProcessResult
}

/// Runs the process for real. Output is captured through temporary files rather
/// than pipes to avoid the classic 64 KB pipe-buffer deadlock when a vault
/// listing is large.
struct SystemProcessRunner: ProcessRunning {
    func run(executable: URL, arguments: [String], timeout: Duration) async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result {
                    try Self.runSynchronously(executable: executable, arguments: arguments, timeout: timeout)
                })
            }
        }
    }

    private static func runSynchronously(
        executable: URL,
        arguments: [String],
        timeout: Duration
    ) throws -> ProcessResult {
        let fileManager = FileManager.default
        let outputURL = temporaryFileURL()
        let errorURL = temporaryFileURL()
        fileManager.createFile(atPath: outputURL.path, contents: nil)
        fileManager.createFile(atPath: errorURL.path, contents: nil)
        defer {
            try? fileManager.removeItem(at: outputURL)
            try? fileManager.removeItem(at: errorURL)
        }

        let outputHandle = try FileHandle(forWritingTo: outputURL)
        let errorHandle = try FileHandle(forWritingTo: errorURL)

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = outputHandle
        process.standardError = errorHandle

        do {
            try process.run()
        } catch {
            throw PassCLIError.launchFailed(underlying: error)
        }

        let deadline = Date().addingTimeInterval(timeout.seconds)
        var didTimeOut = false
        while process.isRunning {
            if Date() >= deadline {
                process.terminate()
                didTimeOut = true
                break
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        process.waitUntilExit()
        try? outputHandle.close()
        try? errorHandle.close()

        if didTimeOut {
            throw PassCLIError.timedOut
        }

        return ProcessResult(
            status: process.terminationStatus,
            stdout: (try? Data(contentsOf: outputURL)) ?? Data(),
            stderr: (try? Data(contentsOf: errorURL)) ?? Data()
        )
    }

    private static func temporaryFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("pass-quick-access-" + UUID().uuidString)
    }
}

private extension Duration {
    var seconds: TimeInterval {
        let (seconds, attoseconds) = components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
}
