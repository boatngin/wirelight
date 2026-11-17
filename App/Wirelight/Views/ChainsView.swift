import SwiftUI

/// Multi-hop: chains drawn as a path, This Mac → hop → exit → Internet, each with one switch.
struct ChainsView: View {
    @EnvironmentObject var store: TunnelStore
    @State private var newHop: String?
    @State private var newExit: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Multi-hop").font(.title2.weight(.semibold))
                    Text("The first tunnel carries the second one's encrypted traffic. The exit server sees the hop's address, the hop never sees what you send.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(store.chains) { ChainCard(chain: $0) }
                adder
            }
            .padding(20)
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
        }
    }

    private var adder: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus.circle").foregroundStyle(Color.accentColor)
            Picker("Hop", selection: $newHop) {
                Text("Hop…").tag(String?.none)
                ForEach(store.profiles) { Text($0.name).tag(Optional($0.name)) }
            }
            .fixedSize()
            Image(systemName: "arrow.right").foregroundStyle(.secondary)
            Picker("Exit", selection: $newExit) {
                Text("Exit…").tag(String?.none)
                ForEach(store.profiles.filter { $0.name != newHop }) { Text($0.name).tag(Optional($0.name)) }
            }
            .fixedSize()
            Spacer()
            Button("Add chain") {
                guard let h = newHop, let e = newExit else { return }
                store.saveChains(store.chains + [HopChain(hop: h, exit: e)])
                newHop = nil; newExit = nil
            }
            .disabled(newHop == nil || newExit == nil || newHop == newExit
                      || store.chains.contains { $0.hop == newHop && $0.exit == newExit })
        }
        .labelsHidden()
        .padding(12)
        .card()
    }
}

private struct ChainCard: View {
    @EnvironmentObject var store: TunnelStore
    let chain: HopChain

    private var up: Bool { store.isChainUp(chain) }
    private var busy: Bool { store.isBusy(chain.hop) || store.isBusy(chain.exit) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 0) {
                node("This Mac", icon: "laptopcomputer", color: .primary, sub: nil)
                link(on: store.isActive(chain.hop))
                node(chain.hop, icon: "1.circle.fill", color: StatusStyle.color(store, chain.hop), sub: "hop")
                link(on: up)
                node(chain.exit, icon: "2.circle.fill", color: up ? StatusStyle.color(store, chain.exit) : .secondary, sub: "exit")
                link(on: up)
                node("Internet", icon: "globe", color: up ? .green : .secondary, sub: nil)
            }
            HStack {
                Text(status).font(.system(size: 11)).foregroundStyle(up ? .green : .secondary)
                Spacer()
                Button(role: .destructive) { store.saveChains(store.chains.filter { $0.id != chain.id }) } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain).foregroundStyle(.red).disabled(up)
                Toggle("", isOn: Binding(get: { up }, set: { on in
                    Task { on ? await store.connectChain(chain) : await store.disconnectChain(chain) }
                }))
                .toggleStyle(.switch).labelsHidden().disabled(busy || !store.helperReachable)
            }
        }
        .padding(14)
        .card(tint: up ? .green : nil)
    }

    private var status: String {
        if busy { return "Working…" }
        if up { return "Your traffic leaves from \(chain.exit)'s server; \(chain.hop) only sees encrypted packets." }
        if store.isActive(chain.exit) { return "\(chain.exit) is up on its own; turning the chain on reconnects it through \(chain.hop)." }
        return "Off"
    }

    private func node(_ title: String, icon: String, color: Color, sub: String?) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 18)).foregroundStyle(color)
                .frame(width: 38, height: 38)
                .background(Circle().fill(color.opacity(0.12)))
            Text(title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
            Text(sub ?? " ").font(.system(size: 9)).foregroundStyle(.secondary)
        }
        .frame(width: 84)
    }

    private func link(on: Bool) -> some View {
        Rectangle()
            .fill(on ? Color.green : Color.secondary.opacity(0.3))
            .frame(height: 2)
            .overlay(Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold))
                .foregroundStyle(on ? Color.green : .secondary))
            .frame(maxWidth: .infinity)
            .padding(.bottom, 26)
    }
}
