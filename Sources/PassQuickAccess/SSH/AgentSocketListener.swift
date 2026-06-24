// SPDX-License-Identifier: GPL-3.0-only

import Foundation

/// Listens on the proxy's Unix socket and hands every accepted connection to a
/// callback. The listening socket is non-blocking and driven by a
/// `DispatchSource`; each accepted client fd is served on its own thread.
///
/// A thread per connection, rather than a shared concurrent `DispatchQueue`, is
/// deliberate. A connection is served by a blocking loop that can sit open for
/// the whole life of the ssh client (with `ForwardAgent` that's the entire
/// session) and can block on a Touch ID prompt. GCD's pool has a hard thread
/// ceiling, so once enough long-lived connections pile up it's exhausted and new
/// ones get accepted but never served, which surfaces as a "Permission denied
/// (publickey)" until the agent is toggled off and on. A dedicated thread sidesteps
/// the ceiling: a new connection is always served at once.
final class AgentSocketListener: @unchecked Sendable {
    private let path: String
    private let onAccept: @Sendable (Int32) -> Void
    private let acceptQueue = DispatchQueue(label: "it.ramin.PassQuickAccess.ssh.accept")
    private var listenFD: Int32 = -1
    private var source: DispatchSourceRead?

    init(path: String, onAccept: @escaping @Sendable (Int32) -> Void) {
        self.path = path
        self.onAccept = onAccept
    }

    func start() throws {
        let fd = try UnixSocket.listen(at: path)
        // Non-blocking, so the accept loop can drain every pending connection per
        // readiness event without blocking on the next accept.
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)
        listenFD = fd

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: acceptQueue)
        let onAccept = self.onAccept
        source.setEventHandler {
            while true {
                let clientFD = accept(fd, nil, nil)
                if clientFD < 0 { break }
                // Accepted sockets inherit the listener's O_NONBLOCK on macOS; the
                // per-connection proxy uses blocking reads, so clear it or those
                // reads spuriously fail with EAGAIN between a client's messages.
                let flags = fcntl(clientFD, F_GETFL, 0)
                _ = fcntl(clientFD, F_SETFL, flags & ~O_NONBLOCK)
                let connection = Thread { onAccept(clientFD) }
                connection.name = "it.ramin.PassQuickAccess.ssh.connection"
                connection.start()
            }
        }
        source.setCancelHandler {
            close(fd)
        }
        self.source = source
        source.resume()
    }

    func stop() {
        source?.cancel()
        source = nil
        listenFD = -1
        try? FileManager.default.removeItem(atPath: UnixSocket.expand(path))
    }
}
