import AppKit
import Charts
import SwiftUI
import WGCore

/// Latency, loss and a grade for one tunnel, or a nudge to turn monitoring on.
struct QualityCard: View {
    @EnvironmentObject var store: TunnelStore
    let name: String

    var body: some View {
        if let q = store.qualitySummary(name) {
            let samples = store.qualitySamples[name] ?? []
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Link quality", systemImage: "waveform.path.ecg").font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(q.grade.rawValue)
                        .font(.system(size: 11, weight: .bold))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(q.grade.color.opacity(0.18)))
                        .foregroundStyle(q.grade.color)
                }
                HStack(spacing: 8) {
                    metric("Typical", q.median.map { String(format: "%.0f ms", $0) } ?? "–")
                    metric("95% under", q.p95.map { String(format: "%.0f ms", $0) } ?? "–")
                    metric("Loss", String(format: "%.1f %%", q.loss))
                    metric("Target", store.probeHost(name) ?? "–")
                }
                Chart {
                    ForEach(samples) { s in
                        if let rtt = s.rtt {
                            LineMark(x: .value("t", s.date), y: .value("ms", rtt))
                                .foregroundStyle(q.grade.color).interpolationMethod(.monotone)
                        }
                        if s.loss > 0 {
                            PointMark(x: .value("t", s.date), y: .value("ms", s.rtt ?? 0))
                                .foregroundStyle(.red).symbolSize(18)
                        }
                    }
                    RuleMark(y: .value("fair", store.quality.fairMs))
                        .foregroundStyle(Color.orange.opacity(0.35)).lineStyle(StrokeStyle(dash: [3, 3]))
                }
                .chartXAxis(.hidden)
                .chartYAxis {
                    AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { v in
                        AxisGridLine().foregroundStyle(Color.secondary.opacity(0.12))
                        AxisValueLabel { if let d = v.as(Double.self) { Text("\(Int(d)) ms").font(.system(size: 9)) } }
                    }
                }
                .frame(height: 90)
                .overlay { if samples.count < 2 { Text("Measuring…").font(.system(size: 11)).foregroundStyle(.secondary) } }
                Text("Red dots are probes with packet loss. Grade uses the last 10 probes.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .padding(12)
            .card()
        } else if !store.quality.enabled && store.isActive(name) {
            HStack {
                Image(systemName: "waveform.path.ecg").foregroundStyle(.secondary)
                Text("Link quality is off. Turn it on to see latency and packet loss.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Button("Turn on…") { store.mainSection = .settings }.controlSize(.small)
            }
            .padding(12)
            .card()
        }
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit().lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Everything that needs attention, across all tunnels: live problems first, then config advice.
struct HeadsUpView: View {
    @EnvironmentObject var store: TunnelStore

    private var withNotices: [String] { store.profiles.map(\.name).filter { !store.notices(for: $0).isEmpty } }
    private func configIssues(_ name: String) -> [ConfigIssue] {
        store.configText(name).map(ConfigLint.check)?.filter { $0.severity != .tip } ?? []
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Heads-up").font(.title2.weight(.semibold))
                    Text("Live problems with a fix, then advice from each tunnel's config.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                if withNotices.isEmpty {
                    Label("Nothing needs attention right now.", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green).font(.system(size: 13))
                        .padding(12).frame(maxWidth: .infinity, alignment: .leading).card()
                } else {
                    HealthStrip(names: withNotices)
                }
                ForEach(store.profiles) { p in
                    let issues = configIssues(p.name)
                    if !issues.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(p.name).font(.system(size: 13, weight: .semibold))
                                Spacer()
                                Button("Open in editor") { store.openBuilder(edit: p.name) }.controlSize(.small)
                            }
                            ChecksList(issues: issues)
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
        }
    }
}

/// The event log with search, an errors-only filter, copy and clear.
struct LogView: View {
    @EnvironmentObject var store: TunnelStore
    @State private var query = ""
    @State private var errorsOnly = false
    @State private var tunnel: String?

    private var entries: [LogEntry] {
        store.log.reversed().filter { e in
            (!errorsOnly || e.isError)
                && (tunnel.map { e.message.contains($0) } ?? true)
                && (query.isEmpty || e.message.localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text("Log").font(.title3.weight(.semibold))
                TextField("Search", text: $query).textFieldStyle(.roundedBorder).frame(maxWidth: 220)
                Picker("", selection: $tunnel) {
                    Text("All tunnels").tag(String?.none)
                    ForEach(store.profiles) { Text($0.name).tag(Optional($0.name)) }
                }
                .labelsHidden().fixedSize()
                Toggle("Errors only", isOn: $errorsOnly).toggleStyle(.checkbox)
                Spacer()
                Button { copy() } label: { Label("Copy", systemImage: "doc.on.doc") }.disabled(entries.isEmpty)
                Button(role: .destructive) { store.clearLog() } label: { Label("Clear", systemImage: "trash") }
                    .disabled(store.log.isEmpty)
            }
            .padding(16)
            Divider()
            if entries.isEmpty {
                Text(store.log.isEmpty ? "No events yet" : "No events match").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(entries) { e in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: e.isError ? "exclamationmark.circle.fill" : "circle.fill")
                            .font(.system(size: e.isError ? 10 : 5))
                            .foregroundStyle(e.isError ? Color.red : .secondary)
                            .frame(width: 12)
                        Text(e.date, format: .dateTime.hour().minute().second())
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Text(e.message)
                            .font(.system(size: 12))
                            .foregroundStyle(e.isError ? Color.red : .primary)
                            .textSelection(.enabled)
                    }
                }
            }
            Divider()
            Text("Helper log: log stream --predicate 'subsystem == \"io.github.boatngin.wirelight\"'")
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                .padding(.horizontal, 16).padding(.vertical, 6)
        }
    }

    private func copy() {
        let f = ISO8601DateFormatter()
        let text = entries.reversed().map { "\(f.string(from: $0.date)) \($0.isError ? "ERROR " : "")\($0.message)" }
            .joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
