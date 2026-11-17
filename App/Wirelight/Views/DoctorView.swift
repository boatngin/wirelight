import SwiftUI

/// Network Doctor: one Scan button, findings worst first, each with what was seen.
struct DoctorView: View {
    @EnvironmentObject var store: TunnelStore
    @State private var findings: [DoctorFinding]?
    @State private var scanning = false
    @State private var scannedAt: Date?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Network Doctor").font(.title2.weight(.semibold))
                        Text("Other VPNs, and routes or DNS that fight your tunnels. Reads only; changes nothing.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    PillButton(icon: "stethoscope", title: scanning ? "Scanning…" : "Scan", tint: .accentColor) { scan() }
                }
                if let scannedAt {
                    Text("Scanned \(scannedAt.formatted(date: .omitted, time: .standard)) with \(store.activeNames.count) tunnel(s) up")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                if let findings {
                    if findings.isEmpty {
                        Label("No conflicts found.", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                            .padding(12).frame(maxWidth: .infinity, alignment: .leading).card()
                    }
                    ForEach(findings) { f in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: icon(f.level)).foregroundStyle(color(f.level)).font(.system(size: 14))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(f.title).font(.system(size: 13, weight: .semibold))
                                Text(f.detail).font(.system(size: 12)).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text(f.evidence).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(12)
                        .card(tint: f.level == .info ? nil : color(f.level))
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
        }
        .onAppear { if findings == nil { scan() } }
    }

    private func scan() {
        guard !scanning else { return }
        scanning = true
        Task {
            findings = await NetworkDoctor.scan(store)
            scannedAt = Date()
            scanning = false
        }
    }

    private func icon(_ l: DoctorFinding.Level) -> String {
        switch l {
        case .problem: return "xmark.octagon.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .info: return "info.circle.fill"
        }
    }

    private func color(_ l: DoctorFinding.Level) -> Color {
        switch l {
        case .problem: return .red
        case .warning: return .orange
        case .info: return .blue
        }
    }
}
