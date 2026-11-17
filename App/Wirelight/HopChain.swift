import Foundation

/// Two tunnels in series: `hop` comes up first and carries `exit`'s encrypted traffic,
/// so the exit server sees the hop server's address, not this Mac's.
struct HopChain: Codable, Identifiable, Equatable {
    var id = UUID()
    var hop: String
    var exit: String

    static let key = "hopChains"

    static func load() -> [HopChain] {
        guard let d = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([HopChain].self, from: d) else { return [] }
        return list
    }
}

extension TunnelStore {
    func saveChains(_ list: [HopChain]) {
        chains = list
        if !Self.isDemo { UserDefaults.standard.set(try? JSONEncoder().encode(list), forKey: HopChain.key) }
    }

    /// Up as a chain: the exit is connected and riding through this hop.
    func isChainUp(_ c: HopChain) -> Bool { isActive(c.exit) && viaOf[c.exit] == c.hop }

    func connectChain(_ c: HopChain) async {
        // An exit already up on its own must reconnect to go through the hop.
        if isActive(c.exit) && viaOf[c.exit] != c.hop { await disconnect(c.exit) }
        if !isActive(c.hop) { await connect(c.hop) }
        guard isActive(c.hop) else { return }
        await connect(c.exit, via: c.hop)
        addLog(isChainUp(c) ? "Chain \(c.hop) → \(c.exit) is up" : "Chain \(c.hop) → \(c.exit) failed", isError: !isChainUp(c))
    }

    func disconnectChain(_ c: HopChain) async {
        await disconnect(c.exit)
        await disconnect(c.hop)
    }
}
