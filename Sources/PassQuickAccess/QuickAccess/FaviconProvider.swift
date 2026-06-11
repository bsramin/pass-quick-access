// SPDX-License-Identifier: GPL-3.0-only

import AppKit

/// Loads and caches website favicons, on demand, only when the user has opted
/// in. Icons are fetched straight from each site (no third-party proxy) so no
/// single service learns the full list of saved domains. The trade-off is that
/// each site sees the request. See SettingsView for the privacy notice.
@MainActor
final class FaviconProvider: ObservableObject {
    static let shared = FaviconProvider()

    @Published private(set) var icons: [String: NSImage] = [:]
    private var inFlight: Set<String> = []
    private let session: URLSession

    private init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        session = URLSession(configuration: configuration)
    }

    func icon(for host: String) -> NSImage? { icons[host] }

    func load(host: String) {
        guard FaviconHost.looksPublic(host), icons[host] == nil, !inFlight.contains(host) else { return }
        inFlight.insert(host)
        let session = self.session
        Task {
            let data = await Self.fetchIfPublic(host, using: session)
            inFlight.remove(host)
            if let data, let image = NSImage(data: data), image.isValid, image.size.width > 0 {
                icons[host] = image
            }
        }
    }

    private static func fetchIfPublic(_ host: String, using session: URLSession) async -> Data? {
        // Resolve off the main actor; skip anything that points at the local
        // network before opening a connection.
        let isPublic = await Task.detached(priority: .utility) {
            FaviconHost.resolvesToPublicAddress(host)
        }.value
        guard isPublic, let url = URL(string: "https://\(host)/favicon.ico") else { return nil }
        return await fetch(url, using: session)
    }

    private static func fetch(_ url: URL, using session: URLSession) async -> Data? {
        guard let (data, response) = try? await session.data(from: url),
              let http = response as? HTTPURLResponse, http.statusCode == 200
        else { return nil }
        return data
    }
}

extension URL {
    /// The host of a stored login URL, tolerating entries written without a
    /// scheme (e.g. "example.com/login").
    static func host(fromUserEntered string: String) -> String? {
        let normalized = string.contains("://") ? string : "https://\(string)"
        return URL(string: normalized)?.host
    }
}
