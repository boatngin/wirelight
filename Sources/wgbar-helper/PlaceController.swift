import Foundation
import WGCore

/// One proxy entry as networksetup reports it.
struct ProxyServer: Codable, Equatable {
    var host: String
    var port: Int
    var enabled: Bool
}

/// The proxy state of a network service, enough to put it back exactly.
struct ProxyState: Codable, Equatable {
    var web: ProxyServer?
    var secure: ProxyServer?
    var socks: ProxyServer?
    var pacURL: String?
    var pacEnabled = false
    var bypass: [String] = []

    /// Parses `networksetup -getwebproxy` style output ("Enabled: Yes", "Server: x", "Port: 8080").
    static func parseServer(_ text: String) -> ProxyServer? {
        var enabled = false, host = "", port = 0
        for line in text.split(separator: "\n") {
            let kv = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard kv.count == 2 else { continue }
            switch kv[0] {
            case "Enabled": enabled = kv[1] == "Yes"
            case "Server": host = kv[1]
            case "Port": port = Int(kv[1]) ?? 0
            default: break
            }
        }
        guard !host.isEmpty || enabled else { return nil }
        return ProxyServer(host: host, port: port, enabled: enabled)
    }

    /// Parses `-getautoproxyurl` ("URL: …", "Enabled: Yes").
    static func parsePAC(_ text: String) -> (url: String?, enabled: Bool) {
        var url: String?, enabled = false
        for line in text.split(separator: "\n") {
            let kv = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard kv.count == 2 else { continue }
            if kv[0] == "URL", kv[1] != "(null)" { url = kv[1] }
            if kv[0] == "Enabled" { enabled = kv[1] == "Yes" }
        }
        return (url, enabled)
    }

    init(web: ProxyServer? = nil, secure: ProxyServer? = nil, socks: ProxyServer? = nil,
         pacURL: String? = nil, pacEnabled: Bool = false, bypass: [String] = []) {
        self.web = web; self.secure = secure; self.socks = socks
        self.pacURL = pacURL; self.pacEnabled = pacEnabled; self.bypass = bypass
    }

    init(_ s: ProxySetting) {
        func server(_ ep: String?) -> ProxyServer? {
            guard s.mode == .manual, let ep, let colon = ep.lastIndex(of: ":") else { return nil }
            var host = String(ep[..<colon])
            if host.hasPrefix("[") { host = String(host.dropFirst().dropLast()) }
            return ProxyServer(host: host, port: Int(ep[ep.index(after: colon)...]) ?? 0, enabled: true)
        }
        self.init(web: server(s.http), secure: server(s.https), socks: server(s.socks),
                  pacURL: s.mode == .auto ? s.pacURL : nil, pacEnabled: s.mode == .auto, bypass: s.bypass)
    }
}

/// What the helper changed for the active Place, persisted so a crash can be undone.
struct PlaceState: Codable {
    var service: String
    var originalDNS: DNSSetting?
    var originalProxy: ProxyState?
}

extension TunnelController {
    static var placePath: String { "\(stateDir)/place.json" }

    /// Network service (as networksetup names it) that carries the IPv4 default route.
    static func defaultService() -> String? {
        guard let dev = NetworkConfigurator.defaultRoute(family: "inet")?.interface,
              let out = try? Shell.run(.networksetup, ["-listnetworkserviceorder"]).stdout else { return nil }
        var lastName: String?
        for line in out.split(separator: "\n").map(String.init) {
            if line.hasPrefix("("), let close = line.firstIndex(of: ")"), !line.hasPrefix("(Hardware") {
                lastName = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
            } else if line.contains("Device: \(dev))"), let name = lastName {
                return name
            }
        }
        return nil
    }

    func loadPlace() -> PlaceState? {
        guard let d = FileManager.default.contents(atPath: Self.placePath) else { return nil }
        return try? JSONDecoder().decode(PlaceState.self, from: d)
    }

    private func savePlace(_ p: PlaceState?) {
        guard let p, let d = try? JSONEncoder().encode(p) else { unlink(Self.placePath); return }
        try? d.write(to: URL(fileURLWithPath: Self.placePath), options: .atomic)
        chmod(Self.placePath, 0o600)
    }

