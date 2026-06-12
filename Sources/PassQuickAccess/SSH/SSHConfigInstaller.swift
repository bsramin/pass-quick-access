// SPDX-License-Identifier: GPL-3.0-only

import Foundation

/// Manages a small, clearly marked block in `~/.ssh/config` that points ssh and
/// git at the proxy, so the user doesn't have to edit the file by hand. The block
/// is written at the top because ssh takes the first `IdentityAgent` it sees.
enum SSHConfigInstaller {
    private static let beginMarker = "# BEGIN Pass Quick Access"
    private static let endMarker = "# END Pass Quick Access"

    static func defaultConfigURL() -> URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".ssh/config")
    }

    static func managedBlock(socketPath: String = UnixSocket.defaultProxyPath) -> String {
        """
        \(beginMarker)
        Host *
            IdentityAgent \(socketPath)
        \(endMarker)
        """
    }

    static func isInstalled(at url: URL = defaultConfigURL()) -> Bool {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return false }
        return contents.contains(beginMarker)
    }

    /// Adds or refreshes the managed block, leaving everything else untouched.
    static func install(at url: URL = defaultConfigURL(), socketPath: String = UnixSocket.defaultProxyPath) throws {
        try ensureSSHDirectory(for: url)
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let withoutBlock = stripBlock(from: existing)
        let separator = withoutBlock.isEmpty ? "" : "\n\n"
        let updated = managedBlock(socketPath: socketPath) + separator + withoutBlock
        try write(updated, to: url)
    }

    /// Removes the managed block, leaving the rest of the file as it was.
    static func uninstall(at url: URL = defaultConfigURL()) throws {
        guard let existing = try? String(contentsOf: url, encoding: .utf8) else { return }
        try write(stripBlock(from: existing), to: url)
    }

    /// Drops the marked block (and the blank line that followed it) from `text`.
    private static func stripBlock(from text: String) -> String {
        guard let begin = text.range(of: beginMarker),
              let end = text.range(of: endMarker, range: begin.upperBound..<text.endIndex)
        else { return text }

        var trailing = end.upperBound
        while trailing < text.endIndex, text[trailing] == "\n" {
            trailing = text.index(after: trailing)
        }
        var result = text
        result.removeSubrange(begin.lowerBound..<trailing)
        return result
    }

    private static func ensureSSHDirectory(for url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    private static func write(_ contents: String, to url: URL) throws {
        let normalized = contents.hasSuffix("\n") || contents.isEmpty ? contents : contents + "\n"
        try normalized.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
