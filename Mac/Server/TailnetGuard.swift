import Foundation

/// Knows this Mac's tailnet address and name, and decides which devices may connect: loopback, and tailnet devices
/// signed in as the same person as this Mac (checked with `tailscale whois`).
@MainActor
final class TailnetGuard {
    private(set) var ipv4: String?
    private(set) var ipv6: String?
    private(set) var dnsName: String?
    private var ownerLogin: String?
    private var peerCache: [String: (allowed: Bool, checked: Date)] = [:]
    var requireSameUser = true
    var allowLAN = false

    private var cli: String? {
        if let path = Shell.which("tailscale") { return path }
        let app = "/Applications/Tailscale.app/Contents/MacOS/Tailscale"
        return FileManager.default.isExecutableFile(atPath: app) ? app : nil
    }

    /// Reads `tailscale status --json`. Returns true when the tailnet address changed.
    @discardableResult
    func refresh() async -> Bool {
        guard let cli else { return false }
        let result = await Shell.run(cli, ["status", "--json"], timeout: 8)
        guard result.ok,
              let object = try? JSONSerialization.jsonObject(with: result.stdout) as? [String: Any],
              let me = object["Self"] as? [String: Any] else {
            let changed = ipv4 != nil
            ipv4 = nil
            ipv6 = nil
            return changed
        }
        let ips = (me["TailscaleIPs"] as? [String]) ?? []
        let newV4 = ips.first { $0.contains(".") }
        let newV6 = ips.first { $0.contains(":") }
        var name = me["DNSName"] as? String
        if name?.hasSuffix(".") == true { name?.removeLast() }
        dnsName = name
        if let userID = me["UserID"] as? Int,
           let users = object["User"] as? [String: Any],
           let user = users["\(userID)"] as? [String: Any] {
            ownerLogin = user["LoginName"] as? String
        }
        let changed = newV4 != ipv4 || newV6 != ipv6
        ipv4 = newV4
        ipv6 = newV6
        return changed
    }

    /// The addresses the server should listen on.
    var listenHosts: [String] {
        var hosts = ["127.0.0.1"]
        if let ipv4 { hosts.append(ipv4) }
        if allowLAN { hosts.append(contentsOf: LANAddresses.current()) }
        return hosts
    }

    func isAllowedAddress(_ address: String, listenerHost: String) -> Bool {
        if address == "127.0.0.1" || address == "::1" { return true }
        if Self.isTailnet(address) { return true }
        if allowLAN, LANAddresses.isPrivate(address) { return true }
        return false
    }

    func isAllowedPeer(_ address: String) async -> Bool {
        guard requireSameUser, Self.isTailnet(address) else { return true }
        if let cached = peerCache[address], Date.now.timeIntervalSince(cached.checked) < 600 { return cached.allowed }
        guard let cli else { return true }
        if ownerLogin == nil { await refresh() }
        let result = await Shell.run(cli, ["whois", "--json", address], timeout: 8)
        var allowed = false
        if result.ok, let object = try? JSONSerialization.jsonObject(with: result.stdout) as? [String: Any],
           let profile = object["UserProfile"] as? [String: Any], let login = profile["LoginName"] as? String {
            allowed = ownerLogin == nil || login == ownerLogin
        } else {
            // Without an answer from Tailscale the tailnet itself is the boundary; the token is still required.
            allowed = true
        }
        peerCache[address] = (allowed, .now)
        return allowed
    }

    /// 100.64.0.0/10 and Tailscale's IPv6 range fd7a:115c:a1e0::/48.
    nonisolated static func isTailnet(_ address: String) -> Bool {
        if address.lowercased().hasPrefix("fd7a:115c:a1e0:") { return true }
        let parts = address.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        return parts[0] == 100 && (64...127).contains(parts[1])
    }
}

/// The Mac's private LAN addresses (only used when the config turns LAN listening on).
enum LANAddresses {
    static func current() -> [String] {
        var addresses: [String] = []
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return [] }
        defer { freeifaddrs(pointer) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: entry.pointee.ifa_name)
            guard name.hasPrefix("en") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0,
                           NI_NUMERICHOST) == 0 {
                let text = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                if isPrivate(text) { addresses.append(text) }
            }
        }
        return addresses
    }

    static func isPrivate(_ address: String) -> Bool {
        let parts = address.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        return parts[0] == 10 || (parts[0] == 172 && (16...31).contains(parts[1])) || (parts[0] == 192 && parts[1] == 168)
    }
}
