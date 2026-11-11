import Foundation
import WGCore

struct RouteEntry: Codable, Equatable {
    var family: String          // "inet" or "inet6"
    var destination: String
    var gateway: String?
    var interface: String?

    var targetArgs: [String] {
        if let gateway { return [gateway] }
        return ["-interface", interface ?? ""]
    }
}

struct DNSSetting: Codable, Equatable {
    var servers: [String]
    var searchDomains: [String]
}

enum NetworkConfigurator {
    static func family(of ip: String) -> String { Validation.isValidIPv6(ip) ? "inet6" : "inet" }

    // MARK: Interface

    static func addAddress(_ cidr: String, utun: String) throws {
        let ip = String(cidr.split(separator: "/")[0])
        if Validation.isValidIPv6(ip) {
            try Shell.run(.ifconfig, [utun, "inet6", cidr, "alias"])
        } else {
            try Shell.run(.ifconfig, [utun, "inet", cidr, ip, "alias"])
        }
    }

    static func setMTU(_ mtu: Int, utun: String) throws {
        try Shell.run(.ifconfig, [utun, "mtu", String(mtu)])
    }

    static func bringUp(_ utun: String) throws {
        try Shell.run(.ifconfig, [utun, "up"])
    }

    // MARK: Routes

    /// 0.0.0.0/0 and ::/0 are split into two /1 routes (wg-quick trick) so the
    /// original default route stays in place for the endpoint host route.
    static func expand(_ cidr: String) -> [String] {
        switch cidr {
        case "0.0.0.0/0": return ["0.0.0.0/1", "128.0.0.0/1"]
        case "::/0": return ["::/1", "8000::/1"]
        default: return [cidr]
        }
    }

    static func addRoute(_ r: RouteEntry) throws {
        try Shell.run(.route, ["-q", "-n", "add", "-\(r.family)", r.destination] + r.targetArgs)
    }

    static func deleteRoute(_ r: RouteEntry) {
        _ = try? Shell.run(.route, ["-q", "-n", "delete", "-\(r.family)", r.destination] + r.targetArgs, check: false)
    }

    /// Current default route for a family: gateway and/or interface.
    static func defaultRoute(family: String) -> (gateway: String?, interface: String?)? {
        guard let r = try? Shell.run(.route, ["-n", "get", "-\(family)", "default"], check: false), r.ok else { return nil }
        var gw: String?, iface: String?
        for line in r.stdout.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            if parts[0] == "gateway" { gw = parts[1] }
            if parts[0] == "interface" { iface = parts[1] }
        }
        if gw == nil && iface == nil { return nil }
        return (gw, iface)
    }

    /// Endpoint IPs as resolved by wg (`wg show <if> endpoints`).
    static func resolvedEndpointIPs(utun: String) -> [String] {
        guard let r = try? Shell.run(.wg, ["show", utun, "endpoints"]) else { return [] }
        return r.stdout.split(separator: "\n").compactMap { line in
            let f = line.split(separator: "\t")
            guard f.count == 2, f[1] != "(none)" else { return nil }
            let ep = String(f[1])
            if ep.hasPrefix("["), let close = ep.firstIndex(of: "]") {
                return String(ep[ep.index(after: ep.startIndex)..<close])
            }
            guard let colon = ep.lastIndex(of: ":") else { return nil }
            return String(ep[..<colon])
        }.filter(Validation.isValidIP)
    }

    // MARK: DNS

    static func networkServices() throws -> [String] {
        let out = try Shell.run(.networksetup, ["-listallnetworkservices"]).stdout
        return out.split(separator: "\n").dropFirst()          // header line
            .map(String.init)
            .filter { !$0.isEmpty && !$0.hasPrefix("*") }     // "*" = disabled
    }

    private static func listValue(_ args: [String]) throws -> [String] {
        let out = try Shell.run(.networksetup, args).stdout
        if out.contains("aren't any") { return [] }
        return out.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static func currentDNS(service: String) throws -> DNSSetting {
        DNSSetting(servers: try listValue(["-getdnsservers", service]),
                   searchDomains: try listValue(["-getsearchdomains", service]))
    }

    static func apply(_ s: DNSSetting, to service: String) throws {
        try Shell.run(.networksetup, ["-setdnsservers", service] + (s.servers.isEmpty ? ["Empty"] : s.servers))
        try Shell.run(.networksetup, ["-setsearchdomains", service] + (s.searchDomains.isEmpty ? ["Empty"] : s.searchDomains))
    }
}
