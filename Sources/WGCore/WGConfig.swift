import Foundation

public enum WGCore {
    public static let version = "0.0.1"
}

public enum WGConfigError: Error, Equatable, CustomStringConvertible {
    case syntax(line: Int, String)
    case unsupportedKey(line: Int, String)
    case forbiddenKey(line: Int, String)
    case invalidValue(line: Int, key: String, value: String)
    case duplicateKey(line: Int, String)
    case missing(String)

    public var description: String {
        switch self {
        case let .syntax(l, m): return "line \(l): \(m)"
        case let .unsupportedKey(l, k): return "line \(l): unsupported key '\(k)'"
        case let .forbiddenKey(l, k): return "line \(l): '\(k)' is not allowed (scripts are never run)"
        case let .invalidValue(l, k, v): return "line \(l): invalid \(k) '\(v)'"
        case let .duplicateKey(l, k): return "line \(l): duplicate key '\(k)'"
        case let .missing(m): return "missing \(m)"
        }
    }
}

public struct WGInterface: Equatable, Sendable {
    public var privateKey: String
    public var addresses: [String] = []
    public var dns: [String] = []
    public var dnsSearch: [String] = []
    public var mtu: Int?
    public var listenPort: Int?
}

public struct WGPeer: Equatable, Sendable {
    public var publicKey: String
    public var presharedKey: String?
    public var endpoint: String?
    public var allowedIPs: [String] = []
    public var persistentKeepalive: Int?
}

/// A parsed wg-quick style `.conf`. Hook keys (PreUp/PostUp/...) are rejected.
public struct WGConfig: Equatable, Sendable {
    public var interface: WGInterface
    public var peers: [WGPeer]

    static let forbiddenKeys: Set<String> = ["preup", "postup", "predown", "postdown", "saveconfig", "table"]

    public init(interface: WGInterface, peers: [WGPeer]) {
        self.interface = interface
        self.peers = peers
    }

    public init(parsing text: String) throws {
        enum Section { case none, interface, peer }
        var section = Section.none
        var iface: [String: (Int, String)] = [:]
        var peerDicts: [[String: (Int, String)]] = []
        var sawInterface = false

        for (idx, rawLine) in text.components(separatedBy: .newlines).enumerated() {
            let lineNo = idx + 1
            var line = rawLine
            if let hash = line.firstIndex(of: "#") { line = String(line[..<hash]) }
            line = line.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            if line.hasPrefix("[") {
                switch line.lowercased() {
                case "[interface]":
                    if sawInterface { throw WGConfigError.syntax(line: lineNo, "duplicate [Interface]") }
                    sawInterface = true
                    section = .interface
                case "[peer]":
                    section = .peer
                    peerDicts.append([:])
                default:
                    throw WGConfigError.syntax(line: lineNo, "unknown section \(line)")
                }
                continue
            }

            guard let eq = line.firstIndex(of: "=") else {
                throw WGConfigError.syntax(line: lineNo, "expected 'Key = Value'")
            }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            let lkey = key.lowercased()
            if Self.forbiddenKeys.contains(lkey) { throw WGConfigError.forbiddenKey(line: lineNo, key) }

            func store(_ dict: inout [String: (Int, String)]) throws {
                if let existing = dict[lkey] {
                    // Multi-value keys may repeat and are concatenated.
                    guard ["address", "dns", "allowedips"].contains(lkey) else {
                        throw WGConfigError.duplicateKey(line: lineNo, key)
                    }
                    dict[lkey] = (existing.0, existing.1 + "," + value)
                } else {
                    dict[lkey] = (lineNo, value)
                }
            }

            switch section {
            case .none: throw WGConfigError.syntax(line: lineNo, "key outside of a section")
            case .interface: try store(&iface)
            case .peer: try store(&peerDicts[peerDicts.count - 1])
            }
        }

        guard sawInterface else { throw WGConfigError.missing("[Interface] section") }
        self.interface = try Self.buildInterface(iface)
        self.peers = try peerDicts.map(Self.buildPeer)
        guard !peers.isEmpty else { throw WGConfigError.missing("[Peer] section") }
    }

