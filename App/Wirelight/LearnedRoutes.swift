import Foundation
import WGCore

/// Outcome of the last route command run for a tunnel, shown on its page.
struct RouteRun: Equatable {
    var date: Date
    var applied: [String]
    var rejected: [String]
    var fromCache: Bool
    var error: String?
}

extension TunnelStore {
    /// Runs the tunnel's route command as this user (20 s limit), validates what it
    /// prints and hands the routes to the helper. Falls back to the last good list.
    func learnRoutes(_ name: String) async {
        guard let p = profile(name), !p.routeCommand.isEmpty, isActive(name) else { return }
        let (status, output) = await Self.runCommand(p.routeCommand, timeout: 20)
        let parsed = DynamicRoutes.parse(output)
        var run = RouteRun(date: Date(), applied: parsed.routes,
                           rejected: parsed.rejected.map { "\($0.0) (\($0.1))" }, fromCache: false)
        if status != 0 || parsed.routes.isEmpty {
            run.error = status != 0 ? "command exited \(status)" : "command printed no usable routes"
            run.applied = p.cachedRoutes
            run.fromCache = true
        }
        do {
            let r = try await HelperClient.send(.setDynamicRoutes(name: name, cidrs: run.applied), timeout: 30)
            guard r.ok else { throw StoreError.helper(r.error ?? "unknown helper error") }
            if !run.fromCache { editProfile(name) { $0.cachedRoutes = run.applied } }
            addLog("\(name): \(run.applied.count) learned route(s)\(run.fromCache ? " from cache" : "")",
                   isError: run.error != nil)
        } catch {
            run.error = String(describing: error)
            addLog("\(name): learned routes failed: \(error)", isError: true)
        }
        routeRuns[name] = run
    }

    func setRouteCommand(_ cmd: String, for name: String) {
        editProfile(name) { $0.routeCommand = cmd }
    }

    /// `/bin/zsh -lc` as the user, so their PATH and tools (cloud CLIs, jq) work.
    static func runCommand(_ command: String, timeout: TimeInterval) async -> (Int32, String) {
        await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/zsh")
                p.arguments = ["-lc", command]
                let out = Pipe()
                p.standardOutput = out
                p.standardError = FileHandle.nullDevice
                p.standardInput = FileHandle.nullDevice
                guard (try? p.run()) != nil else { cont.resume(returning: (-1, "")); return }
                let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
                // Cap the read at 1 MB: a runaway command can't exhaust memory.
                let data = out.fileHandleForReading.readData(ofLength: 1 << 20)
                p.waitUntilExit()
                killer.cancel()
                cont.resume(returning: (p.terminationStatus, String(decoding: data, as: UTF8.self)))
            }
        }
    }
}
