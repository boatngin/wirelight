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

    public init(splitDNSDomains: [String] = [], excludedCIDRs: [String] = [], killSwitch: Bool = false) {
        self.splitDNSDomains = splitDNSDomains
        self.excludedCIDRs = excludedCIDRs
        self.killSwitch = killSwitch
    }

    /// Tolerate options sent by older clients (missing killSwitch key).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        splitDNSDomains = try c.decodeIfPresent([String].self, forKey: .splitDNSDomains) ?? []
        excludedCIDRs = try c.decodeIfPresent([String].self, forKey: .excludedCIDRs) ?? []
        killSwitch = try c.decodeIfPresent(Bool.self, forKey: .killSwitch) ?? false
    }

    /// Returns a description of the first invalid entry, or nil.
    public func validationError() -> String? {
        for d in splitDNSDomains where !Validation.isValidHostname(d) { return "invalid split DNS domain '\(d)'" }
        for c in excludedCIDRs where !Validation.isValidCIDR(c) { return "invalid excluded CIDR '\(c)'" }
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

    public init(name: String, interface: String, peers: [PeerStatus]) {
        self.name = name; self.interface = interface; self.peers = peers
    }
}

public struct Response: Codable, Equatable, Sendable {
    public var ok: Bool
    public var error: String?
    public var status: [TunnelStatus]?
    public var messages: [String]?

    public init(ok: Bool, error: String? = nil, status: [TunnelStatus]? = nil, messages: [String]? = nil) {
        self.ok = ok; self.error = error; self.status = status; self.messages = messages
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
