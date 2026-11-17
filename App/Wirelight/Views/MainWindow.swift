import AppKit
import SwiftUI
import WGCore

enum SidebarItem: String, CaseIterable, Identifiable {
    case all, active, favorites, chains, headsUp, places, doctor, create, importConfig, settings, log
    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All Tunnels"
        case .active: return "Active"
        case .favorites: return "Favorites"
        case .chains: return "Multi-hop"
        case .headsUp: return "Heads-up"
        case .places: return "Places"
        case .doctor: return "Network Doctor"
        case .create: return "New Tunnel"
        case .importConfig: return "Import"
        case .settings: return "Settings"
        case .log: return "Log"
        }
    }

    var icon: String {
        switch self {
        case .all: return "list.bullet"
        case .active: return "bolt.fill"
        case .favorites: return "star.fill"
        case .chains: return "point.3.filled.connected.trianglepath.dotted"
        case .headsUp: return "exclamationmark.bubble"
        case .places: return "mappin.and.ellipse"
        case .doctor: return "stethoscope"
        case .create: return "square.and.pencil"
        case .importConfig: return "square.and.arrow.down"
        case .settings: return "gearshape"
        case .log: return "doc.text"
        }
    }

    var tint: Color {
        switch self {
        case .all: return .accentColor
        case .active: return .green
        case .favorites: return .yellow
        case .chains: return .indigo
        case .headsUp: return .orange
        case .places: return .pink
        case .doctor: return .mint
        case .create: return .teal
        case .importConfig: return .purple
        case .settings: return .secondary
        case .log: return .blue
        }
    }
}

