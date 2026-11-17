import Foundation
import WGCore

/// Shared tunnels live here, readable by root only: configs hold private keys.
struct SharedTunnel: Codable {
    var name: String
    var config: String
    var options: UpOptions
    var policy: SharePolicy
    /// Admin uid that shared it.
    var owner: UInt32
}

enum SharedStore {
    static let dir = "/Library/Application Support/WGBar/shared"

    private static func path(_ name: String) -> String { "\(dir)/\(name).json" }

    static func save(_ t: SharedTunnel) throws {
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        chmod(dir, 0o700)
        let data = try JSONEncoder().encode(t)
        let tmp = path(t.name) + ".tmp"
        unlink(tmp)
        let fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw UnixSocketError.system("open shared", errno) }
        do { try UnixSocket.writeAll(fd, data); close(fd) } catch { close(fd); unlink(tmp); throw error }
        guard rename(tmp, path(t.name)) == 0 else { unlink(tmp); throw UnixSocketError.system("rename shared", errno) }
    }

    static func load(_ name: String) -> SharedTunnel? {
        guard Validation.isValidTunnelName(name), let d = FileManager.default.contents(atPath: path(name)),
              let t = try? JSONDecoder().decode(SharedTunnel.self, from: d), t.name == name else { return nil }
        return t
    }

    static func all() -> [SharedTunnel] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [])
            .filter { $0.hasSuffix(".json") }
            .compactMap { load(String($0.dropLast(5))) }
            .sorted { $0.name < $1.name }
    }

    static func remove(_ name: String) {
        guard Validation.isValidTunnelName(name) else { return }
        unlink(path(name))
    }

    static func info(_ t: SharedTunnel) -> SharedTunnelInfo {
        let cfg = try? WGConfig(parsing: t.config)
        return SharedTunnelInfo(name: t.name, endpoint: cfg?.peers.first?.endpoint,
                                addresses: cfg?.interface.addresses ?? [], policy: t.policy)
    }
}
