import AppKit
import Foundation
import WGCore

/// One thing the Doctor noticed, with what it saw.
struct DoctorFinding: Identifiable {
    enum Level: Int { case info, warning, problem }
    let level: Level
    let title: String
    let detail: String
    let evidence: String
    var id: String { title + evidence }
}

/// Looks for other VPNs and for routes and DNS that fight the tunnels. Reads only;
/// nothing here needs root.
@MainActor
enum NetworkDoctor {
    /// Apps that bring their own VPN or tunnel, by bundle id fragment.
    static let knownVPNs: [(String, String)] = [
        ("tailscale", "Tailscale"), ("mullvad", "Mullvad VPN"), ("protonvpn", "Proton VPN"), ("nordvpn", "NordVPN"),
        ("expressvpn", "ExpressVPN"), ("surfshark", "Surfshark"), ("cisco.anyconnect", "Cisco AnyConnect"),
        ("cisco.secureclient", "Cisco Secure Client"), ("paloaltonetworks.globalprotect", "GlobalProtect"),
        ("fortinet", "FortiClient"), ("zerotier", "ZeroTier"), ("cloudflare.1dot1dot1dot1", "Cloudflare WARP"),
        ("netbird", "NetBird"), ("wireguard.macos", "WireGuard (official app)"), ("openvpn", "OpenVPN"),
        ("tunnelblick", "Tunnelblick"), ("viscosity", "Viscosity"), ("pritunl", "Pritunl"),
    ]

    static func scan(_ store: TunnelStore) async -> [DoctorFinding] {
        var out: [DoctorFinding] = []
        let ours = Set(store.statuses.values.map(\.interface))

        // Other VPN apps running.
        let running = NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier?.lowercased() }
        for (frag, name) in knownVPNs where running.contains(where: { $0.contains(frag) }) {
            out.append(DoctorFinding(level: .warning, title: "\(name) is running",
                                     detail: "Two VPNs can fight over routes and DNS. If a tunnel misbehaves, try with \(name) off.",
                                     evidence: running.first { $0.contains(frag) } ?? frag))
        }

        // Tunnel interfaces that aren't ours.
        let foreign = interfaces().filter { ($0.hasPrefix("utun") || $0.hasPrefix("ipsec") || $0.hasPrefix("ppp")) && !ours.contains($0) }
            .filter { !systemUtuns.contains($0) }
        if !foreign.isEmpty {
            out.append(DoctorFinding(level: .info, title: "Other tunnel interfaces with addresses",
                                     detail: "Another VPN or the system (iCloud Private Relay, Back to My Mac) owns these.",
                                     evidence: foreign.joined(separator: ", ")))
        }

        // Default route taken by someone else.
        if let iface = await routeInterface("default"), iface.hasPrefix("utun"), !ours.contains(iface) {
            out.append(DoctorFinding(level: .problem, title: "Another VPN owns the default route",
                                     detail: "Internet traffic goes through \(iface), which isn't a Wirelight tunnel. Route-all tunnels won't get it.",
                                     evidence: "route get default → \(iface)"))
        }

        let lans = LocalAddresses.ipv4Subnets()
        var claimed: [(String, String)] = []
        for name in store.activeNames {
            guard let st = store.status(name) else { continue }
            let allowed = (store.config(name)?.peers.flatMap(\.allowedIPs) ?? []).filter { !$0.hasSuffix("/0") }
            for cidr in allowed {
                // Our range on the local LAN: local devices or the tunnel become unreachable.
                for lan in lans where CIDR.overlaps(lan, cidr) {
                    out.append(DoctorFinding(level: .warning, title: "\(name) routes your local network",
                                             detail: "\(cidr) overlaps the LAN you're on (\(lan)). Either local devices or the remote side won't be reachable. Use a narrower range or exclude local hosts.",
                                             evidence: "LAN \(lan) ∩ AllowedIPs \(cidr)"))
                }
                // Two of our tunnels claim the same range.
                if let other = claimed.first(where: { $0.0 != name && CIDR.overlaps($0.1, cidr) }) {
                    out.append(DoctorFinding(level: .warning, title: "\(name) and \(other.0) both route \(cidr)",
                                             detail: "Only the more specific route wins, so one tunnel won't get this traffic.",
                                             evidence: "\(other.1) ∩ \(cidr)"))
                }
                claimed.append((name, cidr))
                // The routing table sends the range somewhere else.
                let probe = String(cidr.split(separator: "/")[0])
                if let iface = await routeInterface(probe), iface != st.interface,
                   !lans.contains(where: { CIDR.contains($0, probe) }) {
                    out.append(DoctorFinding(level: .problem, title: "\(name)'s traffic for \(cidr) leaves via \(iface)",
                                             detail: "A more specific route from another app or VPN wins over the tunnel.",
                                             evidence: "route get \(probe) → \(iface), expected \(st.interface)"))
                }
            }
        }

