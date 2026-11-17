import SwiftUI
import WGCore

/// Places: per-network DNS, proxy, tunnel actions and a Shortcut. First match wins.
struct PlacesView: View {
    @EnvironmentObject var store: TunnelStore
    @State private var expanded: UUID?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                if let problem = store.placeProblem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12)).foregroundStyle(.orange)
                        .padding(10).frame(maxWidth: .infinity, alignment: .leading).card(tint: .orange)
                }
                if store.places.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("No places yet").font(.system(size: 13, weight: .semibold))
                        Text("A place is a network you join, like home Wi-Fi or the office dock. While you're on it, Wirelight can switch DNS, set a proxy, turn tunnels on or off and run a Shortcut. Your own settings come back when you leave or quit.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    .padding(14).card()
                }
                ForEach(Array(store.places.enumerated()), id: \.element.id) { i, p in
                    PlaceCard(place: p, index: i, expanded: expanded == p.id) {
                        withAnimation(.easeInOut(duration: 0.18)) { expanded = expanded == p.id ? nil : p.id }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Places").font(.title2.weight(.semibold))
                let net = store.currentNetwork()
                let here = net.wifiSSID.map { "Wi-Fi “\($0)”" } ?? (net.onEthernet ? "Ethernet" : "no network")
                Text("You're on \(here)" + (store.activePlace.map { " · \($0.name) is active" } ?? " · no place matches"))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            PillButton(icon: "arrow.clockwise", title: "Flush DNS cache") { Task { await store.flushDNSCache() } }
            PillButton(icon: "plus", title: "Add place", tint: .accentColor) {
                let ssid = store.currentSSID()
                var p = Place(name: ssid ?? "New place")
                if let ssid { p.values = [ssid] } else if store.currentNetwork().onEthernet { p.kind = .ethernet }
                store.savePlaces(store.places + [p])
                expanded = p.id
            }
        }
    }
}

private struct PlaceCard: View {
    @EnvironmentObject var store: TunnelStore
    let place: Place
    let index: Int
    let expanded: Bool
    let toggle: () -> Void
    @State private var dnsResults: [String: Double?] = [:]
    @State private var testing = false

