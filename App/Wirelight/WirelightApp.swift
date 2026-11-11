import SwiftUI

@main
struct WirelightApp: App {
    @StateObject private var store = TunnelStore()

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environmentObject(store)
        } label: {
            Image(nsImage: MenuBarIcon.image(store.iconState))
        }
        .menuBarExtraStyle(.window)

        Window("Wirelight", id: "main") {
            MainWindow()
                .environmentObject(store)
        }
        .defaultSize(width: 1100, height: 700)


    }
}
