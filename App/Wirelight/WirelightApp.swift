import AppKit
import SwiftUI

@main
struct WirelightApp: App {
    @StateObject private var store = TunnelStore()

    init() {
        _ = Updater.shared
        _ = Toolbox.shared // starts enabled SSH forwards
    }

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environmentObject(store)
        } label: {
            MenuBarLabel().environmentObject(store)
        }
        .menuBarExtraStyle(.window)

        Window("Wirelight", id: "main") {
            MainWindow()
                .environmentObject(store)
        }
        .defaultSize(width: 1100, height: 700)

        // Demo-only window that hosts the dropdown so it can be screenshotted.
        Window("Menu preview", id: "menu-preview") {
            MenuView()
                .environmentObject(store)
                .background(.regularMaterial)
        }
        .windowResizability(.contentSize)


    }
}

private struct MenuBarLabel: View {
    @EnvironmentObject var store: TunnelStore
    @Environment(\.openWindow) private var openWindow
    @AppStorage(MenuBarIcon.coloredKey) private var colored = false
    @AppStorage(NotchPill.enabledKey) private var notch = false

    var body: some View {
        Image(nsImage: MenuBarIcon.image(store.iconState, colored: colored))
            .onAppear { NotchPill.shared.update(enabled: notch, store: store) }
            .onChange(of: notch) { on in NotchPill.shared.update(enabled: on, store: store) }
            .task {
                guard TunnelStore.isDemo else { return }
                openWindow(id: "main")
                openWindow(id: "menu-preview")
                if let dir = ProcessInfo.processInfo.environment["WIRELIGHT_SCREENSHOT_DIR"] {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    DemoScreenshots.capture(to: dir)
                    NSApp.terminate(nil)
                }
            }
    }
}

/// Renders each visible window's content to PNG (demo mode only; no Screen Recording permission needed).
enum DemoScreenshots {
    @MainActor
    static func capture(to dir: String) {
        for window in NSApp.windows where window.isVisible {
            guard let view = window.contentView?.superview ?? window.contentView else { continue }
            let name: String
            switch window.title {
            case "Menu preview": name = "menu"
            case "Wirelight": name = "dashboard"
            default: continue
            }
            let bounds = view.bounds
            guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { continue }
            view.cacheDisplay(in: bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
            }
        }
    }
}
