// SPDX-License-Identifier: GPL-3.0-only

import SwiftUI

/// The leading icon for a result. By default it's a monogram derived locally,
/// with no favicon fetch, so the user's saved domains never leave the machine. When
/// the user opts into website icons, the real favicon overlays the monogram
/// once it loads, falling back to the monogram on failure.
struct ItemIcon: View {
    let item: ItemSummary

    @AppStorage(SettingKey.loadWebsiteIcons) private var loadWebsiteIcons = false
    @ObservedObject private var favicons = FaviconProvider.shared

    private let side: CGFloat = 26

    var body: some View {
        ZStack {
            monogram
            if loadWebsiteIcons, let host, let image = favicons.icon(for: host) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .padding(4)
                    .frame(width: side, height: side)
                    .background(.white, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        }
        .frame(width: side, height: side)
        .task(id: host) {
            if loadWebsiteIcons, let host { favicons.load(host: host) }
        }
    }

    private var monogram: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Self.color(for: seed).gradient)
            .frame(width: side, height: side)
            .overlay(
                Text(letter)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
            )
    }

    private var host: String? {
        item.urls.first.flatMap(URL.host(fromUserEntered:))
    }

    private var seed: String { item.urls.first ?? item.title }

    private var letter: String {
        guard let character = item.title.first(where: { $0.isLetter || $0.isNumber }) else { return "•" }
        return String(character).uppercased()
    }

    private static func color(for seed: String) -> Color {
        var hash: UInt64 = 5381
        for byte in seed.lowercased().utf8 {
            hash = (hash &* 33) ^ UInt64(byte)
        }
        return Color(hue: Double(hash % 360) / 360, saturation: 0.55, brightness: 0.78)
    }
}
