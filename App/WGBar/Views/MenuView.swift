import AppKit
import SwiftUI
import WGCore

struct MenuView: View {
    @EnvironmentObject var store: TunnelStore
    @Environment(\.openWindow) private var openWindow
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !store.helperReachable { helperBanner }
            header
            if let err = store.lastError {
                Text(err)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            tunnelsSection
            if let active = store.active {
                Divider()
                deviceSection(active)
            }
            if let profile = store.currentProfile {
                Divider()
                routeAllSection(profile)
            }
            Divider()
            footer
        }
        .frame(width: 320)
        .onAppear { store.menuOpen = true }
        .onDisappear { store.menuOpen = false }
    }

    // MARK: Sections

    private var helperBanner: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Helper not installed", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .semibold))
            Text("Run ./scripts/install-helper.sh in the wgbar folder, then reopen this menu.")
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(.black)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.yellow)
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("WGBar").font(.system(size: 14, weight: .semibold))
                Text(statusLine)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if store.busy { ProgressView().controlSize(.small).padding(.trailing, 6) }
            Toggle("", isOn: connectedBinding)
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(store.busy || !store.helperReachable || store.profiles.isEmpty)
        }
        .padding(14)
    }

    private var statusLine: String {
        if let a = store.active { return "Connected · \(a.name)" }
        if store.busy { return "Working…" }
        return "Disconnected"
    }

    private var connectedBinding: Binding<Bool> {
        Binding(
            get: { store.isConnected },
            set: { on in
                Task {
                    if on, let name = store.currentProfile?.name { await store.connect(name) }
                    else if !on { await store.disconnect() }
                }
            })
    }

    private var tunnelsSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            sectionTitle("Tunnels")
            if store.profiles.isEmpty {
                Text("No tunnels yet. Import a .conf file to get started.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
            }
            ForEach(store.profiles) { p in
                TunnelRow(profile: p, isActive: store.active?.name == p.name, busy: store.busy) {
                    Task { await store.connect(p.name) }
                }
                .padding(.horizontal, 4)
            }
        }
        .padding(.bottom, 6)
    }

    private func deviceSection(_ active: TunnelStatus) -> some View {
        let peer = active.peers.first
        let address = store.activeProfile?.addresses.first.map(Format.ip)
        return VStack(alignment: .leading, spacing: 6) {
            sectionTitle("This device").padding(.horizontal, -14)
            if let address {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(address, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                } label: {
                    HStack {
                        Text(address).font(.system(size: 13, design: .monospaced))
                        Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 10))
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Copy IP address")
            }
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                HStack(spacing: 4) {
                    Image(systemName: "hand.wave").font(.system(size: 10))
                    if let hs = peer?.latestHandshake {
                        Text("Handshake \(Format.relative(hs, now: ctx.date))")
                            .foregroundStyle(ctx.date.timeIntervalSince(hs) > TunnelStore.staleAfter ? Color.yellow : .secondary)
                    } else {
                        Text("No handshake yet").foregroundStyle(Color.yellow)
                    }
                }
                .font(.system(size: 11))
            }
            HStack(spacing: 12) {
                Text("↓ \(Format.bytes(peer?.rxBytes ?? 0))")
                Text("↑ \(Format.bytes(peer?.txBytes ?? 0))")
            }
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }

    private func routeAllSection(_ profile: TunnelProfile) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Route all traffic").font(.system(size: 13))
                Text(profile.routeAll ? "All traffic goes through \(profile.name)" : "Only the tunnel's AllowedIPs")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { profile.routeAll },
                set: { on in Task { await store.setRouteAll(on, for: profile.name) } }))
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
                .disabled(store.busy)
        }
        .padding(14)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 0) {
            menuButton("Open WGBar…") { open("main") }
            menuButton("Import config…") { open("import") }
            menuButton("Settings…") { open("settings") }
            Divider().padding(.vertical, 4)
            menuButton("Quit WGBar") { NSApp.terminate(nil) }
        }
        .padding(.vertical, 6)
    }

    // MARK: Helpers

    private func sectionTitle(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 4)
    }

    private func menuButton(_ title: String, action: @escaping () -> Void) -> some View {
        HoverButton(title: title, action: action)
    }

    private func open(_ id: String) {
        openWindow(id: id)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct HoverButton: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 5).fill(hovering ? Color.accentColor : .clear))
                .foregroundStyle(hovering ? Color.white : Color.primary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
        .onHover { hovering = $0 }
    }
}
