import SwiftUI
import WGCore

/// "On this network → do this" rows for one tunnel, plus what happens everywhere else.
/// Shows which rule applies right now, so the user can see the effect immediately.
struct RulesEditor: View {
    @EnvironmentObject var store: TunnelStore
    let profile: TunnelProfile

    private var rules: [NetworkRule] { profile.rules }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            nowLine
            ForEach(Array(rules.enumerated()), id: \.element.id) { i, rule in
                ruleRow(i, rule)
            }
            HStack(spacing: 8) {
                Menu {
                    Button("Wi-Fi network…") { add(.wifi, values: store.currentSSID().map { [$0] } ?? []) }
                    Button("Any Wi-Fi") { add(.wifi) }
                    Button("Ethernet subnet…") { add(.ethernet, values: currentSubnet().map { [$0] } ?? []) }
                    Button("Any Ethernet") { add(.ethernet) }
                } label: { Label("Add rule", systemImage: "plus") }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                Spacer()
                Text("Everywhere else").font(.system(size: 12)).foregroundStyle(.secondary)
                Picker("", selection: Binding(get: { profile.otherwise },
                                              set: { save(rules, otherwise: $0) })) {
                    Text("Leave as is").tag(NetworkRule.Action?.none)
                    Text("Connect").tag(NetworkRule.Action?.some(.connect))
                    Text("Disconnect").tag(NetworkRule.Action?.some(.disconnect))
                }
                .labelsHidden()
                .fixedSize()
            }
        }
    }

    private var nowLine: some View {
        let net = store.currentNetwork()
        let place = net.wifiSSID.map { "Wi-Fi “\($0)”" }
            ?? (net.onEthernet ? "Ethernet \(net.ethernetAddresses.first ?? "")" : "No network")
        let decision = NetworkRules.decide(rules, fallback: profile.otherwise, on: net)
        let effect: String = {
            guard let d = decision else { return "nothing changes" }
            let verb = d.action == .connect ? "connects" : "disconnects"
            return d.rule.map { "rule \($0 + 1) \(verb) it" } ?? "\(verb) (everywhere else)"
        }()
        return HStack(spacing: 6) {
            Image(systemName: "location.circle").foregroundStyle(Color.accentColor)
            Text("Now: \(place) · \(effect)").font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private func ruleRow(_ i: Int, _ rule: NetworkRule) -> some View {
        let active = NetworkRules.decide(rules, fallback: nil, on: store.currentNetwork())?.rule == i
        return HStack(alignment: .top, spacing: 8) {
            Text("\(i + 1)")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .frame(width: 18, height: 18)
                .background(Circle().fill(active ? Color.accentColor : Color.primary.opacity(0.1)))
                .foregroundStyle(active ? Color.white : .secondary)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: rule.kind == .wifi ? "wifi" : "cable.connector")
                    Text(rule.values.isEmpty ? (rule.kind == .wifi ? "Any Wi-Fi" : "Any Ethernet")
                                             : (rule.kind == .wifi ? "Wi-Fi named" : "Ethernet in"))
                        .font(.system(size: 12, weight: .medium))
                }
                do {
                    ChipGroup(title: rule.kind == .wifi ? "Names, case-sensitive (none = any Wi-Fi)"
                                                        : "Subnets (none = any Ethernet)",
                              icon: rule.kind == .wifi ? "textformat" : "number",
                              items: rule.values, placeholder: rule.kind == .wifi ? "add name" : "add subnet",
                              lowercase: false, example: rule.kind == .wifi ? "HomeWiFi" : "10.20.0.0/16",
                              validate: rule.kind == .wifi ? Validation.isValidSSID : Validation.isValidCIDR) { list in
                        update(i) { $0.values = list }
                    }
                }
            }
            Spacer()
            Picker("", selection: Binding(get: { rule.action }, set: { a in update(i) { $0.action = a } })) {
                Text("Connect").tag(NetworkRule.Action.connect)
                Text("Disconnect").tag(NetworkRule.Action.disconnect)
            }
            .labelsHidden()
            .fixedSize()
            VStack(spacing: 2) {
                Button { move(i, by: -1) } label: { Image(systemName: "chevron.up") }.disabled(i == 0)
                Button { move(i, by: 1) } label: { Image(systemName: "chevron.down") }.disabled(i == rules.count - 1)
            }
            .buttonStyle(.plain).font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
            Button { save(rules.enumerated().filter { $0.offset != i }.map(\.element), otherwise: profile.otherwise) } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain).foregroundStyle(.red)
        }
        .padding(8)
        .card(tint: active ? .accentColor : nil, radius: 9)
    }

    private func add(_ kind: NetworkRule.Kind, values: [String] = []) {
        // A named rule with no value yet would match anything, so seed it or make it explicit.
        save(rules + [NetworkRule(kind: kind, values: values, action: kind == .wifi && values.isEmpty ? .connect : .disconnect)],
             otherwise: profile.otherwise)
    }

    private func update(_ i: Int, _ change: (inout NetworkRule) -> Void) {
        var list = rules
        change(&list[i])
        save(list, otherwise: profile.otherwise)
    }

    private func move(_ i: Int, by d: Int) {
        var list = rules
        list.swapAt(i, i + d)
        save(list, otherwise: profile.otherwise)
    }

    private func save(_ list: [NetworkRule], otherwise: NetworkRule.Action?) {
        Task { await store.setRules(list, otherwise: otherwise, for: profile.name) }
    }

    /// The /24 (IPv4) of the first Ethernet address, as a sensible starting subnet.
    private func currentSubnet() -> String? {
        guard let ip = store.currentNetwork().ethernetAddresses.first(where: Validation.isValidIPv4) else { return nil }
        let p = ip.split(separator: ".")
        return "\(p[0]).\(p[1]).\(p[2]).0/24"
    }
}
