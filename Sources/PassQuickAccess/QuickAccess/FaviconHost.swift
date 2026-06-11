// SPDX-License-Identifier: GPL-3.0-only

import Darwin
import Foundation

/// Decides whether a host is a public website that a favicon may be fetched
/// from. The point is to keep favicon requests off the local network, which both
/// avoids poking routers and devices and avoids the macOS local-network prompt.
enum FaviconHost {
    /// A cheap textual filter: rejects localhost, `.local` names, IPv6 literals
    /// and any bare IPv4 address.
    static func looksPublic(_ host: String) -> Bool {
        let host = host.lowercased()
        guard host != "localhost", !host.hasSuffix(".local"), !host.contains(":") else { return false }
        return host.split(separator: ".").compactMap { UInt8($0) }.count != 4
    }

    /// Resolves the host and returns true only when every address it maps to is
    /// public. This catches a public-looking name that resolves to a private
    /// address. Resolving is plain DNS and does not trigger the local-network
    /// prompt; only connecting would, which is exactly what this prevents.
    static func resolvesToPublicAddress(_ host: String) -> Bool {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var info: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &info) == 0, info != nil else { return false }
        defer { freeaddrinfo(info) }

        var sawAddress = false
        var node = info
        while let entry = node {
            defer { node = entry.pointee.ai_next }
            guard let address = entry.pointee.ai_addr, let text = string(from: address) else { continue }
            sawAddress = true
            if isPrivate(text) { return false }
        }
        return sawAddress
    }

    private static func string(from address: UnsafePointer<sockaddr>) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        switch Int32(address.pointee.sa_family) {
        case AF_INET:
            return address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                var addr = $0.pointee.sin_addr
                inet_ntop(AF_INET, &addr, &buffer, socklen_t(buffer.count))
                return String(cString: buffer)
            }
        case AF_INET6:
            return address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                var addr = $0.pointee.sin6_addr
                inet_ntop(AF_INET6, &addr, &buffer, socklen_t(buffer.count))
                return String(cString: buffer)
            }
        default:
            return nil
        }
    }

    private static func isPrivate(_ ip: String) -> Bool {
        let ip = ip.lowercased()
        if ip == "::1" || ip.hasPrefix("fe80") || ip.hasPrefix("fc") || ip.hasPrefix("fd") { return true }
        let octets = ip.split(separator: ".").compactMap { UInt8($0) }
        guard octets.count == 4 else { return false }
        switch (octets[0], octets[1]) {
        case (10, _), (127, _), (0, _), (192, 168), (169, 254): return true
        case (172, 16...31): return true
        default: return false
        }
    }
}
