// SPDX-License-Identifier: GPL-3.0-only

import Foundation

/// Shows the build the way the user recognizes it from releases. The build
/// number is the date-based one the release job sets (so it climbs for Sparkle),
/// not the marketing version, which stays put.
enum ReleaseVersion {
    /// `20260619.3` becomes `2026-06-19.3`, matching the release tag. Anything
    /// that isn't a `YYYYMMDD.x` build (like a local build's `1`) is returned as
    /// is.
    static func display(_ build: String) -> String {
        let digits = build.prefix { $0 != "." }
        guard digits.count == 8, digits.allSatisfy(\.isNumber) else { return build }
        let year = digits.prefix(4)
        let month = digits.dropFirst(4).prefix(2)
        let day = digits.dropFirst(6).prefix(2)
        return "\(year)-\(month)-\(day)\(build.dropFirst(8))"
    }

    /// The running build, formatted for display.
    static var current: String {
        display(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "")
    }
}
