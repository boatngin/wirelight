import Foundation
import WGCore

/// Kill switch: a pf anchor that blocks everything except the tunnel interface,
/// the VPN endpoint IPs and local LAN ranges. Loaded only while a tunnel with the
/// kill switch enabled is up (or has dropped unexpectedly); always removed on a
/// clean disconnect and on helper start-up recovery.
///
/// The anchor lives under `com.apple/` because the stock macOS `/etc/pf.conf`
/// already evaluates `anchor "com.apple/*"`; an anchor with any other name would
/// be loaded but never consulted. pf is enabled with `pfctl -E`, which takes a
/// reference token, and released with `pfctl -X <token>`, so we never turn pf off
/// under other software (or the user) that also relies on it.
enum PFGuard {
    static let anchor = "com.apple/250.wgbar"
    static let anchorPath = "/etc/pf.anchors/wgbar.killswitch"
    /// Persisted pf enable token, so a restarted helper can still release it.
    static let tokenPath = "/var/run/wgbar.pf.token"
    static let marker = "# managed by wgbar:"

    /// Private/link-local/multicast ranges that stay reachable so LAN keeps working.
    static let lanCIDRs = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16",
                           "224.0.0.0/4", "255.255.255.255/32",
                           "fe80::/10", "fc00::/7", "ff00::/8"]

    static func rules(utun: String, endpointIPs: [String]) -> String {
        var lines = [marker,
                     "pass quick on lo0 all",
                     "pass quick on \(utun) all",
                     // DHCP, so the machine can still get an address on a new network.
                     "pass quick proto udp from any port 68 to any port 67",
                     "pass quick proto udp from any port 67 to any port 68"]
        for ip in endpointIPs where Validation.isValidIP(ip) {
            lines.append("pass quick to \(ip)")
            lines.append("pass quick from \(ip)")
        }
        for cidr in lanCIDRs {
            lines.append("pass quick to \(cidr)")
            lines.append("pass quick from \(cidr)")
        }
        lines.append("block drop quick all")
        return lines.joined(separator: "\n") + "\n"
    }

    /// Writes the anchor file, loads it into pf and takes a pf enable reference.
    /// Safe to call repeatedly (rules are replaced, the token is taken once).
    static func install(utun: String, endpointIPs: [String]) throws {
        try rules(utun: utun, endpointIPs: endpointIPs).write(toFile: anchorPath, atomically: true, encoding: .utf8)
        chmod(anchorPath, 0o644)
        try Shell.run(.pfctl, ["-a", anchor, "-f", anchorPath])
        if loadToken() == nil {
            let r = try Shell.run(.pfctl, ["-E"])
            guard let token = parseToken(r.stdout + "\n" + r.stderr) else {
                throw ShellError.failed(tool: "pfctl", args: ["-E"], status: 0, stderr: "no enable token in output")
            }
            try token.write(toFile: tokenPath, atomically: true, encoding: .utf8)
            chmod(tokenPath, 0o600)
        }
    }

    /// Flushes the anchor, deletes the file and releases our pf enable reference.
    static func remove() {
        _ = try? Shell.run(.pfctl, ["-a", anchor, "-F", "all"], check: false)
        unlink(anchorPath)
        if let token = loadToken() {
            _ = try? Shell.run(.pfctl, ["-X", token], check: false)
            unlink(tokenPath)
        }
    }

    /// Extracts the reference token from `pfctl -E` output ("Token : 1234567890").
    static func parseToken(_ output: String) -> String? {
        for line in output.split(separator: "\n") where line.hasPrefix("Token") {
            let value = line.split(separator: ":", maxSplits: 1).last?
                .trimmingCharacters(in: .whitespaces) ?? ""
            if !value.isEmpty, value.allSatisfy(\.isNumber) { return value }
        }
        return nil
    }

    private static func loadToken() -> String? {
        guard let s = try? String(contentsOfFile: tokenPath, encoding: .utf8) else { return nil }
        // Round-trip through an integer so only a plain decimal token ever reaches pfctl's argv.
        guard let n = UInt64(s.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return String(n)
    }
}
