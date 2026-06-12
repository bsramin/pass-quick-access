// SPDX-License-Identifier: GPL-3.0-only

import SwiftUI

/// Shows a value at large size for reading aloud or typing by hand, one character
/// per numbered box. Letters are dark, digits blue and symbols red, so each kind
/// stands out. Rows stay short (around five) for easy scanning, but widen for long
/// values so the window doesn't grow unreasonably tall.
struct LargeTypeView: View {
    let value: String

    private var characters: [Character] { Array(value) }

    /// Characters per row: five for short and medium values, widening up to ten so
    /// a long value caps at roughly six rows before it starts growing downward.
    private var perRow: Int {
        let count = characters.count
        guard count > 0 else { return 1 }
        let toFitSixRows = Int((Double(count) / 6.0).rounded(.up))
        return min(10, max(5, toFitSixRows))
    }

    private var rowCount: Int { (characters.count + perRow - 1) / max(perRow, 1) }

    var body: some View {
        VStack(spacing: 12) {
            VStack(spacing: 8) {
                ForEach(0..<rowCount, id: \.self) { row in
                    HStack(spacing: 0) {
                        ForEach(0..<perRow, id: \.self) { column in
                            let index = row * perRow + column
                            if index < characters.count {
                                cell(characters[index], index: index)
                            }
                        }
                    }
                }
            }

            HStack(spacing: 5) {
                Text("esc")
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                Text("return to the item")
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func cell(_ character: Character, index: Int) -> some View {
        VStack(spacing: 6) {
            Text(String(character))
                .font(.system(size: 74, weight: .regular))
                .foregroundStyle(color(for: character))
            Text("\(index + 1)")
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .frame(width: 82, height: 124)
        .background(
            index.isMultiple(of: 2) ? Color.primary.opacity(0.05) : Color.clear,
            in: RoundedRectangle(cornerRadius: 7)
        )
    }

    private func color(for character: Character) -> Color {
        if character.isNumber { return Color(red: 0.10, green: 0.45, blue: 0.91) }
        if character.isLetter { return .primary }
        return Color(red: 0.84, green: 0.18, blue: 0.13)
    }
}
