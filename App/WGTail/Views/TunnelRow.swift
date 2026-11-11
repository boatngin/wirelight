import SwiftUI

struct TunnelRow: View {
    let profile: TunnelProfile
    let isActive: Bool
    let busy: Bool
    let onConnect: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(isActive ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(profile.name).font(.system(size: 13, weight: .medium))
                Text(profile.endpoint ?? "no endpoint")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if isActive {
                Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
            } else if hovering {
                Button("Connect", action: onConnect)
                    .controlSize(.small)
                    .disabled(busy)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Color.primary.opacity(0.07) : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { if !isActive && !busy { onConnect() } }
    }
}