    private static func list(_ s: String) -> [String] {
        s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private static func int(_ entry: (Int, String), key: String, range: ClosedRange<Int>) throws -> Int {
        guard let v = Int(entry.1), range.contains(v) else {
            throw WGConfigError.invalidValue(line: entry.0, key: key, value: entry.1)
        }
        return v
    }

    private static func buildInterface(_ d: [String: (Int, String)]) throws -> WGInterface {
        let allowed: Set<String> = ["privatekey", "address", "dns", "mtu", "listenport"]
        for (k, v) in d where !allowed.contains(k) { throw WGConfigError.unsupportedKey(line: v.0, k) }

        guard let pk = d["privatekey"] else { throw WGConfigError.missing("Interface.PrivateKey") }
        guard Validation.isValidKey(pk.1) else {
            throw WGConfigError.invalidValue(line: pk.0, key: "PrivateKey", value: "<redacted>")
        }
        var i = WGInterface(privateKey: pk.1)

        if let a = d["address"] {
            for addr in list(a.1) {
                guard Validation.isValidCIDR(addr) else {
                    throw WGConfigError.invalidValue(line: a.0, key: "Address", value: addr)
                }
                i.addresses.append(addr)
            }
        }
        guard !i.addresses.isEmpty else { throw WGConfigError.missing("Interface.Address") }

        if let dns = d["dns"] {
            for item in list(dns.1) {
                if Validation.isValidIP(item) { i.dns.append(item) }
                else if Validation.isValidHostname(item) { i.dnsSearch.append(item) }
                else { throw WGConfigError.invalidValue(line: dns.0, key: "DNS", value: item) }
            }
        }
        if let m = d["mtu"] { i.mtu = try int(m, key: "MTU", range: 576...9000) }
        if let p = d["listenport"] { i.listenPort = try int(p, key: "ListenPort", range: 0...65535) }
        return i
    }

    private static func buildPeer(_ d: [String: (Int, String)]) throws -> WGPeer {
        let allowed: Set<String> = ["publickey", "presharedkey", "endpoint", "allowedips", "persistentkeepalive"]
        for (k, v) in d where !allowed.contains(k) { throw WGConfigError.unsupportedKey(line: v.0, k) }

        guard let pub = d["publickey"] else { throw WGConfigError.missing("Peer.PublicKey") }
        guard Validation.isValidKey(pub.1) else {
            throw WGConfigError.invalidValue(line: pub.0, key: "PublicKey", value: pub.1)
        }
        var p = WGPeer(publicKey: pub.1)
        if let psk = d["presharedkey"] {
            guard Validation.isValidKey(psk.1) else {
                throw WGConfigError.invalidValue(line: psk.0, key: "PresharedKey", value: "<redacted>")
            }
            p.presharedKey = psk.1
        }
        if let ep = d["endpoint"] {
            guard Validation.isValidEndpoint(ep.1) else {
                throw WGConfigError.invalidValue(line: ep.0, key: "Endpoint", value: ep.1)
            }
            p.endpoint = ep.1
        }
        if let a = d["allowedips"] {
            for cidr in list(a.1) {
                guard Validation.isValidCIDR(cidr) else {
                    throw WGConfigError.invalidValue(line: a.0, key: "AllowedIPs", value: cidr)
                }
                p.allowedIPs.append(cidr)
            }
        }
        if let k = d["persistentkeepalive"] {
            p.persistentKeepalive = k.1.lowercased() == "off" ? nil : try int(k, key: "PersistentKeepalive", range: 0...65535)
        }
        return p
    }

    /// Text accepted by `wg setconf`: only keys wg itself understands (no Address/DNS/MTU).
    public func wgSetconfText() -> String {
        var out = ["[Interface]", "PrivateKey = \(interface.privateKey)"]
        if let lp = interface.listenPort { out.append("ListenPort = \(lp)") }
        for p in peers {
            out.append("")
            out.append("[Peer]")
            out.append("PublicKey = \(p.publicKey)")
            if let psk = p.presharedKey { out.append("PresharedKey = \(psk)") }
            if let ep = p.endpoint { out.append("Endpoint = \(ep)") }
            if !p.allowedIPs.isEmpty { out.append("AllowedIPs = \(p.allowedIPs.joined(separator: ", "))") }
            if let k = p.persistentKeepalive { out.append("PersistentKeepalive = \(k)") }
        }
        return out.joined(separator: "\n") + "\n"
    }
}
