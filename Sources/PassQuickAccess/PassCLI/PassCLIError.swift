// SPDX-License-Identifier: GPL-3.0-only

import Foundation

enum PassCLIError: Error {
    /// The `pass-cli` executable could not be found on disk.
    case executableNotFound
    /// The process could not be spawned (e.g. permissions, bad path).
    case launchFailed(underlying: Error)
    /// The command did not finish within its deadline and was terminated.
    case timedOut
    /// The command exited non-zero. `stderr` carries the CLI's own message.
    case commandFailed(status: Int32, stderr: String)
    /// JSON returned by the CLI did not match the expected shape.
    case malformedOutput(underlying: Error)
    /// The CLI ran successfully but the requested value was empty.
    case emptyValue
}

extension PassCLIError {
    /// True when the failure looks like a missing or expired session rather
    /// than a malformed request, so the caller should prompt for `pass-cli login`.
    var isAuthenticationFailure: Bool {
        guard case let .commandFailed(_, stderr) = self else { return false }
        let message = stderr.lowercased()
        return message.contains("not logged in")
            || message.contains("session")
            || message.contains("unauthorized")
            || message.contains("log in")
    }
}

extension PassCLIError: CustomStringConvertible {
    var description: String {
        switch self {
        case .executableNotFound:
            return "pass-cli was not found. Install it from https://github.com/protonpass/pass-cli."
        case let .launchFailed(underlying):
            return "Could not start pass-cli: \(underlying.localizedDescription)"
        case .timedOut:
            return "pass-cli did not respond in time."
        case let .commandFailed(status, stderr):
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty ? "pass-cli exited with status \(status)." : detail
        case let .malformedOutput(underlying):
            return "Unexpected response from pass-cli: \(underlying.localizedDescription)"
        case .emptyValue:
            return "pass-cli returned no value for the requested field."
        }
    }
}
