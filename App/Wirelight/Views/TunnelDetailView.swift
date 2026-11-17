import AppKit
import Charts
import SwiftUI
import WGCore

/// Dashboard for one tunnel. Same visual language as the menu bar dropdown:
/// ping hero, stat tiles, traffic card, then compact info and options cards.
struct TunnelDetailView: View {
    @EnvironmentObject var store: TunnelStore
    @Environment(\.openWindow) private var openWindow
    let profile: TunnelProfile

    @State private var testResult: String?
    @State private var testing = false
    @State private var speedTesting = false
    @State private var showAdvanced = false
    @State private var copiedField: String?

    private var isActive: Bool { store.isActive(profile.name) }
    private var busy: Bool { store.isBusy(profile.name) }
    private var stale: Bool { store.isStale(profile.name) }
    private var samples: [TrafficSample] { store.samples(profile.name) }
    private var config: WGConfig? { store.config(profile.name) }
    private var peer: PeerStatus? { store.status(profile.name)?.peers.first }
    private var accent: Color { StatusStyle.color(store, profile.name) }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                hero
                HealthStrip(names: [profile.name])
                if let err = store.lastError {
                    Label(err, systemImage: "exclamationmark.circle.fill")
                        .font(.system(size: 12)).foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if isActive {
                    stats
                    traffic
                }
                QualityCard(name: profile.name)
                connectionCard
                optionsCard
                actions
            }
            .padding(20)
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: Hero

