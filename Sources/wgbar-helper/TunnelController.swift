import Foundation
import WGCore

struct TunnelState: Codable {
    var name: String
    var utun: String
    var routes: [RouteEntry] = []
    /// Original DNS per network service; nil when the config set no DNS.
    var dnsBackup: [String: DNSSetting]?
    // Added in phase 7 (optional so older state files still decode).
    /// Peer public key -> endpoint as written in the config (may be a hostname).
    var peerEndpoints: [String: String]?
    var full4: Bool?
    var full6: Bool?
    var dnsWanted: DNSSetting?
    /// CIDRs routed via the physical default gateway (re-pinned on network change).
    var excludedCIDRs: [String]?
    /// /etc/resolver files we created for split DNS.
    var resolverFiles: [String]?
}

enum TunnelError: Error, CustomStringConvertible {
    case invalidName(String)
    case alreadyUp(String)
    case notUp(String)
    case interfaceStartFailed(String)

    var description: String {
        switch self {
        case let .invalidName(n): return "invalid tunnel name '\(n)'"
        case let .alreadyUp(n): return "tunnel '\(n)' is already up"
        case let .notUp(n): return "tunnel '\(n)' is not up"
        case let .interfaceStartFailed(m): return "wireguard-go failed: \(m)"
        }
    }
}

/// Owns all tunnel lifecycle. Called serially from the socket server thread.
final class TunnelController {
    /// wireguard-go sockets and name files (cleared on reboot).
    static let runDir = "/var/run/wireguard"
    /// Persistent state so DNS can be restored even after a crash or reboot.
    static let stateDir = "/Library/Application Support/WGBar/state"
    static let defaultMTU = 1420

    private var tunnels: [String: TunnelState] = [:]
    private let fm = FileManager.default

    init() {
        for dir in [Self.runDir, Self.stateDir] {
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        }
    }

    private func statePath(_ name: String) -> String { "\(Self.stateDir)/\(name).state.json" }
    private func nameFile(_ name: String) -> String { "\(Self.runDir)/\(name).name" }
    private func uapiSocket(_ utun: String) -> String { "\(Self.runDir)/\(utun).sock" }

    private func save(_ s: TunnelState) {
        tunnels[s.name] = s
        do {
            let data = try JSONEncoder().encode(s)
            try data.write(to: URL(fileURLWithPath: statePath(s.name)), options: .atomic)
            chmod(statePath(s.name), 0o600)
        } catch {
            log("failed to save state for \(s.name): \(error)", error: true)
        }
    }

    // MARK: up

    static let resolverDir = "/etc/resolver"
    static let resolverMarker = "# managed by wgbar:"

    func up(name: String, configText: String, options: UpOptions = UpOptions()) throws {
        if let err = options.validationError() { throw TunnelError.interfaceStartFailed(err) }
        guard Validation.isValidTunnelName(name) else { throw TunnelError.invalidName(name) }
        guard tunnels[name] == nil else { throw TunnelError.alreadyUp(name) }
        // Always re-validate: never trust the client.
        let config = try WGConfig(parsing: configText)

        try? fm.removeItem(atPath: nameFile(name))
        try Shell.run(.wireguardGo, ["utun"], env: ["WG_TUN_NAME_FILE": nameFile(name)], captureOutput: false)

        guard let raw = try? String(contentsOfFile: nameFile(name), encoding: .utf8) else {
            throw TunnelError.interfaceStartFailed("no interface name written")
        }
        let utun = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard utun.range(of: "^utun[0-9]+$", options: .regularExpression) != nil else {
            throw TunnelError.interfaceStartFailed("unexpected interface name '\(utun)'")
        }
        log("\(name): wireguard-go started on \(utun)")

        var state = TunnelState(name: name, utun: utun)
        state.excludedCIDRs = options.excludedCIDRs
        state.peerEndpoints = Dictionary(uniqueKeysWithValues: config.peers.compactMap { p in
            p.endpoint.map { (p.publicKey, $0) }
        })
        save(state) // persist immediately so a crash mid-setup can be cleaned up

        do {
            try waitForUAPI(utun)
            try setconf(config, utun: utun, name: name)

            for addr in config.interface.addresses { try NetworkConfigurator.addAddress(addr, utun: utun) }
            try NetworkConfigurator.setMTU(config.interface.mtu ?? Self.defaultMTU, utun: utun)
            try NetworkConfigurator.bringUp(utun)

            try addRoutes(config, state: &state)
            if options.splitDNSDomains.isEmpty {
                try applyDNS(config, state: &state)
            } else {
                try applySplitDNS(config, domains: options.splitDNSDomains, state: &state)
            }
            log("\(name): up on \(utun) (\(state.routes.count) routes, dns \(state.dnsBackup == nil ? "unchanged" : "set"))")
        } catch {
            log("\(name): up failed, rolling back: \(error)", error: true)
            teardown(state)
            throw error
        }
    }

