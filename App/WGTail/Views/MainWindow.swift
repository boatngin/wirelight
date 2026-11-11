import AppKit
import SwiftUI
import WGCore

enum SidebarItem: String, CaseIterable, Identifiable {
    case all, active, favorites, settings, log
    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All Tunnels"
        case .active: return "Active"
        case .favorites: return "Favorites"
        case .settings: return "Settings"
        case .log: return "Log"
        }
    }

    var icon: String {
        switch self {
        case .all: return "list.bullet"
        case .active: return "bolt.fill"
        case .favorites: return "star.fill"
        case .settings: return "gearshape"
        case .log: return "doc.text"
        }
    }

    var tint: Color {
        switch self {
        case .all: return .accentColor
        case .active: return .green
        case .favorites: return .yellow
        case .settings: return .secondary
        case .log: return .blue
        }
    }
}

struct MainWindow: View {
    @EnvironmentObject var store: TunnelStore
    @Environment(\.openWindow) private var openWindow

    @State private var section: SidebarItem? = .all
    @State private var selection: String?

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } content: {
            tunnelList
                .navigationSplitViewColumnWidth(min: 260, ideal: 300)
        } detail: {
            detail
        }
        .toolbar {
            ToolbarItem {
                Button { openWindow(id: "import") } label: { Image(systemName: "plus") }
                    .help("Import config")
            }
        }
        .frame(minWidth: 820, minHeight: 520)
        .onAppear {
            store.windowOpen = true
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            if selection == nil { selection = store.activeProfile?.name ?? store.profiles.first?.name }
        }
        .onDisappear {
            store.windowOpen = false
            NSApp.setActivationPolicy(.accessory)
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: $section) {
            ForEach(SidebarItem.allCases) { item in
                HStack {
                    Label {
                        Text(item.title)
                    } icon: {
                        Image(systemName: item.icon).foregroundStyle(item.tint)
                    }
                    Spacer()
                    if item == .active && store.isConnected {
                        Text("1")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 18, height: 18)
                            .background(Circle().fill(Color.green))
                    }
                }
                .tag(item)
            }
        }
        .listStyle(.sidebar)
    }

    // MARK: List

    private var filtered: [TunnelProfile] {
        switch section {
        case .active: return store.profiles.filter { $0.name == store.active?.name }
        case .favorites: return store.profiles.filter(\.favorite)
        default: return store.profiles
        }
    }

    @ViewBuilder
    private var tunnelList: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text((section ?? .all).title).font(.headline)
                Text("\(store.profiles.count) tunnel\(store.profiles.count == 1 ? "" : "s"), \(store.isConnected ? 1 : 0) active")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            if filtered.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "dot.radiowaves.left.and.right").font(.system(size: 30)).foregroundStyle(.secondary)
                    Text(store.profiles.isEmpty ? "Import a .conf file to add your first tunnel" : "Nothing here")
                        .foregroundStyle(.secondary)
                    if store.profiles.isEmpty {
                        Button("Import config") { openWindow(id: "import") }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(filtered) { p in
                            TunnelCard(profile: p, selected: selection == p.name)
                                .onTapGesture { selection = p.name }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                }
            }
        }
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        switch section {
        case .settings:
            ScrollView { SettingsView().frame(maxWidth: .infinity, alignment: .leading) }
        case .log:
            LogView()
        default:
            if let name = selection, let profile = store.profile(name) {
                TunnelDetailView(profile: profile)
            } else {
                Text("Select a tunnel").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

// MARK: - Tunnel card

struct TunnelCard: View {
    @EnvironmentObject var store: TunnelStore
    let profile: TunnelProfile
    let selected: Bool
    @State private var hovering = false

    private var isActive: Bool { store.active?.name == profile.name }
    private var accent: Color { StatusStyle.color(connected: isActive, stale: store.isHandshakeStale) }

    var body: some View {
        HStack(spacing: 10) {
            PingBadge(color: accent, animating: isActive)
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(profile.name).font(.system(size: 13, weight: .semibold))
                    if profile.favorite { Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(.yellow) }
                }
                Text(profile.endpoint ?? "no endpoint")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(isActive ? (store.isHandshakeStale ? "No recent handshake" : "Connected") : "Disconnected")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(isActive ? accent : .secondary)
            }
            Spacer(minLength: 6)
            if isActive {
                Sparkline(samples: store.samples, color: accent).frame(width: 48, height: 20)
            }
            Toggle("", isOn: Binding(
                get: { isActive },
                set: { on in Task { on ? await store.connect(profile.name) : await store.disconnect() } }))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .disabled(store.busy || !store.helperReachable)
        }
        .padding(10)
        .card(tint: selected ? .accentColor : (hovering ? .primary : nil), radius: 12)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            Button(profile.favorite ? "Unfavorite" : "Favorite") { store.toggleFavorite(profile.name) }
            Button(isActive ? "Disconnect" : "Connect") {
                Task { isActive ? await store.disconnect() : await store.connect(profile.name) }
            }
        }
    }
}

// MARK: - Log

struct LogView: View {
    @EnvironmentObject var store: TunnelStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Log").font(.title3.weight(.semibold))
                Spacer()
                Text("Helper log: log stream --predicate 'subsystem == \"com.thanaboat.wgbar\"'")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .padding(16)
            Divider()
            if store.log.isEmpty {
                Text("No events yet").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(store.log.reversed()) { e in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(e.date, format: .dateTime.hour().minute().second())
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Text(e.message)
                            .font(.system(size: 12))
                            .foregroundStyle(e.isError ? Color.red : .primary)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }
}
