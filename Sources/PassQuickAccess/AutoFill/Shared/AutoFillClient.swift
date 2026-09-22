// SPDX-License-Identifier: GPL-3.0-only

import Foundation

/// The extension's end of the channel: one connection, one question, one answer.
///
/// Blocking by design. A credential provider is already being waited on by
/// whoever asked for the password, and the caller runs this off the main thread,
/// so there is nothing to be gained by making it asynchronous and a deadline is
/// what actually protects the user from a wedged app.
enum AutoFillClient {
    enum Failure: Error, Equatable {
        /// No socket, or nothing listening: the app isn't running.
        case unavailable
        /// Something is listening, but it isn't the app. Nothing is sent.
        case untrustedServer
        case transport
        case unsupportedVersion
    }

    /// Longer than the app's own deadline for reading a field (8 seconds), so a
    /// slow Proton Pass surfaces as the app's own "try again" rather than as a
    /// severed connection here.
    static let defaultTimeout: TimeInterval = 12

    static func send(
        _ request: AutoFillWire.Request,
        timeout: TimeInterval = defaultTimeout
    ) throws -> AutoFillWire.Response {
        guard let path = AutoFillChannel.socketPath else { throw Failure.unavailable }
        guard let fd = try? UnixSocket.connect(to: path) else { throw Failure.unavailable }
        defer { close(fd) }

        // Check who answered before saying anything. A record identifier is not a
        // secret, but it names an item in the user's vault, and the socket is a
        // path on disk rather than a capability, so the peer is established
        // first and the request is written second.
        let peer = CodeSignatureCheck.verify(fd: fd)
        guard let expected = AutoFillChannel.expectedAppIdentity,
              peer.identity == expected else { throw Failure.untrustedServer }

        UnixSocket.setReadTimeout(timeout, on: fd)
        guard let frame = try? AutoFillWire.frame(request),
              UnixSocket.writeAll(frame, to: fd) else { throw Failure.transport }

        let decoded: AutoFillWire.Response?
        do {
            decoded = try AutoFillWire.read(
                AutoFillWire.Response.self, from: fd, limit: AutoFillWire.maxResponseLength
            )
        } catch {
            throw Failure.transport
        }
        // Nil means the app closed without answering, which reads the same from
        // here as a connection that broke: either way there is nothing to fill.
        guard let response = decoded else { throw Failure.transport }
        guard response.version == AutoFillWire.version else { throw Failure.unsupportedVersion }
        return response
    }
}
