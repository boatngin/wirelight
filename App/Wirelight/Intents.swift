import AppIntents
import Foundation

/// Shortcuts, Siri and Spotlight actions. They run inside the app, which macOS
/// starts in the background if needed.

struct TunnelEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Tunnel"
    static var defaultQuery = TunnelQuery()
    let id: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(id)") }
}

struct TunnelQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [TunnelEntity] {
        let names = try await IntentStore.get().profiles.map(\.name)
        return identifiers.filter(names.contains).map(TunnelEntity.init)
    }

    func suggestedEntities() async throws -> [TunnelEntity] {
        try await IntentStore.get().profiles.map { TunnelEntity(id: $0.name) }
    }
}

enum IntentStore {
    struct NotReady: Error, CustomLocalizedStringResourceConvertible {
        var localizedStringResource: LocalizedStringResource { "Wirelight isn't ready yet. Try again in a moment." }
    }

    struct Failed: Error, CustomLocalizedStringResourceConvertible {
        let message: String
        var localizedStringResource: LocalizedStringResource { "\(message)" }
    }

    /// Waits briefly for the app to finish starting when macOS launched it for the intent.
    @MainActor static func get() async throws -> TunnelStore {
        for _ in 0..<30 {
            if let s = TunnelStore.shared { return s }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw NotReady()
    }
}

struct ConnectTunnelIntent: AppIntent {
    static var title: LocalizedStringResource = "Connect Tunnel"
    static var description = IntentDescription("Connects a Wirelight tunnel. Other tunnels stay up unless both route all traffic.")
    @Parameter(title: "Tunnel") var tunnel: TunnelEntity

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = try await IntentStore.get()
        await store.connect(tunnel.id)
        if let err = store.failures[tunnel.id] { throw IntentStore.Failed(message: err) }
        return .result(dialog: "\(tunnel.id) is connected.")
    }
}

struct DisconnectTunnelIntent: AppIntent {
    static var title: LocalizedStringResource = "Disconnect Tunnel"
    @Parameter(title: "Tunnel") var tunnel: TunnelEntity

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = try await IntentStore.get()
        await store.disconnect(tunnel.id)
        if store.isActive(tunnel.id) { throw IntentStore.Failed(message: "\(tunnel.id) is still connected.") }
        return .result(dialog: "\(tunnel.id) is disconnected.")
    }
}

struct DisconnectAllIntent: AppIntent {
    static var title: LocalizedStringResource = "Disconnect All Tunnels"

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = try await IntentStore.get()
        await store.disconnectAll()
        return .result(dialog: store.isConnected ? "Some tunnels are still up." : "All tunnels are off.")
    }
}

struct ConnectFavoritesIntent: AppIntent {
    static var title: LocalizedStringResource = "Connect Favorite Tunnels"

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = try await IntentStore.get()
        await store.connectFavorites()
        return .result(dialog: "Connected: \(store.activeNames.joined(separator: ", ")).")
    }
}

struct ConnectedTunnelsIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Connected Tunnels"
    static var description = IntentDescription("Returns the names of the tunnels that are up.")

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<[String]> & ProvidesDialog {
        let store = try await IntentStore.get()
        await store.refresh()
        let names = store.activeNames
        return .result(value: names, dialog: names.isEmpty ? "No tunnels are connected." : "\(names.joined(separator: ", "))")
    }
}

struct WirelightShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ConnectTunnelIntent(), phrases: ["Connect \(\.$tunnel) with \(.applicationName)",
                                                             "Connect a tunnel in \(.applicationName)"])
        AppShortcut(intent: DisconnectAllIntent(), phrases: ["Disconnect all \(.applicationName) tunnels",
                                                             "Turn off \(.applicationName)"])
        AppShortcut(intent: ConnectFavoritesIntent(), phrases: ["Connect my \(.applicationName) favorites"])
        AppShortcut(intent: ConnectedTunnelsIntent(), phrases: ["Which \(.applicationName) tunnels are on"])
    }
}
