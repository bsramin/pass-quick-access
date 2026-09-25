// SPDX-License-Identifier: GPL-3.0-only

import XCTest
@testable import PassQuickAccess

/// Covers the two ways a socket can take the app down with it: a path taken
/// from a process still serving it, and a write to a peer that has hung up.
final class UnixSocketTests: XCTestCase {
    private var path = ""

    override func setUp() {
        super.setUp()
        path = "/tmp/pqa-listen-\(UUID().uuidString.prefix(8)).sock"
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: path)
        super.tearDown()
    }

    func testRefusesToTakeOverASocketSomeoneIsServing() throws {
        let first = try UnixSocket.listen(at: path)
        defer { close(first) }
        let inode = UnixSocket.inode(at: path)

        XCTAssertThrowsError(try UnixSocket.listen(at: path)) { error in
            XCTAssertEqual(error as? UnixSocket.Failure, .alreadyInUse(path))
        }
        // Throwing after unlinking would be the same bug with an error message.
        XCTAssertEqual(UnixSocket.inode(at: path), inode)
        XCTAssertTrue(UnixSocket.isServed(at: path))
    }

    func testRebindsOverASocketNobodyIsServing() throws {
        let abandoned = try UnixSocket.listen(at: path)
        let inode = UnixSocket.inode(at: path)
        // What a process that died without cleaning up leaves behind.
        close(abandoned)
        XCTAssertFalse(UnixSocket.isServed(at: path))

        let second = try UnixSocket.listen(at: path)
        defer { close(second) }
        XCTAssertTrue(UnixSocket.isServed(at: path))
        XCTAssertNotEqual(UnixSocket.inode(at: path), inode)
    }

    func testBindsWhenNothingIsThere() throws {
        let fd = try UnixSocket.listen(at: path)
        defer { close(fd) }
        XCTAssertTrue(UnixSocket.isServed(at: path))
    }

    /// Asserted through the socket option rather than by provoking the signal:
    /// XCTest's own process already ignores SIGPIPE, so provoking it here would
    /// pass whether or not the app is protected.
    func testEveryConnectionIsProtectedFromSIGPIPE() throws {
        let listenFD = try UnixSocket.listen(at: path)
        defer { close(listenFD) }
        XCTAssertTrue(Self.ignoresBrokenPipe(listenFD), "the listening socket")

        let client = try UnixSocket.connect(to: path)
        defer { close(client) }
        XCTAssertTrue(Self.ignoresBrokenPipe(client), "the connecting side")

        let served = accept(listenFD, nil, nil)
        XCTAssertGreaterThanOrEqual(served, 0)
        defer { close(served) }
        // Inherited, which is why the accept loop doesn't set it per connection.
        XCTAssertTrue(Self.ignoresBrokenPipe(served), "the accepted connection")
    }

    private static func ignoresBrokenPipe(_ fd: Int32) -> Bool {
        var value: Int32 = 0
        var size = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &value, &size) == 0 else { return false }
        return value != 0
    }

    func testWritingToAHungUpPeerReportsFailure() throws {
        let listenFD = try UnixSocket.listen(at: path)
        defer { close(listenFD) }
        let client = try UnixSocket.connect(to: path)
        let served = accept(listenFD, nil, nil)
        XCTAssertGreaterThanOrEqual(served, 0)
        defer { close(served) }

        close(client)

        // The first write lands in the buffer of an already closed socket, which
        // is what makes the kernel send the reset the second one trips over.
        let payload = Data(repeating: 0x41, count: 1024)
        _ = UnixSocket.writeAll(payload, to: served)
        XCTAssertFalse(
            UnixSocket.writeAll(payload, to: served),
            "a write to a hung-up peer should report failure"
        )
    }

    /// The same theft from the other end: `stop` must not delete a file another
    /// process put in its place.
    func testRemovesOnlyTheSocketItBound() throws {
        let first = try UnixSocket.listen(at: path)
        let inode = UnixSocket.inode(at: path)
        close(first)
        try? FileManager.default.removeItem(atPath: path)

        let replacement = try UnixSocket.listen(at: path)
        defer { close(replacement) }

        UnixSocket.removeSocket(at: path, ifInode: inode)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: path),
            "the replacement socket was deleted by the listener that no longer owns the path"
        )

        UnixSocket.removeSocket(at: path, ifInode: UnixSocket.inode(at: path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }
}
