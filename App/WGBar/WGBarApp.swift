import SwiftUI

@main
struct WGBarApp: App {
    @StateObject private var store = TunnelStore()

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environmentObject(store)
        } label: {
            Image(nsImage: MenuBarIcon.image(store.iconState))
        }
        .menuBarExtraStyle(.window)

        Window("WGBar", id: "main") {
            MainWindow()
                .environmentObject(store)
        }
        .defaultSize(width: 1100, height: 700)

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
