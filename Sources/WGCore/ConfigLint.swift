import CryptoKit
import Foundation

/// WireGuard key helpers (Curve25519, base64).
public enum WGKey {
    public static func generatePrivate() -> String {
        Curve25519.KeyAgreement.PrivateKey().rawRepresentation.base64EncodedString()
    }

    /// A preshared key is 32 random bytes, not a Curve25519 key.
    public static func generatePreshared() -> String {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }.base64EncodedString()
    }

    public static func publicKey(fromPrivate key: String) -> String? {
        guard let raw = Data(base64Encoded: key),
              let k = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw) else { return nil }
        return k.publicKey.rawRepresentation.base64EncodedString()
    }
}

public struct ConfigIssue: Equatable, Sendable, Identifiable {
    public enum Severity: Int, Comparable, Sendable {
        case tip, warning, error
        public static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
    }
    public var line: Int?
    public var severity: Severity
    public var message: String
    /// What to do about it.
    public var hint: String
    public var id: String { "\(line ?? 0)|\(message)" }
}

/// Reads a config line by line and reports problems with a fix for each.
/// Errors come from `WGConfig` (what blocks saving); warnings and tips are advice.
public enum ConfigLint {
    struct Entry { let section: Int; let key: String; let value: String; let line: Int }

    public static func check(_ text: String) -> [ConfigIssue] {
        var issues: [ConfigIssue] = []
        let parsed: WGConfig?
        do { parsed = try WGConfig(parsing: text) } catch let e as WGConfigError {
            parsed = nil
            issues.append(error(e))
        } catch { parsed = nil }

        let entries = scan(text)
        func first(_ key: String, section: Int? = nil) -> Entry? {
            entries.first { $0.key == key && (section == nil || $0.section == section) }
        }
        let peerSections = Set(entries.map(\.section).filter { $0 > 0 }).sorted()
        let addresses = values(entries, "address", section: 0)
        let hasV6Address = addresses.contains { Validation.isValidIPv6(ip($0)) }
        let hasV4Address = addresses.contains { Validation.isValidIPv4(ip($0)) }

        var seenKeys: [String: Int] = [:]
        var routed: [(String, Int)] = []
        for sec in peerSections {
            let allowed = values(entries, "allowedips", section: sec)
            let allowedLine = first("allowedips", section: sec)?.line
            if let pk = first("publickey", section: sec) {
                if let other = seenKeys[pk.value] {
                    issues.append(.init(line: pk.line, severity: .warning,
                                        message: "Same peer public key as line \(other)",
                                        hint: "Merge the two [Peer] sections; wg keeps only the last one."))
                }
                seenKeys[pk.value] = pk.line
                if let priv = first("privatekey", section: 0), WGKey.publicKey(fromPrivate: priv.value) == pk.value {
                    issues.append(.init(line: pk.line, severity: .error, message: "The peer is this device",
                                        hint: "PublicKey must be the server's key, not the one made from your PrivateKey."))
                }
            }
            if allowed.contains("::/0") && !hasV6Address {
                issues.append(.init(line: allowedLine, severity: .warning,
                                    message: "Routes all IPv6 (::/0) but the interface has no IPv6 address",
                                    hint: "Add an IPv6 Address from the server, or remove ::/0 and turn IPv6 off on your Mac to avoid leaks."))
            }
            if allowed.contains("0.0.0.0/0") && !allowed.contains("::/0") {
                issues.append(.init(line: allowedLine, severity: .warning,
                                    message: "IPv4 goes through the tunnel but IPv6 does not",
                                    hint: "Add ::/0 so IPv6 sites can't bypass the tunnel."))
            }
            if allowed.contains("0.0.0.0/0") && !hasV4Address && !addresses.isEmpty {
                issues.append(.init(line: allowedLine, severity: .warning,
                                    message: "Routes all IPv4 (0.0.0.0/0) but the interface has no IPv4 address",
                                    hint: "Add an IPv4 Address from the server."))
            }
            for cidr in allowed where Validation.isValidCIDR(cidr) {
                if let net = network(cidr), net != ip(cidr) {
                    issues.append(.init(line: allowedLine, severity: .tip,
                                        message: "\(cidr) has host bits set",
                                        hint: "wg reads it as \(net)/\(prefix(cidr)). Write that to make it clear."))
                }
                if let clash = routed.first(where: { $0.0 == cidr }) {
                    issues.append(.init(line: allowedLine, severity: .warning,
                                        message: "\(cidr) is also routed to the peer on line \(clash.1)",
                                        hint: "Each range can belong to one peer only; the later one wins."))
                }
                routed.append((cidr, allowedLine ?? 0))
            }
            if let ep = first("endpoint", section: sec), first("persistentkeepalive", section: sec) == nil {
                issues.append(.init(line: ep.line, severity: .tip, message: "No PersistentKeepalive",
                                    hint: "Behind NAT or a firewall, add PersistentKeepalive = 25 to keep the tunnel reachable."))
            }
        }
        if !peerSections.isEmpty, !peerSections.contains(where: { first("endpoint", section: $0) != nil }) {
            issues.append(.init(line: nil, severity: .warning, message: "No peer has an Endpoint",
                                hint: "This Mac can't start the connection; it only works if the server reaches you first."))
        }
        let routesAll = peerSections.contains { values(entries, "allowedips", section: $0).contains("0.0.0.0/0") }
        if routesAll && first("dns", section: 0) == nil {
            issues.append(.init(line: first("address", section: 0)?.line, severity: .warning,
                                message: "Routes all traffic but sets no DNS",
                                hint: "DNS lookups keep going to your local network's server. Add DNS = with a resolver reachable through the tunnel."))
        }
        if let m = first("mtu", section: 0), let v = Int(m.value), v > 1420 {
            issues.append(.init(line: m.line, severity: .tip, message: "MTU \(v) is above WireGuard's usual 1420",
                                hint: "Large MTUs can stall downloads on PPPoE or mobile links. Try 1420, or 1280 if pages hang."))
        }
        if parsed != nil, issues.isEmpty { return [] }
        return issues.sorted { ($0.severity, -($0.line ?? 0)) > ($1.severity, -($1.line ?? 0)) }
    }