    /// Applies a Place's DNS and proxy, always on top of the service's saved original,
    /// or restores the original when `settings` is nil.
    func applyPlace(_ settings: PlaceNetworkSettings?) throws {
        if let err = settings?.validationError() { throw TunnelError.interfaceStartFailed(err) }
        var current = loadPlace()
        let target = settings == nil ? nil : Self.defaultService()
        // The Place ended, or the default route moved to another service: put the old one back first.
        if let c = current, c.service != target {
            restorePlace(c)
            current = nil
        }
        guard let settings, let service = target else { savePlace(nil); return }
        var state = current ?? PlaceState(service: service)
        if let dns = settings.dnsServers {
            if state.originalDNS == nil { state.originalDNS = try NetworkConfigurator.currentDNS(service: service) }
            savePlace(state)
            setDNS(DNSSetting(servers: dns, searchDomains: state.originalDNS?.searchDomains ?? []), service: service)
        } else if let original = state.originalDNS {
            setDNS(original, service: service)
            state.originalDNS = nil
        }
        if let proxy = settings.proxy {
            if state.originalProxy == nil { state.originalProxy = readProxy(service) }
            savePlace(state)
            try writeProxy(ProxyState(proxy), service: service)
        } else if let original = state.originalProxy {
            try? writeProxy(original, service: service)
            state.originalProxy = nil
        }
        savePlace(state.originalDNS == nil && state.originalProxy == nil ? nil : state)
        log("place applied on '\(service)' (dns: \(settings.dnsServers?.count ?? 0), proxy: \(settings.proxy?.mode.rawValue ?? "unchanged"))")
    }

    private func restorePlace(_ p: PlaceState) {
        if let dns = p.originalDNS { setDNS(dns, service: p.service) }
        if let proxy = p.originalProxy { try? writeProxy(proxy, service: p.service) }
        log("place restored on '\(p.service)'")
    }

    /// A connected tunnel that set DNS owns the service: change what it will restore
    /// instead of overriding the tunnel's DNS now.
    private func setDNS(_ s: DNSSetting, service: String) {
        if handOverTunnelDNSBackup(service: service, to: s) { return }
        do { try NetworkConfigurator.apply(s, to: service) }
        catch { log("place: cannot set DNS on '\(service)': \(error)", error: true) }
    }

    func readProxy(_ service: String) -> ProxyState {
        func out(_ flag: String) -> String { (try? Shell.run(.networksetup, [flag, service]).stdout) ?? "" }
        let pac = ProxyState.parsePAC(out("-getautoproxyurl"))
        let bypassText = out("-getproxybypassdomains")
        let bypass = bypassText.contains("aren't any") ? [] :
            bypassText.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return ProxyState(web: ProxyState.parseServer(out("-getwebproxy")),
                          secure: ProxyState.parseServer(out("-getsecurewebproxy")),
                          socks: ProxyState.parseServer(out("-getsocksfirewallproxy")),
                          pacURL: pac.url, pacEnabled: pac.enabled, bypass: bypass)
    }

    func writeProxy(_ p: ProxyState, service: String) throws {
        for (server, set, state) in [(p.web, "-setwebproxy", "-setwebproxystate"),
                                     (p.secure, "-setsecurewebproxy", "-setsecurewebproxystate"),
                                     (p.socks, "-setsocksfirewallproxy", "-setsocksfirewallproxystate")] {
            if let s = server, !s.host.isEmpty, s.port > 0 {
                try Shell.run(.networksetup, [set, service, s.host, String(s.port)])
            }
            try Shell.run(.networksetup, [state, service, server?.enabled == true ? "on" : "off"])
        }
        if let url = p.pacURL { try Shell.run(.networksetup, ["-setautoproxyurl", service, url]) }
        try Shell.run(.networksetup, ["-setautoproxystate", service, p.pacEnabled ? "on" : "off"])
        try Shell.run(.networksetup, ["-setproxybypassdomains", service] + (p.bypass.isEmpty ? ["Empty"] : p.bypass))
    }

    func flushDNS() {
        _ = try? Shell.run(.dscacheutil, ["-flushcache"], check: false)
        _ = try? Shell.run(.killall, ["-HUP", "mDNSResponder"], check: false)
        log("DNS cache flushed")
    }
}
