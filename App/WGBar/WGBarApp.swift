import SwiftUI

@main
struct WGBarApp: App {
    @StateObject private var store = TunnelStore()

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environmentObject(store)
        } label: {
            Image(systemName: store.isConnected ? "network.badge.shield.half.filled" : "network")
        }
        .menuBarExtraStyle(.window)

        Window("Import Config", id: "import") {
            ImportView()
                .environmentObject(store)
        }
        .windowResizability(.contentSize)

        Window("WGBar Settings", id: "settings") {
            SettingsView()
                .environmentObject(store)
        }
        .windowResizability(.contentSize)
    }
}
