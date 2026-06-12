// SPDX-License-Identifier: GPL-3.0-only

import Foundation

/// Listens on the proxy's Unix socket and hands every accepted connection to a
/// callback. The listening socket is non-blocking and driven by a
/// `DispatchSource`; each accepted client fd is processed on a concurrent queue
/// so one slow signature prompt can't stall other connections.
final class AgentSocketListener: @unchecked Sendable {
    private let path: String
    private let onAccept: @Sendable (Int32) -> Void
    private let acceptQueue = DispatchQueue(label: "it.ramin.PassQuickAccess.ssh.accept")
    private let workQueue = DispatchQueue(
        label: "it.ramin.PassQuickAccess.ssh.connections", attributes: .concurrent
    )
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
        let workQueue = self.workQueue
        source.setEventHandler {
            while true {
                let clientFD = accept(fd, nil, nil)
                if clientFD < 0 { break }
                // Accepted sockets inherit the listener's O_NONBLOCK on macOS; the
                // per-connection proxy uses blocking reads, so clear it or those
                // reads spuriously fail with EAGAIN between a client's messages.
                let flags = fcntl(clientFD, F_GETFL, 0)
                _ = fcntl(clientFD, F_SETFL, flags & ~O_NONBLOCK)
                workQueue.async { onAccept(clientFD) }
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
