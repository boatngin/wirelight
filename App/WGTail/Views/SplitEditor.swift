import SwiftUI
import WGCore

/// Compact split tunnel editor for the menu dropdown:
/// chips you can remove with one click and an inline field to add more.
struct SplitCard: View {
    @EnvironmentObject var store: TunnelStore
    let profile: TunnelProfile
    @AppStorage("menu.splitExpanded") private var expanded = false

    private var ruleCount: Int { profile.splitDNSDomains.count + profile.excludedCIDRs.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.branch").font(.system(size: 11)).foregroundStyle(.secondary)
                    Text("Split tunnel").font(.system(size: 12, weight: .semibold))
                    if ruleCount > 0 {
                        Text("\(ruleCount)")
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                            .foregroundStyle(Color.accentColor)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                ChipGroup(title: "DNS only for", icon: "network",
                          items: profile.splitDNSDomains, placeholder: "lan",
                          validate: Validation.isValidHostname) { list in
                    Task { await store.setSplitDNS(list, for: profile.name) }
                }
                if !profile.splitDNSDomains.isEmpty && (store.config(profile.name)?.interface.dns.isEmpty ?? true) {
                    Text("This config has no DNS server, so split DNS won't apply.")
                        .font(.system(size: 10)).foregroundStyle(.orange)
                }
                ChipGroup(title: "Bypass tunnel", icon: "arrow.uturn.right",
                          items: profile.excludedCIDRs, placeholder: "10.0.5.0/24",
                          validate: Validation.isValidCIDR) { list in
                    Task { await store.setExclusions(list, for: profile.name) }
                }
                if store.active?.name == profile.name {
                    Text("Changes reconnect the tunnel.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
        }
        .disabled(store.busy)
    }
}

struct ChipGroup: View {
    let title: String
    let icon: String
    let items: [String]
    let placeholder: String
    let validate: (String) -> Bool
    let onChange: ([String]) -> Void

    @State private var draft = ""
    @State private var invalid = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: icon)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            FlowLayout(spacing: 4) {
                ForEach(items, id: \.self) { item in
                    HStack(spacing: 3) {
                        Text(item).font(.system(size: 11, design: .monospaced))
                        Button { onChange(items.filter { $0 != item }) } label: {
                            Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Remove \(item)")
                    }
                    .padding(.leading, 8).padding(.trailing, 6).padding(.vertical, 3)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
                }
                HStack(spacing: 3) {
                    TextField(placeholder, text: $draft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(width: 96)
                        .focused($focused)
                        .onSubmit(add)
                        .onChange(of: draft) { _ in invalid = false }
                    Button(action: add) {
                        Image(systemName: "plus").font(.system(size: 9, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(draft.isEmpty ? Color.secondary : Color.accentColor)
                    .help("Add")
                }
                .padding(.leading, 8).padding(.trailing, 6).padding(.vertical, 3)
                .background(
                    Capsule().strokeBorder(invalid ? Color.red : (focused ? Color.accentColor : Color.primary.opacity(0.15)),
                                           style: StrokeStyle(lineWidth: 1, dash: focused || invalid ? [] : [3, 2])))
            }
            if invalid {
                Text("Check the format, e.g. \(placeholder)").font(.system(size: 10)).foregroundStyle(.red)
            }
        }
    }

    private func add() {
        let value = draft.trimmingCharacters(in: .whitespaces).lowercased()
        guard !value.isEmpty else { return }
        guard validate(value) else { invalid = true; return }
        if !items.contains(value) { onChange(items + [value]) }
        draft = ""
    }
}

/// Simple wrapping layout for chips (macOS 13+ Layout protocol).
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, maxX: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > width { x = 0; y += rowH + spacing; rowH = 0 }
            x += s.width + spacing
            rowH = max(rowH, s.height)
            maxX = max(maxX, x - spacing)
        }
        return CGSize(width: proposal.width ?? maxX, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX && x + s.width > bounds.maxX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
    }
}
