// SPDX-License-Identifier: GPL-3.0-only

import Foundation

/// The version `pass-cli --version` reports, and the one line that decides
/// whether this app can drive it.
///
/// The app follows one CLI rather than branching on versions: the output shape
/// of `item list` has gained and lost fields between minor releases, and
/// carrying a path for each of them means testing against a tool that isn't
/// ours. So an older CLI is sent off to update instead of being worked around.
struct PassCLIVersion: Comparable, CustomStringConvertible, Sendable {
    let major: Int
    let minor: Int
    let patch: Int

    /// The oldest CLI this app is built against. 2.5.0 is where login with
    /// credentials went away and the item content grew `autofill_urls`.
    static let minimum = PassCLIVersion(major: 2, minor: 5, patch: 0)

    static let downloadPage = URL(string: "https://github.com/protonpass/pass-cli/releases")!

    init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// Reads the version out of a line like `Proton Pass CLI 2.5.1 (84186e7)`.
    /// Nil when there is no `x.y.z` in it at all.
    init?(_ output: String) {
        let pattern = /(\d+)\.(\d+)\.(\d+)/
        guard let match = output.firstMatch(of: pattern),
              let major = Int(match.1), let minor = Int(match.2), let patch = Int(match.3) else { return nil }
        self.init(major: major, minor: minor, patch: patch)
    }

    /// Whether what the CLI printed names a version older than this app drives.
    ///
    /// A banner that cannot be read counts as new enough. The prompt is better
    /// wrong in that direction: a CLI we cannot place still gets to run and
    /// fails on its own terms, where blocking would turn a reworded version
    /// line into an app that refuses to start.
    static func isTooOld(_ output: String) -> Bool {
        guard let version = PassCLIVersion(output) else { return false }
        return version < minimum
    }

    var description: String { "\(major).\(minor).\(patch)" }

    static func < (lhs: PassCLIVersion, rhs: PassCLIVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}
