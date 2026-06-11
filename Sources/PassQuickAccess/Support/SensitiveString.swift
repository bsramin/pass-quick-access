// SPDX-License-Identifier: GPL-3.0-only

import Foundation

/// A string that never reveals itself through logging, debugging, or string
/// interpolation. The plaintext is only reachable through `reveal()`, which
/// keeps secret access explicit and greppable at every call site.
struct SensitiveString: Sendable {
    private let value: String

    init(_ value: String) {
        self.value = value
    }

    var isEmpty: Bool { value.isEmpty }

    func reveal() -> String { value }
}

extension SensitiveString: CustomStringConvertible, CustomDebugStringConvertible {
    var description: String { "••••••" }
    var debugDescription: String { "SensitiveString(••••••)" }
}
