// SPDX-License-Identifier: GPL-3.0-only

import Foundation

/// POSIX Unix-domain socket helpers for the SSH agent proxy. `Network.framework`
/// can't bind a listening socket at an arbitrary filesystem path, so the proxy
/// uses raw BSD sockets and blocking I/O on background queues.
enum UnixSocket {
    /// Default path of the proxy socket clients point `IdentityAgent` at.
    static let defaultProxyPath = "~/.ssh/pass-quick-access-agent.sock"
    /// Default path of the upstream agent run by `pass-cli`.
    static let defaultUpstreamPath = "~/.ssh/proton-pass-agent.sock"

    /// `sun_path` is a fixed 104-byte field on macOS; a path must leave room for
    /// the trailing NUL.
    static let maxPathLength = 104

    enum Failure: Error, Equatable {
        case pathTooLong(String)
        case socketCreateFailed(Int32)
        case bindFailed(Int32)
        case listenFailed(Int32)
        case connectFailed(Int32)
    }

    /// Expands a leading `~` to the user's home directory.
    static func expand(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    /// Creates, binds and listens on a Unix socket at `path`. Any stale socket
    /// file is removed first, and the new socket is created with `0600`
    /// permissions so only the user can reach it. Returns the listening fd.
    static func listen(at path: String, backlog: Int32 = 16) throws -> Int32 {
        let expanded = expand(path)
        guard expanded.utf8.count < maxPathLength else { throw Failure.pathTooLong(expanded) }

        try? FileManager.default.removeItem(atPath: expanded)
        let parent = (expanded as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: parent, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.socketCreateFailed(errno) }

        // Restrict the socket to the owner before it accepts a single connection.
        let previousMask = umask(0o077)
        defer { umask(previousMask) }

        var addr = makeAddr(path: expanded)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            let err = errno
            close(fd)
            throw Failure.bindFailed(err)
        }
        chmod(expanded, 0o600)

        guard Darwin.listen(fd, backlog) == 0 else {
            let err = errno
            close(fd)
            throw Failure.listenFailed(err)
        }
        return fd
    }

    /// Connects to the upstream Unix socket at `path`, returning the connected fd.
    static func connect(to path: String) throws -> Int32 {
        let expanded = expand(path)
        guard expanded.utf8.count < maxPathLength else { throw Failure.pathTooLong(expanded) }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.socketCreateFailed(errno) }

        var addr = makeAddr(path: expanded)
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            let err = errno
            close(fd)
            throw Failure.connectFailed(err)
        }
        return fd
    }

    /// Caps how long a blocking read on `fd` waits for data before failing with
    /// `EAGAIN`. Used on the upstream connection so a daemon that accepts the
    /// socket but never replies can't wedge a connection's thread forever; the
    /// stalled read surfaces as a read failure, which the relay treats as an
    /// upstream failure and heals from.
    static func setReadTimeout(_ seconds: TimeInterval, on fd: Int32) {
        var tv = timeval(tv_sec: Int(seconds), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    /// Writes all of `data` to `fd`, retrying short writes and `EINTR`.
    static func writeAll(_ data: Data, to fd: Int32) -> Bool {
        var ok = true
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var total = 0
            while total < data.count {
                let n = Darwin.write(fd, base.advanced(by: total), data.count - total)
                if n < 0 {
                    if errno == EINTR { continue }
                    ok = false
                    return
                }
                total += n
            }
        }
        return ok
    }

    private static func makeAddr(path: String) -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            path.withCString { cstr in
                memcpy(ptr, cstr, min(path.utf8.count + 1, maxPathLength))
            }
        }
        return addr
    }
}
