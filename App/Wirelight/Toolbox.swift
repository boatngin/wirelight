import AppKit
import Darwin
import Foundation
import WGCore

/// SSH forwards, Wake-on-LAN devices and other mesh VPNs, run as the logged-in user.
@MainActor
final class Toolbox: ObservableObject {
    static let shared = Toolbox()

    struct ForwardState { var running = false; var error: String?; var retryAt: Date? }

    @Published var forwards: [SSHForward] = [] { didSet { save(forwards, "sshForwards") } }
    @Published var devices: [WakeDevice] = [] { didSet { save(devices, "wakeDevices") } }
    @Published private(set) var state: [UUID: ForwardState] = [:]
    @Published private(set) var mesh: [MeshStatus] = []

    private var processes: [UUID: Process] = [:]
    private var backoff: [UUID: Double] = [:]
    private var startedAt: [UUID: Date] = [:]

    private init() {
        if TunnelStore.isDemo { return }
        forwards = load("sshForwards")
        devices = load("wakeDevices")
        for f in forwards where f.enabled { start(f) }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil,
                                               queue: .main) { _ in SSHChildren.terminateAll() }
    }

    private func load<T: Decodable>(_ key: String) -> [T] {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode([T].self, from: $0) } ?? []
    }

    private func save<T: Encodable>(_ v: [T], _ key: String) {
        if !TunnelStore.isDemo { UserDefaults.standard.set(try? JSONEncoder().encode(v), forKey: key) }
    }

    // MARK: SSH forwards

    func setEnabled(_ on: Bool, _ f: SSHForward) {
        guard let i = forwards.firstIndex(where: { $0.id == f.id }) else { return }
        forwards[i].enabled = on
        on ? start(forwards[i]) : stop(f.id)
    }

    func update(_ f: SSHForward) {
        guard let i = forwards.firstIndex(where: { $0.id == f.id }) else { return }
        let wasOn = forwards[i].enabled
        stop(f.id)
        forwards[i] = f
        if wasOn { start(f) }
    }

    func remove(_ f: SSHForward) {
        stop(f.id)
        forwards.removeAll { $0.id == f.id }
    }

    private func start(_ f: SSHForward) {
        if let err = f.validationError() { state[f.id] = ForwardState(error: err); return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = f.sshArguments()
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        p.terminationHandler = { proc in
            let msg = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            Task { @MainActor in Toolbox.shared.exited(f.id, status: proc.terminationStatus, message: msg) }
        }
        do {
            try p.run()
            processes[f.id] = p
            SSHChildren.all[f.id] = p
            startedAt[f.id] = Date()
            state[f.id] = ForwardState(running: true)
        } catch {
            state[f.id] = ForwardState(error: error.localizedDescription)
        }
    }

    /// ssh ended: if the forward is still on, try again after 2 s, doubling up to 1 min.
    private func exited(_ id: UUID, status: Int32, message: String) {
        guard processes[id] != nil else { return } // stopped on purpose
        processes[id] = nil
        SSHChildren.all[id] = nil
        guard let f = forwards.first(where: { $0.id == id }), f.enabled else { return }
        // A forward that held for a while starts its backoff over.
        if let s = startedAt[id], Date().timeIntervalSince(s) > 30 { backoff[id] = nil }
        let delay = min(60, (backoff[id] ?? 1) * 2)
        backoff[id] = delay
        let line = message.split(separator: "\n").last.map(String.init) ?? "ssh exited (\(status))"
        state[id] = ForwardState(running: false, error: line, retryAt: Date().addingTimeInterval(delay))
        Task {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let f = forwards.first(where: { $0.id == id }), f.enabled, processes[id] == nil else { return }
            start(f)
        }
    }

    private func stop(_ id: UUID) {
        let p = processes.removeValue(forKey: id)
        SSHChildren.all[id] = nil
        p?.terminate()
        backoff[id] = nil
        state[id] = nil
    }

    func stopAll() { for id in Array(processes.keys) { stop(id) } }

    // MARK: Wake-on-LAN

    /// Sends the magic packet by UDP broadcast to port 9. Only reaches the local network.
    func wake(_ d: WakeDevice) -> String {
        guard let packet = WakeOnLAN.packet(mac: d.mac) else { return "Invalid MAC address" }
        guard Validation.isValidIPv4(d.broadcast) else { return "Broadcast must be an IPv4 address" }
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return "Couldn't open a socket" }
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(9).bigEndian
        inet_pton(AF_INET, d.broadcast, &addr.sin_addr)
        let sent = packet.withUnsafeBytes { buf in
            withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, buf.baseAddress, buf.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        return sent == packet.count ? "Magic packet sent to \(d.name)" : "Sending failed: \(String(cString: strerror(errno)))"
    }

    // MARK: Mesh VPNs

    func refreshMesh() async {
        var out: [MeshStatus] = []
        for kind in MeshStatus.Kind.allCases {
            if let s = await MeshStatus.read(kind) { out.append(s) }
        }
        mesh = out
    }

    func meshAction(_ kind: MeshStatus.Kind, _ args: [String]) async -> String? {
        guard let cli = kind.cli else { return "\(kind.title) isn't installed" }
        let (status, text) = await MeshStatus.run(cli, args)
        await refreshMesh()
        return status == 0 ? nil : (text.isEmpty ? "\(kind.title) exited \(status)" : text)
    }
}