    private var hero: some View {
        HStack(spacing: 14) {
            PingBadge(color: accent, animating: isActive || busy, fast: busy)
                .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(profile.name).font(.system(size: 20, weight: .semibold))
                    if profile.favorite { Image(systemName: "star.fill").font(.system(size: 11)).foregroundStyle(.yellow) }
                    engineMenu
                }
                HStack(spacing: 5) {
                    Circle().fill(accent).frame(width: 7, height: 7)
                    Text(statusText).foregroundStyle(isActive ? accent : .secondary)
                }
                .font(.system(size: 12, weight: .medium))
                Text(profile.endpoint ?? "no endpoint")
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { isActive },
                set: { on in Task { on ? await store.connect(profile.name) : await store.disconnect(profile.name) } }))
                .toggleStyle(.switch)
                .controlSize(.large)
                .labelsHidden()
                .disabled(busy || !store.helperReachable)
        }
        .padding(16)
        .card(tint: isActive ? accent : nil, radius: 14)
    }

    /// Engine pill: shows WireGuard or AmneziaWG; choosing applies on the next connect (reconnects if up).
    private var engineMenu: some View {
        let e = store.engine(profile.name)
        let needsAmnezia = config?.interface.isAmnezia == true
        return Menu {
            Button("Automatic\(profile.engine == nil ? " ✓" : "")") { Task { await store.setEngine(nil, for: profile.name) } }
            Button("WireGuard\(profile.engine == .wireguard ? " ✓" : "")") { Task { await store.setEngine(.wireguard, for: profile.name) } }
                .disabled(needsAmnezia)
            Button("AmneziaWG\(profile.engine == .amneziawg ? " ✓" : "")") { Task { await store.setEngine(.amneziawg, for: profile.name) } }
        } label: {
            Text(e == .amneziawg ? "AmneziaWG" : "WireGuard")
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Capsule().fill((e == .amneziawg ? Color.purple : Color.secondary).opacity(0.16)))
                .foregroundStyle(e == .amneziawg ? Color.purple : .secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(needsAmnezia ? "This config has AmneziaWG keys, so it runs on AmneziaWG" : "Engine; Automatic follows the config")
    }

    private var statusText: String {
        if !store.helperReachable { return "Helper not running" }
        if busy { return isActive ? "Disconnecting…" : "Connecting…" }
        if isActive {
            if store.isSilent(profile.name) { return "Connected · no answer from server" }
            return stale ? "Connected · no recent handshake" : "Connected"
        }
        if store.failures[profile.name] != nil { return "Couldn't connect" }
        return "Disconnected"
    }

    // MARK: Live

    private var stats: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            HStack(spacing: 8) {
                StatTile(icon: "arrow.down", tint: .green, title: "Download",
                         value: rate(samples.last?.rx ?? 0), sub: "Total \(Format.bytes(peer?.rxBytes ?? 0))")
                StatTile(icon: "arrow.up", tint: .blue, title: "Upload",
                         value: rate(samples.last?.tx ?? 0), sub: "Total \(Format.bytes(peer?.txBytes ?? 0))")
                StatTile(icon: "hand.wave", tint: stale ? .orange : .purple, title: "Handshake",
                         value: peer?.latestHandshake.map { Format.relative($0, now: ctx.date) } ?? "never",
                         sub: stale ? "Stale" : "Healthy")
                StatTile(icon: "clock", tint: .teal, title: "Uptime",
                         value: store.connectedSince(profile.name).map { duration(ctx.date.timeIntervalSince($0)) } ?? "-",
                         sub: store.status(profile.name)?.interface ?? "")
            }
        }
    }

    private var traffic: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Traffic · last 60s").font(.system(size: 12, weight: .semibold))
                Spacer()
                legend(.green, "Down")
                legend(.blue, "Up")
            }
            Chart {
                ForEach(samples) { s in
                    AreaMark(x: .value("t", s.date), y: .value("down", s.rx), series: .value("s", "down"))
                        .foregroundStyle(Color.green.opacity(0.15))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("t", s.date), y: .value("down", s.rx), series: .value("s", "down"))
                        .foregroundStyle(Color.green)
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("t", s.date), y: .value("up", s.tx), series: .value("s", "up"))
                        .foregroundStyle(Color.blue)
                        .interpolationMethod(.monotone)
                }
            }
            .chartXScale(domain: Date().addingTimeInterval(-60)...Date())
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { v in
                    AxisGridLine().foregroundStyle(Color.secondary.opacity(0.12))
                    AxisValueLabel { if let d = v.as(Double.self) { Text(rate(d)).font(.system(size: 9, design: .monospaced)) } }
                }
            }
            .frame(height: 110)
            .overlay {
                if samples.count < 2 { Text("Collecting…").font(.system(size: 11)).foregroundStyle(.secondary) }
            }
        }
        .padding(12)
        .card()
    }

    // MARK: Info

    private var connectionCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            cardTitle("Connection", icon: "point.3.connected.trianglepath.dotted")
            infoRow("Address", config?.interface.addresses.joined(separator: ", ") ?? "-", copy: true)
            infoRow("Interface", store.status(profile.name)?.interface ?? "-")
            infoRow("Allowed IPs", allowedIPs)
            infoRow("DNS", dns)
            infoRow("Public key", config?.interface.publicKey ?? "-", copy: true)
            infoRow("Peer key", config?.peers.first?.publicKey ?? "-", copy: true, last: true)
        }
        .card()
    }

    private var optionsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            cardTitle("Options", icon: "slider.horizontal.3")
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Route all traffic").font(.system(size: 13))
                    Text("Send everything through this tunnel").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: Binding(get: { profile.routeAll },
                                         set: { on in Task { await store.setRouteAll(on, for: profile.name) } }))
                    .toggleStyle(.switch).controlSize(.small).labelsHidden()
                    .disabled(busy)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)

            Divider().padding(.horizontal, 14)

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Network rules").font(.system(size: 13))
                    Text("Connect or disconnect by Wi-Fi name or Ethernet subnet. Reading the Wi-Fi name needs Location permission; it never leaves this Mac.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: Binding(get: { profile.onDemand },
                                         set: { on in Task { await store.setOnDemand(on, for: profile.name) } }))
                    .toggleStyle(.switch).controlSize(.small).labelsHidden()
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            if profile.onDemand {
                RulesEditor(profile: profile).padding(.horizontal, 14).padding(.bottom, 12)
            }

            Divider().padding(.horizontal, 14)

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Kill switch").font(.system(size: 13))
                    Text("Block all non-tunnel traffic if the tunnel drops").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: Binding(get: { profile.killSwitch },
                                         set: { on in Task { await store.setKillSwitch(on, for: profile.name) } }))
                    .toggleStyle(.switch).controlSize(.small).labelsHidden()
                    .disabled(busy)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)

            if store.routesAll(profile.name) && !profile.routeAll
                && !(config?.peers.flatMap(\.allowedIPs).contains("::/0") ?? false) {
                Divider().padding(.horizontal, 14)
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Block IPv6 while connected").font(.system(size: 13))
                        Text("This tunnel takes IPv4 only. Drop IPv6 so it can't go around the tunnel.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(get: { profile.blockIPv6 },
                                             set: { on in Task { await store.setBlockIPv6(on, for: profile.name) } }))
                        .toggleStyle(.switch).controlSize(.small).labelsHidden()
                        .disabled(busy)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
            }

            Divider().padding(.horizontal, 14)

            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showAdvanced.toggle() }
            } label: {
                HStack {
                    Text("Advanced").font(.system(size: 13))
                    if !profile.splitDNSDomains.isEmpty || !profile.excludedCIDRs.isEmpty {
                        Text("\(profile.splitDNSDomains.count + profile.excludedCIDRs.count) rules")
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                            .foregroundStyle(Color.accentColor)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(showAdvanced ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 14).padding(.vertical, 10)

            if showAdvanced {
                VStack(alignment: .leading, spacing: 14) {
                    advancedBlock(title: "Split DNS",
                                  hint: "Use this tunnel's DNS only for these domains. Others keep your normal DNS.") {
                        EditableList(items: profile.splitDNSDomains, placeholder: "Domain, e.g. lan",
                                     icon: "network", validate: Validation.isValidHostname) { list in
                            Task { await store.setSplitDNS(list, for: profile.name) }
                        }
                    }
                    advancedBlock(title: "Exclusions",
                                  hint: "These ranges skip the tunnel and use your normal connection.") {
                        EditableList(items: profile.excludedCIDRs, placeholder: "CIDR, e.g. 10.0.5.0/24",
                                     icon: "arrow.triangle.branch", validate: Validation.isValidCIDR) { list in
                            Task { await store.setExclusions(list, for: profile.name) }
                        }
                    }
                    advancedBlock(title: "Learned routes",
                                  hint: "A command run as you after connecting. Every IP or CIDR it prints (one per line, # for comments) is routed through this tunnel. Ranges wider than /8 (IPv4) or /32 (IPv6) and special ranges are refused; if it fails, the last good list is used.") {
                        LearnedRoutesBlock(profile: profile)
                    }
                    Text("Changes reconnect the tunnel if it's active.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14).padding(.bottom, 14)
            }
        }
        .card()
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                if isActive {
                    PillButton(icon: "waveform.path.ecg", title: testing ? "Testing…" : "Test", tint: .accentColor) {
                        guard !testing else { return }
                        testing = true
                        Task { testResult = await store.testConnection(profile.name); testing = false }
                    }
                }
                if isActive && !store.speedTestURL.isEmpty {
                    PillButton(icon: "speedometer", title: speedTesting ? "Measuring…" : "Speed test", tint: .accentColor) {
                        guard !speedTesting else { return }
                        speedTesting = true
                        Task { testResult = await store.speedTest(); speedTesting = false }
                    }
                }
                PillButton(icon: profile.favorite ? "star.fill" : "star",
                           title: profile.favorite ? "Unfavorite" : "Favorite") { store.toggleFavorite(profile.name) }
                PillButton(icon: "pencil", title: "Edit") { store.openBuilder(edit: profile.name) }
                PillButton(icon: "square.and.arrow.up", title: "Export") { exportConfig() }
                PillButton(icon: "plus.square.on.square", title: "Duplicate") { store.duplicate(profile.name) }
                if TunnelStore.isAdminUser {
                    let isShared = store.sharedInfo(profile.name) != nil
                    PillButton(icon: "person.2", title: isShared ? "Update share" : "Share") {
                        Task { await store.share(profile.name, policy: store.sharedInfo(profile.name)?.policy ?? SharePolicy()) }
                    }
                    .help("Keep a root-only copy so every user on this Mac can use it (they never see the keys)")
                }
                Spacer()
            }
            if let testResult {
                Text(testResult)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(testResult.contains("avg") || testResult.hasPrefix("Download") ? Color.green : .orange)
                    .textSelection(.enabled)
            }
        }
    }

    // MARK: Pieces

    private func cardTitle(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 4)
    }

    private func infoRow(_ label: String, _ value: String, copy: Bool = false, last: Bool = false) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(label).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 96, alignment: .leading)
                Text(value)
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer(minLength: 4)
                if copy && value != "-" {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(value, forType: .string)
                        copiedField = label
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { if copiedField == label { copiedField = nil } }
                    } label: {
                        Image(systemName: copiedField == label ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 10))
                            .foregroundStyle(copiedField == label ? Color.green : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Copy")
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            if !last { Divider().padding(.leading, 14) }
        }
        .padding(.bottom, last ? 4 : 0)
    }

    private func advancedBlock<C: View>(title: String, hint: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12, weight: .semibold))
            Text(hint).font(.system(size: 11)).foregroundStyle(.secondary)
            content()
        }
    }

    private func legend(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }

    private var allowedIPs: String {
        if profile.routeAll { return "0.0.0.0/0, ::/0" }
        let ips = config?.peers.flatMap(\.allowedIPs) ?? []
        return ips.isEmpty ? "-" : ips.joined(separator: ", ")
    }

    private var dns: String {
        let all = (config?.interface.dns ?? []) + (config?.interface.dnsSearch ?? [])
        return all.isEmpty ? "-" : all.joined(separator: ", ")
    }

    private func rate(_ bps: Double) -> String { Format.rate(bps) }

    private func duration(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        return "\(s / 3600)h \((s % 3600) / 60)m"
    }

    /// Saves the full config (including the private key) to a file the user picks.
    private func exportConfig() {
        guard let text = store.configText(profile.name) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(profile.name).conf"
        panel.message = "The exported file contains your private key. Keep it safe."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            store.addLog("Exported \(profile.name) to \(url.path)")
        } catch {
            store.addLog("Export failed: \(error.localizedDescription)", isError: true)
        }
    }
}

/// Tiny combined rx+tx sparkline used in the tunnel list.
struct Sparkline: View {
    let samples: [TrafficSample]
    var color: Color = .green

    var body: some View {
        GeometryReader { geo in
            let values = samples.suffix(30).map { $0.rx + $0.tx }
            let maxV = max(values.max() ?? 1, 1)
            let step = values.count > 1 ? geo.size.width / CGFloat(values.count - 1) : 0
            Path { p in
                for (i, v) in values.enumerated() {
                    let pt = CGPoint(x: CGFloat(i) * step, y: geo.size.height * (1 - CGFloat(v / maxV)))
                    i == 0 ? p.move(to: pt) : p.addLine(to: pt)
                }
                if values.count < 2 {
                    p.move(to: CGPoint(x: 0, y: geo.size.height))
                    p.addLine(to: CGPoint(x: geo.size.width, y: geo.size.height))
                }
            }
            .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
        }
    }
}
