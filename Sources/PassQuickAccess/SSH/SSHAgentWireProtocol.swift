// SPDX-License-Identifier: GPL-3.0-only

import Foundation

/// SSH agent protocol message types we care about. Everything the proxy doesn't
/// need to inspect is forwarded byte-for-byte, so this only names the few types
/// that drive a decision. See RFC draft-miller-ssh-agent.
enum AgentMessageType: UInt8, Sendable {
    case failure = 5
    case success = 6
    case requestIdentities = 11
    case identitiesAnswer = 12
    case signRequest = 13
    case signResponse = 14
    case extensionRequest = 27
}

enum AgentWireError: Error, Equatable, Sendable {
    case messageTooShort
    case messageTooLarge
    case unexpectedEOF
}

/// One agent message in wire form: a 4-byte big-endian length, a 1-byte type,
/// then the payload. The raw type byte is preserved so messages of types we
/// don't model still forward losslessly.
struct AgentMessage: Sendable, Equatable {
    /// Cap on the payload length, matching what OpenSSH and the reference proxy
    /// accept (256 KB). Anything larger is treated as a protocol error.
    static let maxPayloadLength: UInt32 = 256 * 1024

    let rawType: UInt8
    let payload: Data

    init(rawType: UInt8, payload: Data = Data()) {
        self.rawType = rawType
        self.payload = payload
    }

    init(type: AgentMessageType, payload: Data = Data()) {
        self.init(rawType: type.rawValue, payload: payload)
    }

    /// The modelled type, or `nil` for a type we forward without inspecting.
    var type: AgentMessageType? { AgentMessageType(rawValue: rawType) }

    /// Wire encoding: `uint32 length | byte type | payload`, where length counts
    /// the type byte plus the payload.
    func encoded() -> Data {
        var data = Data()
        data.appendBigEndianUInt32(UInt32(payload.count) + 1)
        data.append(rawType)
        data.append(payload)
        return data
    }

    /// The extension name of an `extensionRequest`. The payload begins with a
    /// `string extension_type`.
    var extensionType: String? {
        payload.readLengthPrefixedString(at: 0).map { String(decoding: $0, as: UTF8.self) }
    }

    /// The key blob a sign request is about. The payload is
    /// `string key_blob | string data | uint32 flags`, and SSH strings are
    /// length-prefixed, so the blob is the first such string.
    var signRequestKeyBlob: Data? {
        payload.readLengthPrefixedString(at: 0)
    }

    /// Reads one full message from a blocking file descriptor. Returns `nil` on a
    /// clean EOF (peer closed between messages), and throws on a truncated or
    /// oversized message.
    static func read(from fd: Int32) throws -> AgentMessage? {
        guard let lengthData = try readExact(fd: fd, count: 4, allowEOFAtStart: true) else {
            return nil
        }
        let length = lengthData.readBigEndianUInt32(at: 0)
        guard length >= 1 else { throw AgentWireError.messageTooShort }
        guard length <= Self.maxPayloadLength + 1 else { throw AgentWireError.messageTooLarge }

        guard let body = try readExact(fd: fd, count: Int(length), allowEOFAtStart: false) else {
            throw AgentWireError.unexpectedEOF
        }
        let rawType = body[body.startIndex]
        let payload = body.count > 1 ? body.subdata(in: (body.startIndex + 1)..<body.endIndex) : Data()
        return AgentMessage(rawType: rawType, payload: payload)
    }

    /// Reads exactly `count` bytes. Returns `nil` if the peer closes with no bytes
    /// read and `allowEOFAtStart` is set; throws `unexpectedEOF` on a partial read.
    private static func readExact(fd: Int32, count: Int, allowEOFAtStart: Bool) throws -> Data? {
        var buffer = Data(count: count)
        var total = 0
        try buffer.withUnsafeMutableBytes { raw in
            let base = raw.baseAddress!
            while total < count {
                let n = Darwin.read(fd, base.advanced(by: total), count - total)
                if n == 0 {
                    if total == 0 && allowEOFAtStart { return }
                    throw AgentWireError.unexpectedEOF
                }
                if n < 0 {
                    if errno == EINTR { continue }
                    throw AgentWireError.unexpectedEOF
                }
                total += n
            }
        }
        return total == 0 ? nil : buffer
    }
}

/// Identities carried by an `identitiesAnswer`, parsed so the proxy can map a key
/// blob to its human comment for the approval prompt.
enum SSHIdentitiesAnswer {
    struct Identity: Sendable, Equatable {
        let keyBlob: Data
        let comment: String
    }

    /// Payload is `uint32 count` followed by `count` × (`string key_blob`,
    /// `string comment`). Returns the identities it can parse, stopping on the
    /// first malformed entry rather than throwing.
    static func parse(_ payload: Data) -> [Identity] {
        guard payload.count >= 4 else { return [] }
        let count = payload.readBigEndianUInt32(at: 0)
        var identities: [Identity] = []
        var offset = 4
        for _ in 0..<count {
            guard let blob = payload.readLengthPrefixedString(at: offset) else { break }
            offset += 4 + blob.count
            guard let commentData = payload.readLengthPrefixedString(at: offset) else { break }
            offset += 4 + commentData.count
            let comment = String(decoding: commentData, as: UTF8.self)
            identities.append(Identity(keyBlob: blob, comment: comment))
        }
        return identities
    }
}

extension Data {
    mutating func appendBigEndianUInt32(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xff))
        append(UInt8((value >> 16) & 0xff))
        append(UInt8((value >> 8) & 0xff))
        append(UInt8(value & 0xff))
    }

    /// Reads a big-endian `UInt32` at a byte offset relative to the start of the
    /// data. Returns 0 if it would read past the end.
    func readBigEndianUInt32(at offset: Int) -> UInt32 {
        let start = startIndex + offset
        guard start >= startIndex, start + 4 <= endIndex else { return 0 }
        return (UInt32(self[start]) << 24)
            | (UInt32(self[start + 1]) << 16)
            | (UInt32(self[start + 2]) << 8)
            | UInt32(self[start + 3])
    }

    /// Reads an SSH `string` (a `uint32` length followed by that many bytes) at a
    /// byte offset. Returns `nil` if the length runs past the end of the data.
    func readLengthPrefixedString(at offset: Int) -> Data? {
        guard offset >= 0, offset + 4 <= count else { return nil }
        let length = Int(readBigEndianUInt32(at: offset))
        let valueStart = offset + 4
        guard valueStart + length <= count else { return nil }
        let base = startIndex + valueStart
        return subdata(in: base..<(base + length))
    }
}