    /// Section 0 is [Interface]; each [Peer] gets 1, 2, …
    static func scan(_ text: String) -> [Entry] {
        var out: [Entry] = []
        var section = -1, peers = 0
        for (i, raw) in text.components(separatedBy: .newlines).enumerated() {
            var line = raw
            if let h = line.firstIndex(of: "#") { line = String(line[..<h]) }
            line = line.trimmingCharacters(in: .whitespaces)
            switch line.lowercased() {
            case "": continue
            case "[interface]": section = 0; continue
            case "[peer]": peers += 1; section = peers; continue
            default: break
            }
            guard section >= 0, let eq = line.firstIndex(of: "=") else { continue }
            out.append(Entry(section: section, key: line[..<eq].trimmingCharacters(in: .whitespaces).lowercased(),
                             value: line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces), line: i + 1))
        }
        return out
    }

    static func values(_ entries: [Entry], _ key: String, section: Int) -> [String] {
        entries.filter { $0.key == key && $0.section == section }
            .flatMap { $0.value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
    }

    static func ip(_ cidr: String) -> String { String(cidr.split(separator: "/").first ?? "") }
    static func prefix(_ cidr: String) -> Int { Int(cidr.split(separator: "/").last ?? "") ?? 0 }

    /// The network address of an IPv4 CIDR (nil for IPv6, which is left alone).
    static func network(_ cidr: String) -> String? {
        let parts = ip(cidr).split(separator: ".").compactMap { UInt32($0) }
        guard parts.count == 4 else { return nil }
        let addr = parts.reduce(0) { $0 << 8 | $1 }
        let p = prefix(cidr)
        let mask: UInt32 = p == 0 ? 0 : ~UInt32(0) << (32 - p)
        let n = addr & mask
        return [24, 16, 8, 0].map { String((n >> UInt32($0)) & 255) }.joined(separator: ".")
    }

    static func error(_ e: WGConfigError) -> ConfigIssue {
        switch e {
        case let .syntax(l, m):
            return .init(line: l, severity: .error, message: m.prefix(1).uppercased() + m.dropFirst(),
                         hint: "Each line is a [Section] or Key = Value. Comments start with #.")
        case let .unsupportedKey(l, k):
            return .init(line: l, severity: .error, message: "Unsupported key '\(k)'",
                         hint: "Remove it. Wirelight understands PrivateKey, Address, DNS, MTU, ListenPort and the usual [Peer] keys.")
        case let .forbiddenKey(l, k):
            return .init(line: l, severity: .error, message: "'\(k)' is not allowed",
                         hint: "Scripts and Table are never run by Wirelight. Delete the line; split DNS and exclusions cover most uses.")
        case let .invalidValue(l, k, v):
            return .init(line: l, severity: .error, message: "\(k) '\(v)' is not valid",
                         hint: hint(forKey: k))
        case let .duplicateKey(l, k):
            return .init(line: l, severity: .error, message: "'\(k)' appears twice",
                         hint: "Keep one; only Address, DNS and AllowedIPs may repeat.")
        case let .missing(m):
            return .init(line: nil, severity: .error, message: "Missing \(m)", hint: "Add it; every config needs it.")
        }
    }

    static func hint(forKey k: String) -> String {
        switch k {
        case "PrivateKey", "PublicKey", "PresharedKey": return "Keys are 44 characters of base64 ending in '='."
        case "Address", "AllowedIPs": return "Use CIDR form, like 10.0.0.2/32 or fd00::2/128."
        case "Endpoint": return "Use host:port, like vpn.example.com:51820 or [2001:db8::1]:51820."
        case "DNS": return "List IP addresses, or domain names to use as search domains."
        case "MTU": return "A number from 576 to 9000; 1420 is typical."
        default: return "Check the value's format."
        }
    }
}