    private func waitForUAPI(_ utun: String) throws {
        for _ in 0..<30 {
            if fm.fileExists(atPath: uapiSocket(utun)) { return }
            usleep(100_000)
        }
        throw TunnelError.interfaceStartFailed("control socket for \(utun) did not appear")
    }

    /// Writes the setconf text to a root-only temp file, applies it, then deletes it.
    private func setconf(_ config: WGConfig, utun: String, name: String) throws {
        let path = "\(Self.runDir)/\(name).setconf"
        unlink(path)
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw UnixSocketError.system("open setconf", errno) }
        defer { unlink(path) }
        do {
            try UnixSocket.writeAll(fd, Data(config.wgSetconfText().utf8))
            close(fd)
        } catch {
            close(fd)
            throw error
        }
        try Shell.run(.wg, ["setconf", utun, path])
    }

    private func addRoutes(_ config: WGConfig, state: inout TunnelState) throws {
        var allowed: [String] = []
        for cidr in config.peers.flatMap(\.allowedIPs) where !allowed.contains(cidr) { allowed.append(cidr) }
        state.full4 = allowed.contains("0.0.0.0/0")
        state.full6 = allowed.contains("::/0")
        // Full tunnel: pin each endpoint to the original default gateway first.
        try pinEndpoints(state: &state)

        for cidr in allowed {
            let fam = NetworkConfigurator.family(of: String(cidr.split(separator: "/")[0]))
            for dest in NetworkConfigurator.expand(cidr) {
                try addRoute(RouteEntry(family: fam, destination: dest, gateway: nil, interface: state.utun), state: &state)
            }
        }
    }

    /// Host routes that keep endpoint traffic on the physical default route (full tunnel only).
    private func pinEndpoints(state: inout TunnelState) throws {
        // Excluded CIDRs always go out the physical default route.
        for cidr in state.excludedCIDRs ?? [] {
            let fam = NetworkConfigurator.family(of: String(cidr.split(separator: "/")[0]))
            guard let def = NetworkConfigurator.defaultRoute(family: fam), def.interface != state.utun else { continue }
            try addRoute(RouteEntry(family: fam, destination: cidr, gateway: def.gateway,
                                    interface: def.gateway == nil ? def.interface : nil), state: &state)
        }
        let full4 = state.full4 ?? false, full6 = state.full6 ?? false
        guard full4 || full6 else { return }
        for ip in NetworkConfigurator.resolvedEndpointIPs(utun: state.utun) {
            let fam = NetworkConfigurator.family(of: ip)
            guard (fam == "inet" && full4) || (fam == "inet6" && full6),
                  let def = NetworkConfigurator.defaultRoute(family: fam),
                  def.interface != state.utun else { continue }
            let r = RouteEntry(family: fam, destination: ip, gateway: def.gateway,
                               interface: def.gateway == nil ? def.interface : nil)
            try addRoute(r, state: &state)
        }
    }

    private func isEndpointRoute(_ r: RouteEntry, utun: String) -> Bool { r.interface != utun }

    private func addRoute(_ r: RouteEntry, state: inout TunnelState) throws {
        do {
            try NetworkConfigurator.addRoute(r)
            state.routes.append(r)
            save(state)
        } catch let ShellError.failed(_, _, _, stderr) where stderr.contains("File exists") {
            log("\(state.name): route \(r.destination) already exists, skipping")
        }
    }

    /// Split DNS: one /etc/resolver/<domain> file per domain, pointing at the tunnel DNS.
    private func applySplitDNS(_ config: WGConfig, domains: [String], state: inout TunnelState) throws {
        let servers = config.interface.dns
        guard !servers.isEmpty else { throw TunnelError.interfaceStartFailed("split DNS needs DNS servers in the config") }
        try fm.createDirectory(atPath: Self.resolverDir, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o755])
        var files = state.resolverFiles ?? []
        for domain in domains {
            let d = domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            let path = "\(Self.resolverDir)/\(d)"
            // Never overwrite a resolver file someone else created.
            if fm.fileExists(atPath: path), !isOurs(path, name: state.name) {
                log("\(state.name): \(path) exists and is not ours, skipping", error: true)
                continue
            }
            let body = "\(Self.resolverMarker)\(state.name)\n" + servers.map { "nameserver \($0)" }.joined(separator: "\n") + "\n"
            try body.write(toFile: path, atomically: true, encoding: .utf8)
            chmod(path, 0o644)
            files.append(path)
            state.resolverFiles = files
            save(state)
        }
    }

    private func isOurs(_ path: String, name: String) -> Bool {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return false }
        return text.hasPrefix("\(Self.resolverMarker)\(name)\n")
    }

    private func applyDNS(_ config: WGConfig, state: inout TunnelState) throws {
        let iface = config.interface
        guard !iface.dns.isEmpty || !iface.dnsSearch.isEmpty else { return }

        var backup: [String: DNSSetting] = [:]
        for svc in try NetworkConfigurator.networkServices() {
            do { backup[svc] = try NetworkConfigurator.currentDNS(service: svc) }
            catch { log("\(state.name): cannot read DNS for '\(svc)': \(error)", error: true) }
        }
        state.dnsBackup = backup
        save(state) // backup must be on disk before we change anything

        let wanted = DNSSetting(servers: iface.dns, searchDomains: iface.dnsSearch)
        state.dnsWanted = wanted
        save(state)
        for svc in backup.keys.sorted() {
            do { try NetworkConfigurator.apply(wanted, to: svc) }
            catch { log("\(state.name): cannot set DNS for '\(svc)': \(error)", error: true) }
        }
    }

    // MARK: down

    func down(name: String) throws {
        guard Validation.isValidTunnelName(name) else { throw TunnelError.invalidName(name) }
        guard let state = tunnels[name] else { throw TunnelError.notUp(name) }
        teardown(state)
        log("\(name): down")
    }

    /// Best-effort reverse of `up`: DNS → routes → interface → state files.
    private func teardown(_ state: TunnelState) {
        if let backup = state.dnsBackup {
            for (svc, setting) in backup.sorted(by: { $0.key < $1.key }) {
                do { try NetworkConfigurator.apply(setting, to: svc) }
                catch { log("\(state.name): cannot restore DNS for '\(svc)': \(error)", error: true) }
            }
        }
        for path in state.resolverFiles ?? [] where path.hasPrefix(Self.resolverDir + "/") && isOurs(path, name: state.name) {
            unlink(path)
        }
        for r in state.routes.reversed() { NetworkConfigurator.deleteRoute(r) }
        // Removing the UAPI socket makes wireguard-go exit and destroy the utun.
        unlink(uapiSocket(state.utun))
        unlink(nameFile(state.name))
        unlink(statePath(state.name))
        tunnels[state.name] = nil
    }

    // MARK: refresh (wake / network change)

    /// Re-resolves hostname endpoints, re-pins endpoint host routes to the current
    /// default gateway and applies tunnel DNS to network services that appeared later.
    func refresh() {
        for var state in tunnels.values.sorted(by: { $0.name < $1.name }) {
            for (pk, ep) in (state.peerEndpoints ?? [:]).sorted(by: { $0.key < $1.key })
            where Validation.isValidKey(pk) && Validation.isValidEndpoint(ep) {
                do { try Shell.run(.wg, ["set", state.utun, "peer", pk, "endpoint", ep]) }
                catch { log("\(state.name): cannot re-resolve endpoint \(ep): \(error)", error: true) }
            }

            if state.full4 == true || state.full6 == true || !(state.excludedCIDRs ?? []).isEmpty {
                for r in state.routes where isEndpointRoute(r, utun: state.utun) { NetworkConfigurator.deleteRoute(r) }
                state.routes.removeAll { isEndpointRoute($0, utun: state.utun) }
                save(state)
                do { try pinEndpoints(state: &state) }
                catch { log("\(state.name): cannot re-pin endpoint routes: \(error)", error: true) }
            }

            if let wanted = state.dnsWanted, var backup = state.dnsBackup,
               let services = try? NetworkConfigurator.networkServices() {
                for svc in services where backup[svc] == nil {
                    guard let original = try? NetworkConfigurator.currentDNS(service: svc) else { continue }
                    backup[svc] = original
                    state.dnsBackup = backup
                    save(state)
                    do {
                        try NetworkConfigurator.apply(wanted, to: svc)
                        log("\(state.name): applied tunnel DNS to new service '\(svc)'")
                    } catch { log("\(state.name): cannot set DNS for '\(svc)': \(error)", error: true) }
                }
            }
            log("\(state.name): refreshed")
        }
    }

    private var lastNetworkSignature: String?

    /// Called periodically; triggers `refresh()` when the default route changes.
    func checkNetworkChange() {
        guard !tunnels.isEmpty else { lastNetworkSignature = nil; return }
        let sig = ["inet", "inet6"].map { fam -> String in
            guard let d = NetworkConfigurator.defaultRoute(family: fam) else { return "\(fam):-" }
            return "\(fam):\(d.gateway ?? "")@\(d.interface ?? "")"
        }.joined(separator: " ")
        defer { lastNetworkSignature = sig }
        if let last = lastNetworkSignature, last != sig {
            log("default route changed (\(last) -> \(sig)), refreshing")
            refresh()
        }
    }

    // MARK: doctor

    func doctor() -> [String] {
        var out: [String] = []
        for tool in [Tool.wireguardGo, .wg, .ifconfig, .route, .networksetup] {
            if let url = try? Shell.resolve(tool) {
                var note = ""
                if let attrs = try? fm.attributesOfItem(atPath: url.resolvingSymlinksInPath().path),
                   let owner = attrs[.ownerAccountID] as? NSNumber, owner.intValue != 0 {
                    note = " (not root-owned: a local user could replace it)"
                }
                out.append("ok    \(tool.rawValue): \(url.path)\(note)")
            } else {
                out.append("FAIL  \(tool.rawValue): not found")
            }
        }
        let tracked = Set(tunnels.values.map(\.utun))
        for s in tunnels.values.sorted(by: { $0.name < $1.name }) {
            let alive = fm.fileExists(atPath: uapiSocket(s.utun))
            out.append("\(alive ? "ok  " : "FAIL")  tunnel \(s.name) on \(s.utun)\(alive ? "" : " (control socket missing)")")
        }
        let socks = ((try? fm.contentsOfDirectory(atPath: Self.runDir)) ?? []).filter { $0.hasSuffix(".sock") }
        for sock in socks.sorted() {
            let utun = String(sock.dropLast(5))
            if !tracked.contains(utun) {
                out.append("warn  \(utun) has a wireguard socket but is not managed by wgbar (wg-quick? leftover?)")
            }
        }
        if tunnels.isEmpty { out.append("ok    no active tunnels") }
        return out
    }

    // MARK: status / recovery

    func status() -> [TunnelStatus] {
        tunnels.values.sorted { $0.name < $1.name }.map { s in
            let dump = (try? Shell.run(.wg, ["show", s.utun, "dump"]))?.stdout ?? ""
            return TunnelStatus(name: s.name, interface: s.utun, peers: WGDump.parsePeers(dump))
        }
    }

    /// On start: re-adopt tunnels that are still alive, clean up the rest.
    func recoverOnStart() {
        guard let files = try? fm.contentsOfDirectory(atPath: Self.stateDir) else { return }
        for file in files where file.hasSuffix(".state.json") {
            let path = "\(Self.stateDir)/\(file)"
            guard let data = fm.contents(atPath: path),
                  let s = try? JSONDecoder().decode(TunnelState.self, from: data),
                  Validation.isValidTunnelName(s.name),
                  s.utun.range(of: "^utun[0-9]+$", options: .regularExpression) != nil else {
                log("removing unreadable state file \(file)", error: true)
                unlink(path)
                continue
            }
            if fm.fileExists(atPath: uapiSocket(s.utun)) {
                tunnels[s.name] = s
                log("\(s.name): re-adopted running tunnel on \(s.utun)")
            } else {
                log("\(s.name): cleaning up stale state from previous run")
                teardown(s)
            }
        }
    }
}
