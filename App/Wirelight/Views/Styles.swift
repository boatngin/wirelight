import SwiftUI

/// Shared card look used by the menu dropdown and the dashboard window.
struct CardBackground: ViewModifier {
    var tint: Color?
    var radius: CGFloat = 12

    func body(content: Content) -> some View {
        content.background(
            RoundedRectangle(cornerRadius: radius)
                .fill(tint.map { $0.opacity(0.10) } ?? Color.primary.opacity(0.05))
                .overlay(RoundedRectangle(cornerRadius: radius)
                    .strokeBorder((tint ?? Color.primary).opacity(tint == nil ? 0.07 : 0.30), lineWidth: 0.5)))
    }
}

extension View {
    func card(tint: Color? = nil, radius: CGFloat = 12) -> some View {
        modifier(CardBackground(tint: tint, radius: radius))
    }
}

/// Small rounded action button used in the dashboard.
struct PillButton: View {
    let icon: String
    let title: String
    var tint: Color = .primary
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 11))
                Text(title).font(.system(size: 12))
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.primary.opacity(hovering ? 0.12 : 0.06)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

enum StatusStyle {
    static func color(connected: Bool, stale: Bool) -> Color {
        guard connected else { return .secondary }
        return stale ? .orange : .green
    }
}