    private var isActive: Bool { store.activePlace?.id == place.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) {
                HStack(spacing: 10) {
                    Image(systemName: place.kind == .wifi ? "wifi" : "cable.connector")
                        .foregroundStyle(isActive ? Color.accentColor : .secondary)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(place.name).font(.system(size: 13, weight: .semibold))
                            if isActive {
                                Text("Active").font(.system(size: 9, weight: .bold))
                                    .padding(.horizontal, 6).padding(.vertical, 1)
                                    .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        Text(summary).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    if isActive && store.activePlace != place {
                        Button("Apply changes") { Task { await store.evaluatePlaces(store.currentNetwork(), force: true) } }
                            .controlSize(.small)
                            .disabled(place.settings?.validationError() != nil)
                    }
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .padding(12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded { editor.padding(.horizontal, 14).padding(.bottom, 14) }
        }
        .card(tint: isActive ? .accentColor : nil)
    }

    private var summary: String {
        var parts: [String] = []
        parts.append(place.values.isEmpty ? (place.kind == .wifi ? "Any Wi-Fi" : "Any Ethernet") : place.values.joined(separator: ", "))
        if place.dnsMode != .keep { parts.append("DNS \(place.dnsMode == .custom ? "custom" : place.dnsMode.rawValue.capitalized)") }
        if let p = place.proxy { parts.append("proxy \(p.mode.rawValue)") }
        if !place.connect.isEmpty { parts.append("on: \(place.connect.joined(separator: ", "))") }
        if !place.disconnect.isEmpty { parts.append("off: \(place.disconnect.joined(separator: ", "))") }
        if !place.shortcut.isEmpty { parts.append("runs \(place.shortcut)") }
        return parts.joined(separator: " · ")
    }

    private func update(_ change: (inout Place) -> Void) {
        var list = store.places
        guard let i = list.firstIndex(where: { $0.id == place.id }) else { return }
        change(&list[i])
        store.savePlaces(list)
    }

    @ViewBuilder private var editor: some View {
        VStack(alignment: .leading, spacing: 14) {
            row("Name") {
                TextField("Home", text: Binding(get: { place.name }, set: { v in update { $0.name = v } }))
                    .textFieldStyle(.roundedBorder)
            }
            row("Network") {
                VStack(alignment: .leading, spacing: 6) {
                    Picker("", selection: Binding(get: { place.kind }, set: { k in update { $0.kind = k; $0.values = [] } })) {
                        Text("Wi-Fi").tag(NetworkRule.Kind.wifi)
                        Text("Ethernet").tag(NetworkRule.Kind.ethernet)
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 180)
                    ChipGroup(title: place.kind == .wifi ? "Names (none = any Wi-Fi)" : "Subnets (none = any Ethernet)",
                              icon: place.kind == .wifi ? "wifi" : "number", items: place.values,
                              placeholder: place.kind == .wifi ? "add name" : "add subnet", lowercase: false,
                              example: place.kind == .wifi ? "HomeWiFi" : "192.168.1.0/24",
                              validate: place.kind == .wifi ? Validation.isValidSSID : Validation.isValidCIDR) { v in
                        update { $0.values = v }
                    }
                }
            }
            row("DNS") { dnsEditor }
            row("Proxy") { proxyEditor }
            row("Tunnels") {
                VStack(alignment: .leading, spacing: 6) {
                    tunnelChips("Connect", place.connect, other: place.disconnect) { v in update { $0.connect = v } }
                    tunnelChips("Disconnect", place.disconnect, other: place.connect) { v in update { $0.disconnect = v } }
                    Text("Happens once when the place starts. A tunnel's own network rules can change it later.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            row("Shortcut") {
                TextField("Name of a Shortcut to run (optional)",
                          text: Binding(get: { place.shortcut }, set: { v in update { $0.shortcut = v } }))
                    .textFieldStyle(.roundedBorder)
            }
            HStack {
                Button { move(-1) } label: { Label("Up", systemImage: "arrow.up") }.disabled(index == 0)
                Button { move(1) } label: { Label("Down", systemImage: "arrow.down") }.disabled(index == store.places.count - 1)
                Text("First matching place wins.").font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Button(role: .destructive) { store.savePlaces(store.places.filter { $0.id != place.id }) } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
            .controlSize(.small)
            if let err = place.settings?.validationError() {
                Text("Not applied: \(err)").font(.system(size: 11)).foregroundStyle(.red)
            }
        }
    }

    private var dnsEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("", selection: Binding(get: { place.dnsMode }, set: { m in update { $0.dnsMode = m } })) {
                Text("Keep").tag(Place.DNSMode.keep)
                Text("Cloudflare").tag(Place.DNSMode.cloudflare)
                Text("Quad9").tag(Place.DNSMode.quad9)
                Text("Google").tag(Place.DNSMode.google)
                Text("Custom").tag(Place.DNSMode.custom)
            }
            .pickerStyle(.segmented).labelsHidden()
            if place.dnsMode == .custom {
                ChipGroup(title: "Servers (up to 8)", icon: "server.rack", items: place.customDNS, placeholder: "add server",
                          example: "192.168.1.1", validate: Validation.isValidIP) { v in update { $0.customDNS = Array(v.prefix(8)) } }
            }
            if let servers = place.dnsServers {
                HStack(alignment: .top) {
                    Button(testing ? "Testing…" : "Test DNS") { test(servers) }.controlSize(.small).disabled(testing)
                    FlowLayout(spacing: 6) {
                        ForEach(servers, id: \.self) { s in
                            if let r = dnsResults[s] {
                                Text("\(s) \(r.map { String(format: "%.0f ms", $0) } ?? "no answer")")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(r == nil ? Color.red : .green)
                            }
                        }
                    }
                }
                Text("If none answer after the place starts, your usual DNS comes back on its own.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }

    private var proxyEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("", selection: Binding(get: { place.proxy?.mode.rawValue ?? "keep" }, set: { v in
                update { $0.proxy = v == "keep" ? nil : ProxySetting(mode: ProxySetting.Mode(rawValue: v) ?? .off,
                                                                    http: $0.proxy?.http, https: $0.proxy?.https,
                                                                    socks: $0.proxy?.socks, bypass: $0.proxy?.bypass ?? [],
                                                                    pacURL: $0.proxy?.pacURL) }
            })) {
                Text("Keep").tag("keep")
                Text("None").tag("off")
                Text("Manual").tag("manual")
                Text("PAC file").tag("auto")
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 300)
            if let p = place.proxy, p.mode == .manual {
                proxyField("HTTP", \.http)
                proxyField("HTTPS", \.https)
                proxyField("SOCKS", \.socks)
                ChipGroup(title: "Skip proxy for", icon: "arrow.uturn.right", items: p.bypass, placeholder: "add host",
                          example: "*.local", validate: ProxySetting.isValidBypass) { v in update { $0.proxy?.bypass = v } }
            }
            if let p = place.proxy, p.mode == .auto {
                TextField("http://wpad.lan/proxy.pac", text: Binding(get: { p.pacURL ?? "" },
                                                                     set: { v in update { $0.proxy?.pacURL = v.isEmpty ? nil : v } }))
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    private func proxyField(_ label: String, _ key: WritableKeyPath<ProxySetting, String?>) -> some View {
        HStack {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 50, alignment: .leading)
            TextField("host:port", text: Binding(get: { place.proxy?[keyPath: key] ?? "" },
                                                 set: { v in update { $0.proxy?[keyPath: key] = v.isEmpty ? nil : v } }))
                .textFieldStyle(.roundedBorder)
        }
    }

    private func tunnelChips(_ title: String, _ items: [String], other: [String],
                             _ onChange: @escaping ([String]) -> Void) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
            ForEach(items, id: \.self) { n in
                HStack(spacing: 3) {
                    Text(n).font(.system(size: 11))
                    Button { onChange(items.filter { $0 != n }) } label: { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(Color.primary.opacity(0.08)))
            }
            let free = store.profiles.map(\.name).filter { !items.contains($0) && !other.contains($0) }
            if !free.isEmpty {
                Menu {
                    ForEach(free, id: \.self) { n in Button(n) { onChange(items + [n]) } }
                } label: { Image(systemName: "plus.circle") }
                    .menuStyle(.borderlessButton).fixedSize()
            }
        }
    }

    private func row<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
            content()
        }
    }

    private func move(_ d: Int) {
        var list = store.places
        list.swapAt(index, index + d)
        store.savePlaces(list)
    }

    private func test(_ servers: [String]) {
        testing = true
        dnsResults = [:]
        Task {
            await withTaskGroup(of: (String, Double?).self) { g in
                for s in servers { g.addTask { (s, await DNSProbe.latency(s)) } }
                for await (s, r) in g { dnsResults[s] = r }
            }
            testing = false
        }
    }
}
