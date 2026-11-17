import AppKit
import Foundation
import Network
import WGCore

/// A network this Mac joins, and what to change while on it: DNS, proxy, tunnels, a Shortcut.
struct Place: Codable, Identifiable, Equatable {
    enum DNSMode: String, Codable, CaseIterable { case keep, cloudflare, quad9, google, custom }

    var id = UUID()
    var name: String
    var kind: NetworkRule.Kind = .wifi
    /// Wi-Fi names or Ethernet subnets; empty matches any network of that kind.
    var values: [String] = []
    var dnsMode = DNSMode.keep
    var customDNS: [String] = []
    /// nil leaves the proxy alone.
    var proxy: ProxySetting?
    var connect: [String] = []
    var disconnect: [String] = []
    /// Name of a Shortcut to run when the Place starts.
    var shortcut = ""

    var dnsServers: [String]? {
        switch dnsMode {
        case .keep: return nil
        case .cloudflare: return DNSPreset.cloudflare.servers
        case .quad9: return DNSPreset.quad9.servers
        case .google: return DNSPreset.google.servers
        case .custom: return customDNS.isEmpty ? nil : customDNS
        }
    }

    var settings: PlaceNetworkSettings? {
        dnsServers == nil && proxy == nil ? nil : PlaceNetworkSettings(dnsServers: dnsServers, proxy: proxy)
    }

    func matches(_ n: NetworkSnapshot) -> Bool { NetworkRule(kind: kind, values: values, action: .connect).matches(n) }
}

/// Times one DNS query (A record for apple.com) over UDP to a server.
enum DNSProbe {
    static func latency(_ server: String, timeout: TimeInterval = 2) async -> Double? {
        await withCheckedContinuation { cont in
            let conn = NWConnection(host: NWEndpoint.Host(server), port: 53, using: .udp)
            let start = Date()
            var finished = false
            let lock = NSLock()
            func finish(_ v: Double?) {
                lock.lock(); defer { lock.unlock() }
                guard !finished else { return }
                finished = true
                conn.cancel()
                cont.resume(returning: v)
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    conn.send(content: query, completion: .contentProcessed { _ in })
                    conn.receiveMessage { data, _, _, _ in
                        // A reply with our id and the response bit set counts.
                        if let d = data, d.count >= 4, d[0] == 0x57, d[1] == 0x4c, d[2] & 0x80 != 0 {
                            finish(Date().timeIntervalSince(start) * 1000)
                        } else { finish(nil) }
                    }
                case .failed, .cancelled: finish(nil)
                default: break
                }
            }
            conn.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(nil) }
        }
    }

    /// id 0x574c, recursion desired, one question: apple.com IN A.
    static let query: Data = {
        var d = Data([0x57, 0x4c, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        for label in ["apple", "com"] { d.append(UInt8(label.count)); d.append(contentsOf: Array(label.utf8)) }
        d.append(contentsOf: [0x00, 0x00, 0x01, 0x00, 0x01])
        return d
    }()
}

extension TunnelStore {
    static let placesKey = "places"

    func loadPlaces() -> [Place] {
        guard let d = UserDefaults.standard.data(forKey: Self.placesKey),
              let list = try? JSONDecoder().decode([Place].self, from: d) else { return [] }
        return list
    }

    func savePlaces(_ list: [Place]) {
        places = list
        if !Self.isDemo { UserDefaults.standard.set(try? JSONEncoder().encode(list), forKey: Self.placesKey) }
    }

    /// The Place for a network: the first one in list order that matches.
    func place(for n: NetworkSnapshot) -> Place? { places.first { $0.matches(n) } }

    /// Called whenever the network may have changed. Applies only when the matching Place changes.
    func evaluatePlaces(_ n: NetworkSnapshot, force: Bool = false) async {
        if Self.isDemo { return }
        let next = place(for: n)
        guard force || next != activePlace else { return }
        let previous = activePlace
        activePlace = next
        placeProblem = nil
        let settings = next?.settings
        PlaceQuitHook.changedNetwork = settings != nil
        if settings != nil || previous?.settings != nil {
            do {
                let r = try await HelperClient.send(.applyPlace(settings), timeout: 20)
                if !r.ok { throw StoreError.helper(r.error ?? "unknown helper error") }
                if next?.dnsServers != nil || previous?.dnsServers != nil {
                    _ = try? await HelperClient.send(.flushDNS, timeout: 10)
                }
            } catch {
                placeProblem = "Couldn't apply \(next?.name ?? "the original settings"): \(error)"
                addLog(placeProblem!, isError: true)
            }
        }
        guard let p = next else {
            if let previous { addLog("Left place \(previous.name); network settings restored") }
            return
        }
        addLog("Place \(p.name) is active")
        for name in p.disconnect where isActive(name) { await disconnect(name) }
        for name in p.connect where !isActive(name) { await connect(name) }
        if !p.shortcut.isEmpty { runShortcut(p.shortcut) }
        if let servers = p.dnsServers { await checkPlaceDNS(p, servers) }
    }

    /// If none of the Place's DNS servers answer, give the original DNS back and say why.
    private func checkPlaceDNS(_ p: Place, _ servers: [String]) async {
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        for s in servers where await DNSProbe.latency(s) != nil { return }
        _ = try? await HelperClient.send(.applyPlace(p.proxy.map { PlaceNetworkSettings(proxy: $0) }), timeout: 20)
        _ = try? await HelperClient.send(.flushDNS, timeout: 10)
        placeProblem = "None of \(p.name)'s DNS servers answered, so your usual DNS is back. The network may block outside DNS."
        addLog(placeProblem!, isError: true)
    }

    func runShortcut(_ name: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        p.arguments = ["run", name]
        do { try p.run(); addLog("Ran Shortcut \(name)") }
        catch { addLog("Couldn't run Shortcut \(name): \(error.localizedDescription)", isError: true) }
    }

    func flushDNSCache() async {
        let ok = (try? await HelperClient.send(.flushDNS, timeout: 10))?.ok == true
        addLog(ok ? "DNS cache flushed" : "Couldn't flush the DNS cache", isError: !ok)
    }

}

/// Puts the user's DNS and proxy back on quit (blocking: the app is about to exit).
enum PlaceQuitHook {
    /// Set on the main thread while a Place has changed DNS or proxy.
    static var changedNetwork = false

    static func restore() {
        guard changedNetwork else { return }
        _ = try? UnixSocket.request(.applyPlace(nil), timeout: 10)
    }
}
