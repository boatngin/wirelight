import Foundation

/// What this Mac is connected to right now.
public struct NetworkSnapshot: Equatable, Sendable {
    public var wifiSSID: String?
    /// Addresses on wired Ethernet interfaces (IPv4 and IPv6).
    public var ethernetAddresses: [String]

    public init(wifiSSID: String? = nil, ethernetAddresses: [String] = []) {
        self.wifiSSID = wifiSSID; self.ethernetAddresses = ethernetAddresses
    }

    public var onEthernet: Bool { !ethernetAddresses.isEmpty }
}

/// One "when on this network, do that" rule for a tunnel.
public struct NetworkRule: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        /// Wi-Fi with one of `values` as its name; empty matches any Wi-Fi.
        case wifi
        /// Ethernet with an address in one of `values` (CIDRs); empty matches any Ethernet.
        case ethernet
    }
    public enum Action: String, Codable, CaseIterable, Sendable { case connect, disconnect }

    public var id: UUID
    public var kind: Kind
    public var values: [String]
    public var action: Action

    public init(id: UUID = UUID(), kind: Kind, values: [String] = [], action: Action) {
        self.id = id; self.kind = kind; self.values = values; self.action = action
    }

    public func matches(_ n: NetworkSnapshot) -> Bool {
        switch kind {
        case .wifi:
            guard let ssid = n.wifiSSID else { return false }
            return values.isEmpty || values.contains(ssid)
        case .ethernet:
            guard n.onEthernet else { return false }
            return values.isEmpty || n.ethernetAddresses.contains { ip in values.contains { CIDR.contains($0, ip) } }
        }
    }
}

public enum NetworkRules {
    /// First matching rule wins; otherwise `fallback` (nil leaves the tunnel as it is).
    /// With no network at all nothing happens.
    public static func decide(_ rules: [NetworkRule], fallback: NetworkRule.Action?,
                              on n: NetworkSnapshot) -> (action: NetworkRule.Action, rule: Int?)? {
        guard n.wifiSSID != nil || n.onEthernet else { return nil }
        if let i = rules.firstIndex(where: { $0.matches(n) }) { return (rules[i].action, i) }
        return fallback.map { ($0, nil) }
    }
}

public enum CIDR {
    /// True when `ip` lies inside `cidr` (same family only).
    public static func contains(_ cidr: String, _ ip: String) -> Bool {
        let parts = cidr.split(separator: "/")
        guard parts.count == 2, let prefix = Int(parts[1]),
              let net = bytes(String(parts[0])), let addr = bytes(ip), net.count == addr.count,
              prefix >= 0, prefix <= net.count * 8 else { return false }
        for i in 0..<net.count {
            let bits = max(0, min(8, prefix - i * 8))
            let mask: UInt8 = bits == 0 ? 0 : ~UInt8(0) << (8 - bits)
            if net[i] & mask != addr[i] & mask { return false }
        }
        return true
    }

    static func bytes(_ ip: String) -> [UInt8]? {
        var v4 = in_addr(), v6 = in6_addr()
        if ip.withCString({ inet_pton(AF_INET, $0, &v4) }) == 1 { return withUnsafeBytes(of: &v4) { Array($0) } }
        // Drop a zone id (fe80::1%en0) before parsing.
        let bare = ip.split(separator: "%").first.map(String.init) ?? ip
        if bare.withCString({ inet_pton(AF_INET6, $0, &v6) }) == 1 { return withUnsafeBytes(of: &v6) { Array($0) } }
        return nil
    }
}