/// ssh children, ended synchronously on quit so no forward outlives the app.
enum SSHChildren {
    /// Touched on the main thread only.
    static var all: [UUID: Process] = [:]

    static func terminateAll() {
        for p in all.values where p.isRunning { p.terminate() }
        all = [:]
    }
}

/// What a Tailscale or NetBird client reports through its own command line.
struct MeshStatus: Identifiable {
    enum Kind: String, CaseIterable {
        case tailscale, netbird
        var title: String { self == .tailscale ? "Tailscale" : "NetBird" }

        var cli: String? {
            let paths = self == .tailscale
                ? ["/Applications/Tailscale.app/Contents/MacOS/Tailscale", "/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale"]
                : ["/opt/homebrew/bin/netbird", "/usr/local/bin/netbird", "/Applications/NetBird.app/Contents/MacOS/netbird"]
            return paths.first { FileManager.default.isExecutableFile(atPath: $0) }
        }
    }

    struct ExitNode: Hashable { let name: String; let ip: String; let active: Bool }

    let kind: Kind
    let running: Bool
    let summary: String
    let addresses: [String]
    let exitNodes: [ExitNode]
    var id: String { kind.rawValue }

    static func read(_ kind: Kind) async -> MeshStatus? {
        guard let cli = kind.cli else { return nil }
        let (_, text) = await run(cli, ["status", "--json"])
        guard let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            return MeshStatus(kind: kind, running: false, summary: "Not running", addresses: [], exitNodes: [])
        }
        switch kind {
        case .tailscale:
            let state = json["BackendState"] as? String ?? "?"
            let me = json["Self"] as? [String: Any]
            let peers = (json["Peer"] as? [String: [String: Any]] ?? [:]).values
            let exits = peers.filter { $0["ExitNodeOption"] as? Bool == true }.compactMap { p -> ExitNode? in
                guard let ip = (p["TailscaleIPs"] as? [String])?.first else { return nil }
                return ExitNode(name: p["HostName"] as? String ?? ip, ip: ip, active: p["ExitNode"] as? Bool == true)
            }.sorted { $0.name < $1.name }
            let online = peers.filter { $0["Online"] as? Bool == true }.count
            let tailnet = (json["CurrentTailnet"] as? [String: Any])?["Name"] as? String
            return MeshStatus(kind: kind, running: state == "Running",
                              summary: "\(state)\(tailnet.map { " · \($0)" } ?? "") · \(online) of \(peers.count) peers online",
                              addresses: me?["TailscaleIPs"] as? [String] ?? [], exitNodes: exits)
        case .netbird:
            let connected = (json["management"] as? [String: Any])?["connected"] as? Bool ?? false
            let peers = json["peers"] as? [String: Any]
            let ip = json["netbirdIp"] as? String
            return MeshStatus(kind: kind, running: connected,
                              summary: "\(connected ? "Connected" : "Disconnected") · \(peers?["connected"] as? Int ?? 0) of \(peers?["total"] as? Int ?? 0) peers",
                              addresses: ip.map { [$0] } ?? [], exitNodes: [])
        }
    }

    static func run(_ path: String, _ args: [String]) async -> (Int32, String) {
        await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: path)
                p.arguments = args
                let out = Pipe()
                p.standardOutput = out
                p.standardError = out
                guard (try? p.run()) != nil else { cont.resume(returning: (-1, "couldn't start \(path)")); return }
                let d = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                cont.resume(returning: (p.terminationStatus, String(decoding: d, as: UTF8.self)))
            }
        }
    }
}
