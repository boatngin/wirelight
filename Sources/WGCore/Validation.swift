import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Pure validation helpers shared by the app, helper and CLI.
public enum Validation {
    private static let tunnelNameRegex = try! NSRegularExpression(pattern: "^[a-zA-Z0-9_-]{1,15}$")
    private static let hostnameRegex = try! NSRegularExpression(
        pattern: "^(?=.{1,253}$)([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)(\\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*\\.?$")

    /// A WireGuard key: base64 that decodes to exactly 32 bytes.
    public static func isValidKey(_ s: String) -> Bool {
        guard s.count == 44, let data = Data(base64Encoded: s) else { return false }
        return data.count == 32
    }

    public static func isValidIPv4(_ s: String) -> Bool {
        var addr = in_addr()
        return s.withCString { inet_pton(AF_INET, $0, &addr) } == 1
    }

    public static func isValidIPv6(_ s: String) -> Bool {
        var addr = in6_addr()
        return s.withCString { inet_pton(AF_INET6, $0, &addr) } == 1
    }

    public static func isValidIP(_ s: String) -> Bool { isValidIPv4(s) || isValidIPv6(s) }

    /// `addr/prefix`, IPv4 (0...32) or IPv6 (0...128). A bare address is rejected.
    public static func isValidCIDR(_ s: String) -> Bool {
        let parts = s.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let prefix = Int(parts[1]), String(prefix) == parts[1] else { return false }
        let ip = String(parts[0])
        if isValidIPv4(ip) { return (0...32).contains(prefix) }
        if isValidIPv6(ip) { return (0...128).contains(prefix) }
        return false
    }

    public static func isValidHostname(_ s: String) -> Bool {
        let range = NSRange(s.startIndex..., in: s)
        return hostnameRegex.firstMatch(in: s, range: range) != nil
    }

    public static func isValidPort(_ s: String) -> Bool {
        guard let p = Int(s), String(p) == s else { return false }
        return (1...65535).contains(p)
    }

    /// `host:port`, `ipv4:port` or `[ipv6]:port`.
    public static func isValidEndpoint(_ s: String) -> Bool {
        if s.hasPrefix("[") {
            guard let close = s.firstIndex(of: "]") else { return false }
            let host = String(s[s.index(after: s.startIndex)..<close])
            let rest = s[s.index(after: close)...]
            guard rest.hasPrefix(":") else { return false }
            return isValidIPv6(host) && isValidPort(String(rest.dropFirst()))
        }
        guard let colon = s.lastIndex(of: ":") else { return false }
        let host = String(s[..<colon])
        let port = String(s[s.index(after: colon)...])
        guard !host.contains(":") else { return false } // unbracketed IPv6
        return (isValidIPv4(host) || isValidHostname(host)) && isValidPort(port)
    }

    public static func isValidTunnelName(_ s: String) -> Bool {
        let range = NSRange(s.startIndex..., in: s)
        return tunnelNameRegex.firstMatch(in: s, range: range) != nil
    }
}
