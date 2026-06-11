// SPDX-License-Identifier: GPL-3.0-only

import SwiftUI

struct ItemRowView: View {
    let item: ItemSummary
    let isSelected: Bool
    let showsVault: Bool
    var isFlashing: Bool = false

    var body: some View {
        HStack(spacing: 11) {
            ItemIcon(item: item)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                if let account = item.account {
                    Text(account)
                        .font(.system(size: 11))
                        .foregroundStyle(isSelected ? .white.opacity(0.85) : .secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            if showsVault {
                Text(item.vaultName)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(isSelected ? .white.opacity(0.9) : .secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(isSelected ? Color.white.opacity(0.18) : Color.primary.opacity(0.07))
                    )
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Color.accentColor : .clear)
        )
        .foregroundStyle(isSelected ? .white : .primary)
        .brightness(isFlashing ? 0.35 : 0)
        .contentShape(Rectangle())
    }
}
