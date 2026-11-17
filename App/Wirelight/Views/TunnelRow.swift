import SwiftUI

/// One tunnel in the menu list: status dot, live rate when up, and its own switch.
/// Clicking the row focuses it in the menu hero.
struct TunnelRow: View {
    @EnvironmentObject var store: TunnelStore
    let profile: TunnelProfile
    let focused: Bool

    @State private var hovering = false

    private var isActive: Bool { store.isActive(profile.name) }
    private var busy: Bool { store.isBusy(profile.name) }
    private var color: Color { StatusStyle.color(connected: isActive, stale: store.isStale(profile.name)) }

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if busy { PingBadge(color: color, animating: true, fast: true) }
                else { Circle().fill(isActive ? color : Color.secondary.opacity(0.35)).padding(3) }
            }
            .frame(width: 14, height: 14)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(profile.name).font(.system(size: 12, weight: focused ? .semibold : .medium))
                    if profile.favorite { Image(systemName: "star.fill").font(.system(size: 7)).foregroundStyle(.yellow) }
                }
                Text(subtitle)
                    .font(.system(size: 10, design: isActive ? .monospaced : .default))
                    .foregroundStyle(isActive ? color : .secondary)
                    .lineLimit(1)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { isActive },
                set: { on in Task { on ? await store.connect(profile.name) : await store.disconnect(profile.name) } }))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .disabled(busy || !store.helperReachable)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(focused ? Color.accentColor.opacity(0.10) : (hovering ? Color.primary.opacity(0.07) : .clear)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { store.selectedName = profile.name }
    }

    private var subtitle: String {
        if busy { return isActive ? "Disconnecting…" : "Connecting…" }
        guard isActive else { return profile.endpoint ?? "no endpoint" }
        let s = store.samples(profile.name).last
        return "↓ \(Format.rate(s?.rx ?? 0))  ↑ \(Format.rate(s?.tx ?? 0))"
    }
}