        // DNS: someone else overriding a tunnel's DNS, and foreign /etc/resolver files.
        let dns = await systemNameservers()
        for name in store.activeNames {
            guard let p = store.profile(name), p.splitDNSDomains.isEmpty,
                  let servers = store.config(name)?.interface.dns, !servers.isEmpty, let first = dns.first else { continue }
            if !servers.contains(first) {
                out.append(DoctorFinding(level: .warning, title: "\(name)'s DNS isn't the one in use",
                                         detail: "macOS asks \(first) first, not the tunnel's \(servers.joined(separator: ", ")). Another VPN, a Place or a DNS app may be overriding it.",
                                         evidence: "scutil --dns resolver #1: \(dns.joined(separator: ", "))"))
            }
        }
        let foreignResolvers = ((try? FileManager.default.contentsOfDirectory(atPath: "/etc/resolver")) ?? []).filter { f in
            let text = (try? String(contentsOfFile: "/etc/resolver/\(f)", encoding: .utf8)) ?? ""
            return !text.hasPrefix("# managed by wgbar:")
        }
        if !foreignResolvers.isEmpty {
            out.append(DoctorFinding(level: .info, title: "Resolver files from other software",
                                     detail: "These domains use their own DNS servers whatever Wirelight sets.",
                                     evidence: foreignResolvers.sorted().map { "/etc/resolver/\($0)" }.joined(separator: ", ")))
        }
        return out.sorted { $0.level.rawValue > $1.level.rawValue }
    }

    /// utun0–3 are created by macOS itself on most Macs (keepalive, iCloud services).
    static let systemUtuns: Set<String> = ["utun0", "utun1", "utun2", "utun3"]

    /// Interfaces that have at least one non-link-local address.
    static func interfaces() -> [String] {
        var out = Set<String>()
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return [] }
        defer { freeifaddrs(head) }
        var p = head
        while let ifa = p?.pointee {
            defer { p = ifa.ifa_next }
            guard let sa = ifa.ifa_addr, [AF_INET, AF_INET6].contains(Int32(sa.pointee.sa_family)) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            if !String(cString: host).lowercased().hasPrefix("fe80") { out.insert(String(cString: ifa.ifa_name)) }
        }
        return out.sorted()
    }

    static func run(_ path: String, _ args: [String]) async -> String {
        await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: path)
                p.arguments = args
                let out = Pipe()
                p.standardOutput = out
                p.standardError = Pipe()
                guard (try? p.run()) != nil else { cont.resume(returning: ""); return }
                let d = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                cont.resume(returning: String(decoding: d, as: UTF8.self))
            }
        }
    }

    static func routeInterface(_ dest: String) async -> String? {
        let out = await run("/sbin/route", ["-n", "get", dest])
        return out.split(separator: "\n").first { $0.contains("interface:") }?
            .split(separator: ":").last?.trimmingCharacters(in: .whitespaces)
    }

    /// Nameservers of resolver #1 in `scutil --dns`, the one used for most lookups.
    static func systemNameservers() async -> [String] {
        let out = await run("/usr/sbin/scutil", ["--dns"])
        var servers: [String] = []
        var inFirst = false
        for line in out.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("resolver #") { if inFirst { break }; inFirst = t == "resolver #1" }
            if inFirst, t.hasPrefix("nameserver["), let v = t.split(separator: ":", maxSplits: 1).last {
                servers.append(v.trimmingCharacters(in: .whitespaces))
            }
        }
        return servers
    }
}
