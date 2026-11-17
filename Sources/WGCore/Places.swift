import Foundation

/// A system proxy choice for the network service a Place applies to.
public struct ProxySetting: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, CaseIterable, Sendable { case off, manual, auto }
    public var mode: Mode
    /// `host:port` for each manual proxy; nil leaves that one off.
    public var http: String?
    public var https: String?
    public var socks: String?
    public var bypass: [String]
    /// PAC file address for `.auto`.
    public var pacURL: String?

    public init(mode: Mode = .off, http: String? = nil, https: String? = nil, socks: String? = nil,
                bypass: [String] = [], pacURL: String? = nil) {
        self.mode = mode; self.http = http; self.https = https; self.socks = socks
        self.bypass = bypass; self.pacURL = pacURL
    }

    public func validationError() -> String? {
        for s in [http, https, socks].compactMap({ $0 }) where !Validation.isValidEndpoint(s) {
            return "invalid proxy '\(s)' (use host:port)"
        }
        for b in bypass where !Self.isValidBypass(b) { return "invalid bypass entry '\(b)'" }
        if bypass.count > 64 { return "too many bypass entries" }
        if mode == .auto {
            guard let u = pacURL, u.count <= 2048, !u.contains(where: \.isWhitespace),
                  let url = URL(string: u), ["http", "https"].contains(url.scheme ?? ""), url.host != nil else {
                return "invalid PAC address"
            }
        }
        if mode == .manual, http == nil, https == nil, socks == nil { return "manual proxy needs a server" }
        return nil
    }

    /// `example.com`, `*.local`, an IP or a CIDR.
    public static func isValidBypass(_ s: String) -> Bool {
        let host = s.hasPrefix("*.") ? String(s.dropFirst(2)) : s
        return Validation.isValidHostname(host) || Validation.isValidIP(s) || Validation.isValidCIDR(s)
    }
}

/// What a Place changes on the active network service. nil fields are left alone.
public struct PlaceNetworkSettings: Codable, Equatable, Sendable {
    public var dnsServers: [String]?
    public var proxy: ProxySetting?

    public init(dnsServers: [String]? = nil, proxy: ProxySetting? = nil) {
        self.dnsServers = dnsServers; self.proxy = proxy
    }

    public func validationError() -> String? {
        if let d = dnsServers {
            if d.isEmpty || d.count > 8 { return "use 1 to 8 DNS servers" }
            for s in d where !Validation.isValidIP(s) { return "invalid DNS server '\(s)'" }
        }
        return proxy?.validationError()
    }
}

/// Well-known public resolvers offered as presets (their published anycast addresses).
public enum DNSPreset: String, Codable, CaseIterable, Sendable {
    case cloudflare, quad9, google

    public var title: String {
        switch self {
        case .cloudflare: return "Cloudflare"
        case .quad9: return "Quad9"
        case .google: return "Google"
        }
    }

    public var servers: [String] {
        switch self {
        case .cloudflare: return ["1.1.1.1", "1.0.0.1", "2606:4700:4700::1111", "2606:4700:4700::1001"]
        case .quad9: return ["9.9.9.9", "149.112.112.112", "2620:fe::fe", "2620:fe::9"]
        case .google: return ["8.8.8.8", "8.8.4.4", "2001:4860:4860::8888", "2001:4860:4860::8844"]
        }
    }
}