struct MainWindow: View {
    @EnvironmentObject var store: TunnelStore
    @Environment(\.openWindow) private var openWindow


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
                Menu {
                    Button("New Tunnel…") { store.openBuilder() }
                    Button("Import Config…") { store.mainSection = .importConfig }
                } label: { Image(systemName: "plus") }
                    .help("New or import")
            }
        }
        .frame(minWidth: 820, minHeight: 520)
        .onAppear {
            store.windowOpen = true
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            if store.mainSelection == nil { store.mainSelection = store.activeProfile?.name ?? store.profiles.first?.name }
        }
        .onDisappear {
            store.windowOpen = false
            NSApp.setActivationPolicy(.accessory)
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: Binding(get: { store.mainSection }, set: { item in
            // The sidebar entry always means "new"; editing is opened from a tunnel.
            if item == .create { store.openBuilder() } else { store.mainSection = item }
        })) {
            ForEach(SidebarItem.allCases) { item in
                HStack {
                    Label {
                        Text(item.title)
                    } icon: {
                        Image(systemName: item.icon).foregroundStyle(item.tint)
                    }
                    Spacer()
                    if item == .active && store.isConnected {
                        countBadge(store.activeNames.count, .green)
                    }
                    if item == .headsUp {
                        let n = store.profiles.reduce(0) { $0 + store.notices(for: $1.name).count }
                        if n > 0 { countBadge(n, .orange) }
                    }
                }
                .tag(item)
            }
        }
        .listStyle(.sidebar)
    }

    private func countBadge(_ n: Int, _ color: Color) -> some View {
        Text("\(n)")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.white)
            .frame(minWidth: 18, minHeight: 18)
            .background(Capsule().fill(color))
    }

    // MARK: List

    private var filtered: [TunnelProfile] {
        switch store.mainSection {
        case .active: return store.profiles.filter { store.isActive($0.name) }
        case .favorites: return store.profiles.filter(\.favorite)
        default: return store.profiles
        }
    }

    @ViewBuilder
    private var tunnelList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text((store.mainSection ?? .all).title).font(.headline)
                    Text("\(store.profiles.count) tunnel\(store.profiles.count == 1 ? "" : "s"), \(store.activeNames.count) active")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                BulkActions()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            if filtered.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "dot.radiowaves.left.and.right").font(.system(size: 30)).foregroundStyle(.secondary)
                    Text(store.profiles.isEmpty ? "Import a .conf file to add your first tunnel" : "Nothing here")
                        .foregroundStyle(.secondary)
                    if store.profiles.isEmpty {
                        HStack {
                            Button("New tunnel") { store.openBuilder() }
                            Button("Import config") { store.mainSection = .importConfig }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(filtered) { p in
                            TunnelCard(profile: p, selected: store.mainSelection == p.name)
                                .onTapGesture { store.mainSelection = p.name }
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
        switch store.mainSection {
        case .settings:
            ScrollView { SettingsView().frame(maxWidth: .infinity, alignment: .leading) }
        case .log:
            LogView()
        case .chains:
            ChainsView()
        case .headsUp:
            HeadsUpView()
        case .places:
            PlacesView()
        case .doctor:
            DoctorView()
        case .create:
            TunnelBuilderView(editing: store.builderTarget)
                .id(store.builderSession)
        case .importConfig:
            ImportView()
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, 24)
        default:
            if let name = store.mainSelection, let profile = store.profile(name) {
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

    private var isActive: Bool { store.isActive(profile.name) }
    private var busy: Bool { store.isBusy(profile.name) }
    private var accent: Color { StatusStyle.color(store, profile.name) }

    var body: some View {
        HStack(spacing: 10) {
            PingBadge(color: accent, animating: isActive || busy, fast: busy)
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(profile.name).font(.system(size: 13, weight: .semibold))
                    if profile.favorite { Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(.yellow) }
                }
                HStack(spacing: 6) {
                    Text(profile.endpoint ?? "no endpoint")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let q = store.qualitySummary(profile.name), q.grade != .unknown {
                        Text(q.grade.rawValue)
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(q.grade.color.opacity(0.18)))
                            .foregroundStyle(q.grade.color)
                    }
                }
                Text(busy ? (isActive ? "Disconnecting…" : "Connecting…")
                     : store.failures[profile.name] != nil ? "Couldn't connect"
                     : isActive ? (store.isSilent(profile.name) ? "No answer from server"
                                   : store.isStale(profile.name) ? "No recent handshake" : "Connected") : "Disconnected")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(isActive || store.failures[profile.name] != nil ? accent : .secondary)
            }
            Spacer(minLength: 6)
            if isActive {
                Sparkline(samples: store.samples(profile.name), color: accent).frame(width: 48, height: 20)
            }
            Toggle("", isOn: Binding(
                get: { isActive },
                set: { on in Task { on ? await store.connect(profile.name) : await store.disconnect(profile.name) } }))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .disabled(busy || !store.helperReachable)
        }
        .padding(10)
        .card(tint: selected ? .accentColor : (hovering ? .primary : nil), radius: 12)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            Button(profile.favorite ? "Unfavorite" : "Favorite") { store.toggleFavorite(profile.name) }
            Button("Edit…") { store.openBuilder(edit: profile.name) }
            Button("Duplicate") { store.duplicate(profile.name) }
            Button(isActive ? "Disconnect" : "Connect") {
                Task { isActive ? await store.disconnect(profile.name) : await store.connect(profile.name) }
            }
        }
    }
}

/// "Favorites on" and "All off": the two bulk actions, shown only when they would do something.
struct BulkActions: View {
    @EnvironmentObject var store: TunnelStore
    var compact = false

    private var favoritesOff: Bool { store.profiles.contains { $0.favorite && !store.isActive($0.name) } }

    var body: some View {
        HStack(spacing: 6) {
            if favoritesOff {
                PillButton(icon: "star.circle", title: compact ? "Favorites" : "Favorites on", tint: .yellow) {
                    Task { await store.connectFavorites() }
                }
                .help("Connect every favorite tunnel")
            }
            if store.isConnected {
                PillButton(icon: "power", title: "All off", tint: .red) {
                    Task { await store.disconnectAll() }
                }
                .help("Disconnect every tunnel")
            }
        }
        .disabled(store.busy || !store.helperReachable)
    }
}

