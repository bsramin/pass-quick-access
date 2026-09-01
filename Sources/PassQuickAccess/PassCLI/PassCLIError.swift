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
        // Specific phrases only: a bare "session" match swept in transient,
        // non-auth errors (a refresh blip, a daemon message) and turned them into
        // a spurious signed-out prompt. A real lost session says one of these.
        return message.contains("not logged in")
            || message.contains("no session")
            || message.contains("session expired")
            || message.contains("session has expired")
            || message.contains("invalid session")
            || message.contains("authenticated client")
            || message.contains("unauthorized")
            || message.contains("log in")
    }

    /// True when the command failed because pass-cli could not reach Proton
    /// rather than because anything was wrong with the request: a timeout, or a
    /// network or server error it reported. Worth its own message, since the
    /// only thing the user can do about it is try again later.
    var isServiceUnreachable: Bool {
        if case .timedOut = self { return true }
        guard case let .commandFailed(_, stderr) = self else { return false }
        let message = stderr.lowercased()
        return message.contains("connection")
            || message.contains("timed out")
            || message.contains("timeout")
            || message.contains("network")
            || message.contains("could not resolve")
            || message.contains("dns error")
            || message.contains("temporarily unavailable")
            || message.contains("service unavailable")
            || message.contains("bad gateway")
            || message.contains("502")
            || message.contains("503")
    }

    /// True when the CLI refused the command itself rather than failing to carry
    /// it out, which is what a subcommand dropped by a newer pass-cli looks like
    /// from here. It says nothing about the session, so callers must not read it
    /// as a lapsed one.
    var isUnsupportedCommand: Bool {
        guard case let .commandFailed(_, stderr) = self else { return false }
        let message = stderr.lowercased()
        return message.contains("unrecognized subcommand")
            || message.contains("unexpected argument")
            || message.contains("unknown command")
    }

    /// True when a command failed because the locally stored session can't be
    /// decrypted (its key is missing or changed). A forced logout clears it.
    var isCorruptLocalSession: Bool {
        guard case let .commandFailed(_, stderr) = self else { return false }
        let message = stderr.lowercased()
        return (message.contains("decrypting") && message.contains("session"))
            || message.contains("removed your local key")
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
