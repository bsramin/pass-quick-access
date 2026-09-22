// SPDX-License-Identifier: GPL-3.0-only

import Foundation

/// What the extension asks the app for, and what comes back.
///
/// One request and one response per connection, then the socket closes. The
/// server holds no per-connection state that way, and a client that wedges
/// costs a thread and a read deadline rather than a session.
enum AutoFillWire {
    /// Bumped when a message changes shape. App and extension ship in one
    /// bundle and update together, but a partially replaced install is exactly
    /// the sort of thing that happens once and is then very hard to read from a
    /// crash, so the version is checked rather than assumed.
    static let version = 1

    /// A request frame is small by construction; a response carries a match list
    /// and is capped well above a large vault's worth of titles and usernames.
    static let maxRequestLength = 64 * 1024
    static let maxResponseLength = 8 * 1024 * 1024

    enum Failure: Error, Equatable {
        case tooLarge
        case malformed
        case unexpectedEOF
        case writeFailed
    }

    struct Request: Codable, Sendable {
        let version: Int
        /// Set when the extension has just taken the user through Touch ID, so
        /// the app can honour the same unlock the panel would.
        let authenticated: Bool
        let body: Body

        init(_ body: Body, authenticated: Bool = false) {
            self.version = AutoFillWire.version
            self.authenticated = authenticated
            self.body = body
        }

        enum Body: Codable, Sendable {
            /// Is the app there, is it unlocked, does it have an index yet.
            case status
            /// Logins for these services, or every login when the list is
            /// empty. The values are the service identifiers exactly as macOS
            /// gave them, a bare domain or a whole URL; reducing them to hosts
            /// is the app's job, so the matching rules live next to the index
            /// they are matched against rather than in two places.
            case matches(services: [String], kind: Kind)
            case password(recordIdentifier: String)
            case oneTimeCode(recordIdentifier: String)
        }

        enum Kind: String, Codable, Sendable {
            case password
            case oneTimeCode
        }
    }

    struct Response: Codable, Sendable {
        let version: Int
        let body: Body

        init(_ body: Body) {
            self.version = AutoFillWire.version
            self.body = body
        }

        enum Body: Codable, Sendable {
            case status(State)
            case matches([Candidate])
            /// The plaintext, travelling once and retained by neither side.
            case secret(String)
            case failure(Failure)
        }

        enum State: String, Codable, Sendable {
            case ready
            case indexing
            case locked
            case signedOut
        }

        /// Everything the extension needs to draw a row. No secret, and no more
        /// of the item than a list needs.
        struct Candidate: Codable, Sendable {
            let recordIdentifier: String
            let title: String
            let account: String?
            let vaultName: String?
            let hasOneTimeCode: Bool
            /// Whether this one matches the site that asked. The rest of the
            /// vault is sent too, under a heading, because a login saved
            /// against gmail.com is the one you want on a google.com form and
            /// no matching rule is ever going to know that. It also makes the
            /// search field honest: it can only filter what was sent.
            let matchesSite: Bool
        }

        enum Failure: String, Codable, Sendable {
            case unsupportedVersion
            case denied
            case locked
            case indexNotReady
            case signedOut
            case notFound
            case timedOut
            case unavailable
        }
    }

    // MARK: - Framing

    /// `uint32` big-endian length, then JSON. Length-prefixed rather than
    /// delimited because a secret may contain anything at all, newlines
    /// included.
    static func frame<T: Encodable>(_ message: T) throws -> Data {
        let payload = try JSONEncoder().encode(message)
        guard payload.count <= maxResponseLength else { throw Failure.tooLarge }
        var data = Data(capacity: payload.count + 4)
        let length = UInt32(payload.count)
        data.append(UInt8((length >> 24) & 0xff))
        data.append(UInt8((length >> 16) & 0xff))
        data.append(UInt8((length >> 8) & 0xff))
        data.append(UInt8(length & 0xff))
        data.append(payload)
        return data
    }

    /// Reads one frame from a blocking socket. Returns nil when the peer closed
    /// before sending anything, which is an ordinary way for a connection to
    /// end rather than an error.
    static func read<T: Decodable>(_ type: T.Type, from fd: Int32, limit: Int) throws -> T? {
        guard let header = try readExact(fd: fd, count: 4, allowEOFAtStart: true) else { return nil }
        let length = (Int(header[0]) << 24) | (Int(header[1]) << 16) | (Int(header[2]) << 8) | Int(header[3])
        guard length > 0, length <= limit else { throw Failure.tooLarge }
        guard let payload = try readExact(fd: fd, count: length, allowEOFAtStart: false) else {
            throw Failure.unexpectedEOF
        }
        do {
            return try JSONDecoder().decode(T.self, from: payload)
        } catch {
            throw Failure.malformed
        }
    }

    /// Reads exactly `count` bytes. A peer that closes having sent nothing is
    /// reported as nil when that is allowed; a partial frame always throws,
    /// since half a message is never something to act on.
    private static func readExact(fd: Int32, count: Int, allowEOFAtStart: Bool) throws -> Data? {
        var buffer = Data(count: count)
        var total = 0
        try buffer.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { throw Failure.malformed }
            while total < count {
                let read = Darwin.read(fd, base.advanced(by: total), count - total)
                if read == 0 {
                    if total == 0 && allowEOFAtStart { return }
                    throw Failure.unexpectedEOF
                }
                if read < 0 {
                    if errno == EINTR { continue }
                    throw Failure.unexpectedEOF
                }
                total += read
            }
        }
        return total == 0 ? nil : buffer
    }
}
