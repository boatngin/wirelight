import Foundation

/// Socket path shared by helper and clients.
public let wgbarSocketPath = "/var/run/wgbar.sock"

/// Extra per-connection behaviour that is not part of a wg-quick config.
public struct UpOptions: Codable, Equatable, Sendable {
    /// Use the tunnel's DNS servers only for these domains (via /etc/resolver).
    public var splitDNSDomains: [String]
    /// CIDRs that keep using the physical default route even while connected.
    public var excludedCIDRs: [String]
    /// Block all non-tunnel traffic while this tunnel is up or has dropped unexpectedly.
    public var killSwitch: Bool
    /// When the tunnel takes all IPv4 but not IPv6, drop IPv6 instead of letting it bypass the tunnel.
    public var blockIPv6: Bool
    /// Multi-hop: reach this tunnel's server through the named tunnel, which must already be up.
    public var via: String?
    /// Run on AmneziaWG even without obfuscation keys (it also speaks plain WireGuard).
    public var amnezia: Bool

    public init(splitDNSDomains: [String] = [], excludedCIDRs: [String] = [], killSwitch: Bool = false,
                blockIPv6: Bool = false, via: String? = nil, amnezia: Bool = false) {
        self.via = via
        self.amnezia = amnezia
        self.splitDNSDomains = splitDNSDomains
        self.excludedCIDRs = excludedCIDRs
        self.killSwitch = killSwitch
        self.blockIPv6 = blockIPv6
    }

    /// Tolerate options sent by older clients (missing killSwitch key).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        splitDNSDomains = try c.decodeIfPresent([String].self, forKey: .splitDNSDomains) ?? []
        excludedCIDRs = try c.decodeIfPresent([String].self, forKey: .excludedCIDRs) ?? []
        killSwitch = try c.decodeIfPresent(Bool.self, forKey: .killSwitch) ?? false
        blockIPv6 = try c.decodeIfPresent(Bool.self, forKey: .blockIPv6) ?? false
        via = try c.decodeIfPresent(String.self, forKey: .via)
        amnezia = try c.decodeIfPresent(Bool.self, forKey: .amnezia) ?? false
    }

    /// Returns a description of the first invalid entry, or nil.
    public func validationError() -> String? {
        for d in splitDNSDomains where !Validation.isValidHostname(d) { return "invalid split DNS domain '\(d)'" }
        for c in excludedCIDRs where !Validation.isValidCIDR(c) { return "invalid excluded CIDR '\(c)'" }
        if let v = via, !Validation.isValidTunnelName(v) { return "invalid hop tunnel '\(v)'" }
        if splitDNSDomains.count > 64 || excludedCIDRs.count > 256 { return "too many entries" }
        return nil
    }
}

public enum Request: Codable, Equatable, Sendable {
    case up(name: String, config: String)
    case upWithOptions(name: String, config: String, options: UpOptions)
    case down(name: String)
    case status
    case ping
    /// Re-resolve endpoints, re-pin endpoint routes and re-apply DNS (after wake / network change).
    case refresh
    /// Toggle the kill switch on a tunnel that is currently up (applies live, no reconnect).
    case setKillSwitch(name: String, enabled: Bool)
    /// Helper-side diagnostics, returned in `Response.messages`.
    case doctor
    /// Apply a Place's DNS/proxy to the network service with the default route; nil restores the originals.
    case applyPlace(PlaceNetworkSettings?)
    /// Empty the system DNS cache.
    case flushDNS
    /// Admin: store a tunnel root-only so every local user can use it (replaces one with the same name).
    case shareTunnel(name: String, config: String, options: UpOptions, policy: SharePolicy)
    /// Admin: change what other users may do with a shared tunnel.
    case setSharePolicy(name: String, policy: SharePolicy)
    /// Admin: stop sharing (disconnects it if up).
    case unshareTunnel(name: String)
    /// Any user: shared tunnels without their keys, in `Response.shared`.
    case listShared
    /// Bring a shared tunnel up from the helper's own copy.
    case upShared(name: String)
}

extension Request {
    /// Requests a non-admin user may send; the helper checks share policies on top.
    public var allowedForStandardUsers: Bool {
        switch self {
        case .ping, .status, .listShared, .upShared, .down: return true
        default: return false
        }
    }
}

public struct PeerStatus: Codable, Equatable, Sendable {
    public var publicKey: String
    public var endpoint: String?
    public var latestHandshake: Date?
    public var rxBytes: UInt64
    public var txBytes: UInt64
    public var allowedIPs: [String]

    public init(publicKey: String, endpoint: String?, latestHandshake: Date?, rxBytes: UInt64, txBytes: UInt64, allowedIPs: [String]) {
        self.publicKey = publicKey; self.endpoint = endpoint; self.latestHandshake = latestHandshake
        self.rxBytes = rxBytes; self.txBytes = txBytes; self.allowedIPs = allowedIPs
    }
}

public struct TunnelStatus: Codable, Equatable, Sendable {
    public var name: String
    public var interface: String
    public var peers: [PeerStatus]
    /// "wireguard" or "amneziawg"; nil from older helpers.
    public var engine: String?

    public init(name: String, interface: String, peers: [PeerStatus], engine: String? = nil) {
        self.name = name; self.interface = interface; self.peers = peers; self.engine = engine
    }
}

public struct Response: Codable, Equatable, Sendable {
    public var ok: Bool
    public var error: String?
    public var status: [TunnelStatus]?
    public var messages: [String]?
    public var shared: [SharedTunnelInfo]?

    public init(ok: Bool, error: String? = nil, status: [TunnelStatus]? = nil, messages: [String]? = nil,
                shared: [SharedTunnelInfo]? = nil) {
        self.ok = ok; self.error = error; self.status = status; self.messages = messages; self.shared = shared
    }
    public static func failure(_ msg: String) -> Response { Response(ok: false, error: msg) }
}

public enum IPCError: Error, Equatable {
    case frameTooLarge(Int)
    case truncated
}

/// Framing: 4-byte big-endian length followed by a JSON body.
public enum IPCFraming {
    public static let maxFrameSize = 1 << 20 // 1 MiB

    static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .secondsSince1970; return e
    }()
    static let decoder: JSONDecoder = {
        let d = JSONDecoder(); d.dateDecodingStrategy = .secondsSince1970; return d
    }()

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let body = try encoder.encode(value)
        guard body.count <= maxFrameSize else { throw IPCError.frameTooLarge(body.count) }
        var len = UInt32(body.count).bigEndian
        var frame = Data(bytes: &len, count: 4)
        frame.append(body)
        return frame
    }

    /// Length from a 4-byte header; throws if it exceeds `maxFrameSize`.
    public static func length(fromHeader header: Data) throws -> Int {
        guard header.count >= 4 else { throw IPCError.truncated }
        let b = [UInt8](header.prefix(4))
        let n = Int(b[0]) << 24 | Int(b[1]) << 16 | Int(b[2]) << 8 | Int(b[3])
        guard n <= maxFrameSize else { throw IPCError.frameTooLarge(n) }
        return n
    }

    public static func decodeBody<T: Decodable>(_ type: T.Type, from body: Data) throws -> T {
        try decoder.decode(type, from: body)
    }

    /// Decode a complete frame (header + body).
    public static func decode<T: Decodable>(_ type: T.Type, from frame: Data) throws -> T {
        let n = try length(fromHeader: frame)
        guard frame.count >= 4 + n else { throw IPCError.truncated }
        return try decodeBody(type, from: frame.subdata(in: frame.startIndex + 4 ..< frame.startIndex + 4 + n))
    }
}
