import SwiftUI

/// Route command field, a Run now button and what the last run did.
struct LearnedRoutesBlock: View {
    @EnvironmentObject var store: TunnelStore
    let profile: TunnelProfile
    @State private var draft = ""
    @State private var running = false

    private var run: RouteRun? { store.routeRuns[profile.name] }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("e.g. ~/bin/inventory.sh prod", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .onSubmit { store.setRouteCommand(draft, for: profile.name) }
                Button("Save") { store.setRouteCommand(draft, for: profile.name) }
                    .disabled(draft == profile.routeCommand)
                Button(running ? "Running…" : "Run now") {
                    store.setRouteCommand(draft, for: profile.name)
                    running = true
                    Task { await store.learnRoutes(profile.name); running = false }
                }
                .disabled(running || draft.isEmpty || !store.isActive(profile.name))
                .help(store.isActive(profile.name) ? "Run the command and apply its routes" : "Connect the tunnel first")
            }
            .controlSize(.small)
            if let run {
                Text(summary(run))
                    .font(.system(size: 11))
                    .foregroundStyle(run.error == nil ? Color.green : .orange)
                if !run.rejected.isEmpty {
                    Text("Refused: " + run.rejected.prefix(5).joined(separator: ", ") + (run.rejected.count > 5 ? " …" : ""))
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
            let shown = run?.applied ?? profile.cachedRoutes
            if !shown.isEmpty {
                FlowLayout(spacing: 4) {
                    ForEach(shown.prefix(40), id: \.self) { c in
                        Text(c).font(.system(size: 10, design: .monospaced))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Color.primary.opacity(0.07)))
                    }
                    if shown.count > 40 { Text("+\(shown.count - 40) more").font(.system(size: 10)).foregroundStyle(.secondary) }
                }
            }
        }
        .onAppear { draft = profile.routeCommand }
    }

    private func summary(_ r: RouteRun) -> String {
        let when = Format.relative(r.date)
        if let e = r.error { return "\(e) · using \(r.applied.count) cached route(s) · \(when)" }
        return "\(r.applied.count) route(s) applied · \(when)"
    }
}
