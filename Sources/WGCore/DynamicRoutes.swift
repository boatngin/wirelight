import Foundation

/// Routes a tunnel learns after it connects, from a command the user runs
/// (an inventory script, a cloud CLI, a curl to an API...).
public enum DynamicRoutes {
    public static let maxRoutes = 512

    /// Why a CIDR (or bare IP) can't be routed, or nil. Broad and special ranges are
    /// refused so a bad script can't swallow the whole internet or the local machine.
    public static func problem(_ entry: String) -> String? {
        let cidr = normalize(entry)
        guard Validation.isValidCIDR(cidr) else { return "not an IP or CIDR" }
        let ip = String(cidr.split(separator: "/")[0]), prefix = Int(cidr.split(separator: "/")[1]) ?? 0
        if Validation.isValidIPv4(ip) {
            if prefix < 8 { return "wider than /8" }
            for bad in ["0.0.0.0/8", "127.0.0.0/8", "169.254.0.0/16", "224.0.0.0/4", "240.0.0.0/4"]
            where CIDR.overlaps(bad, cidr) { return "special range \(bad)" }
        } else {
            if prefix < 32 { return "wider than /32" }
            for bad in ["::/128", "::1/128", "fe80::/10", "ff00::/8"] where CIDR.overlaps(bad, cidr) {
                return "special range \(bad)"
            }
        }
        return nil
    }

    /// A bare address becomes a host route.
    public static func normalize(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.contains("/") { return t }
        return Validation.isValidIPv6(t) ? "\(t)/128" : "\(t)/32"
    }

    /// Reads a command's output: one entry per line or comma/space separated;
    /// `#` comments and blank lines are skipped. Returns accepted CIDRs and rejected lines.
    public static func parse(_ output: String) -> (routes: [String], rejected: [(String, String)]) {
        var routes: [String] = [], rejected: [(String, String)] = []
        for line in output.split(whereSeparator: \.isNewline) {
            let body = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
            for token in body.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\t" }) {
                let t = String(token)
                if let p = problem(t) { rejected.append((t, p)); continue }
                let c = normalize(t)
                if !routes.contains(c) { routes.append(c) }
            }
        }
        return (Array(routes.prefix(maxRoutes)), rejected)
    }
}
