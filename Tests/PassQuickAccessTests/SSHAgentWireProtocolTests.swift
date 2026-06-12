// SPDX-License-Identifier: GPL-3.0-only

import XCTest
@testable import PassQuickAccess

final class SSHAgentWireProtocolTests: XCTestCase {
    private func sshString(_ bytes: [UInt8]) -> Data {
        var data = Data()
        data.appendBigEndianUInt32(UInt32(bytes.count))
        data.append(contentsOf: bytes)
        return data
    }

    func testEncodingPrefixesLengthAndType() {
        let message = AgentMessage(type: .signRequest, payload: Data([0xaa, 0xbb]))
        let encoded = message.encoded()
        // length = type byte + 2 payload bytes = 3
        XCTAssertEqual(Array(encoded), [0, 0, 0, 3, AgentMessageType.signRequest.rawValue, 0xaa, 0xbb])
    }

    func testReadRoundTripsThroughAPipeAndReportsEOF() throws {
        var fds = [Int32](repeating: 0, count: 2)
        XCTAssertEqual(pipe(&fds), 0)
        let original = AgentMessage(type: .requestIdentities, payload: Data([1, 2, 3, 4]))
        XCTAssertTrue(UnixSocket.writeAll(original.encoded(), to: fds[1]))
        close(fds[1])

        let read = try AgentMessage.read(from: fds[0])
        XCTAssertEqual(read, original)
        // Second read sees a clean EOF.
        XCTAssertNil(try AgentMessage.read(from: fds[0]))
        close(fds[0])
    }

    func testUnknownTypeIsPreservedForLosslessForwarding() {
        let message = AgentMessage(rawType: 200, payload: Data([9]))
        XCTAssertNil(message.type)
        XCTAssertEqual(message.encoded(), Data([0, 0, 0, 2, 200, 9]))
    }

    func testSignRequestKeyBlobIsTheFirstString() {
        let blob: [UInt8] = [0xde, 0xad, 0xbe, 0xef]
        var payload = sshString(blob)
        payload.append(sshString([0x00]))          // data
        payload.appendBigEndianUInt32(0)            // flags
        let message = AgentMessage(type: .signRequest, payload: payload)
        XCTAssertEqual(message.signRequestKeyBlob.map(Array.init), blob)
    }

    func testIdentitiesAnswerParsesBlobsAndComments() {
        var payload = Data()
        payload.appendBigEndianUInt32(2)
        payload.append(sshString([0x01, 0x02]))
        payload.append(sshString(Array("alice".utf8)))
        payload.append(sshString([0x03]))
        payload.append(sshString(Array("bob".utf8)))

        let identities = SSHIdentitiesAnswer.parse(payload)
        XCTAssertEqual(identities.count, 2)
        XCTAssertEqual(Array(identities[0].keyBlob), [0x01, 0x02])
        XCTAssertEqual(identities[0].comment, "alice")
        XCTAssertEqual(identities[1].comment, "bob")
    }

    func testOversizedLengthIsRejected() throws {
        var fds = [Int32](repeating: 0, count: 2)
        XCTAssertEqual(pipe(&fds), 0)
        var header = Data()
        header.appendBigEndianUInt32(AgentMessage.maxPayloadLength + 100)
        XCTAssertTrue(UnixSocket.writeAll(header, to: fds[1]))
        close(fds[1])
        XCTAssertThrowsError(try AgentMessage.read(from: fds[0])) { error in
            XCTAssertEqual(error as? AgentWireError, .messageTooLarge)
        }
        close(fds[0])
    }
}
