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
                .navigationSplitViewColumnWidth(min: 280, ideal: 340)
        } detail: {
            detail
        }
        .toolbar {
            ToolbarItem {
                Button { openWindow(id: "import") } label: { Image(systemName: "plus") }
                    .help("Import config")
            }
        }
        .frame(minWidth: 900, minHeight: 560)
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
                    VStack(spacing: 8) {
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

    private var isActive: Bool { store.active?.name == profile.name }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Circle()
                .fill(isActive ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 3) {
                Text(profile.name).font(.system(size: 14, weight: .semibold))
                Text(profile.endpoint ?? "no endpoint")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(selected ? Color.white.opacity(0.9) : .secondary)
                Text(allowedIPs)
                    .font(.system(size: 11))
                    .foregroundStyle(selected ? Color.white.opacity(0.65) : Color.secondary.opacity(0.8))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if isActive {
                Sparkline(samples: store.samples)
                    .frame(width: 70, height: 26)
            }
            Button { store.toggleFavorite(profile.name) } label: {
                Image(systemName: profile.favorite ? "star.fill" : "star")
                    .foregroundStyle(profile.favorite ? Color.yellow : (selected ? .white : .secondary))
            }
            .buttonStyle(.plain)
            Toggle("", isOn: Binding(
                get: { isActive },
                set: { on in Task { on ? await store.connect(profile.name) : await store.disconnect() } }))
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(store.busy || !store.helperReachable)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .foregroundStyle(selected ? Color.white : Color.primary)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(selected ? Color.accentColor : Color.primary.opacity(0.05)))
        .contentShape(Rectangle())
    }

    private var allowedIPs: String {
        let ips = store.config(profile.name)?.peers.flatMap(\.allowedIPs) ?? []
        if profile.routeAll { return "0.0.0.0/0, ::/0 (route all)" }
        return ips.isEmpty ? "-" : ips.joined(separator: ", ")
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
