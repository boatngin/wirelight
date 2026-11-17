import Darwin
import Foundation
import WGCore

extension TunnelStore {
    /// Whether this macOS user is an administrator (in the `admin` group).
    static let isAdminUser: Bool = {
        guard let pw = getpwuid(getuid()), let admin = getgrnam("admin")?.pointee.gr_gid else { return false }
        var groups = [Int32](repeating: 0, count: 64)
        var count = Int32(groups.count)
        guard getgrouplist(pw.pointee.pw_name, Int32(bitPattern: pw.pointee.pw_gid), &groups, &count) >= 0 else { return false }
        return groups.prefix(Int(count)).contains(Int32(bitPattern: admin))
    }()

    func refreshShared() async {
        if Self.isDemo { return }
        if let r = try? await HelperClient.send(.listShared), r.ok { shared = r.shared ?? [] }
    }

    func sharedInfo(_ name: String) -> SharedTunnelInfo? { shared.first { $0.name == name } }

    /// Admin: hand the helper a root-only copy of this tunnel for every user on the Mac.
    func share(_ name: String, policy: SharePolicy) async {
        guard let text = KeychainStore.load(name) else { lastError = StoreError.missingConfig(name).description; return }
        do {
            let opts = profile(name)?.upOptions ?? UpOptions()
            let r = try await HelperClient.send(.shareTunnel(name: name, config: text, options: opts, policy: policy), timeout: 15)
            guard r.ok else { throw StoreError.helper(r.error ?? "unknown helper error") }
            shared = r.shared ?? shared
            addLog("Shared \(name) with all users on this Mac")
        } catch {
            lastError = String(describing: error)
            addLog(String(describing: error), isError: true)
        }
    }

    func setSharePolicy(_ name: String, _ policy: SharePolicy) async {
        guard let r = try? await HelperClient.send(.setSharePolicy(name: name, policy: policy), timeout: 15), r.ok else {
            lastError = "Couldn't change sharing for \(name)"
            return
        }
        shared = r.shared ?? shared
    }

    func unshare(_ name: String) async {
        do {
            let r = try await HelperClient.send(.unshareTunnel(name: name), timeout: 30)
            guard r.ok else { throw StoreError.helper(r.error ?? "unknown helper error") }
            shared = r.shared ?? []
            addLog("Stopped sharing \(name)")
            await refresh()
        } catch {
            lastError = String(describing: error)
        }
    }

    func connectShared(_ name: String) async {
        guard !isBusy(name), !isActive(name) else { return }
        await runBusy(name) {
            let r = try await HelperClient.send(.upShared(name: name), timeout: 30)
            guard r.ok else { throw StoreError.helper(r.error ?? "unknown helper error") }
            return r.status
        }
    }

    func disconnectShared(_ name: String) async {
        guard !isBusy(name), isActive(name) else { return }
        await runBusy(name) {
            let r = try await HelperClient.send(.down(name: name), timeout: 30)
            guard r.ok else { throw StoreError.helper(r.error ?? "unknown helper error") }
            return r.status
        }
    }
}
