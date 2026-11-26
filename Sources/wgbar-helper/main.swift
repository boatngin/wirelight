import Foundation
import Darwin
import WGCore

let maxRequestSize = 64 * 1024

guard getuid() == 0 else {
    FileHandle.standardError.write(Data("wgbar-helper must run as root\n".utf8))
    exit(1)
}
signal(SIGPIPE, SIG_IGN)
umask(0o077)

let controller = TunnelController()
/// All controller access is serialized on this queue (socket requests + network watcher).
let controllerQueue = DispatchQueue(label: "io.github.boatngin.wirelight.controller")
controllerQueue.sync { controller.recoverOnStart() }

// Watch for default-route changes (Wi-Fi <-> hotspot, wake from sleep).
let networkTimer = DispatchSource.makeTimerSource(queue: controllerQueue)
networkTimer.schedule(deadline: .now() + 15, repeating: 15)
networkTimer.setEventHandler { controller.checkNetworkChange() }
networkTimer.resume()

/// Whether the peer is root or in the `admin` group. Standard users get a limited
/// request set (see `Request.allowedForStandardUsers`).
func isAdmin(_ fd: Int32) -> (Bool, uid_t) {
    var uid: uid_t = .max, gid: gid_t = .max  // never "root" if getpeereid fails
    guard getpeereid(fd, &uid, &gid) == 0 else { return (false, uid) }
    if uid == 0 { return (true, uid) }
    guard let adminGID = getgrnam("admin")?.pointee.gr_gid,
          let pw = getpwuid(uid) else { return (false, uid) }
    var groups = [Int32](repeating: 0, count: 64)
    var count = Int32(groups.count)
    guard getgrouplist(pw.pointee.pw_name, Int32(bitPattern: pw.pointee.pw_gid), &groups, &count) >= 0 else {
        return (false, uid)
    }
    return (groups.prefix(Int(count)).contains(Int32(bitPattern: adminGID)), uid)
}

func handle(_ request: Request, uid: uid_t, isAdmin: Bool) -> Response {
    do {
        if !isAdmin {
            guard request.allowedForStandardUsers else { return .failure("permission denied: needs an administrator") }
            // Standard users may only touch shared tunnels, and only as the admin allowed.
            switch request {
            case let .upShared(name):
                guard SharedStore.load(name)?.policy.usersCanConnect == true else {
                    return .failure("permission denied: an administrator hasn't allowed connecting '\(name)'")
                }
            case let .down(name):
                guard SharedStore.load(name)?.policy.usersCanDisconnect == true else {
                    return .failure("permission denied: you can't disconnect '\(name)'")
                }
            default: break
            }
        }
        switch request {
        case .ping:
            return Response(ok: true)
        case .status:
            return Response(ok: true, status: controller.status())
        case let .up(name, config):
            log("request: up \(name)")
            try controller.up(name: name, configText: config)
            return Response(ok: true, status: controller.status())
        case .refresh:
            controller.refresh()
            return Response(ok: true, status: controller.status())
        case let .setKillSwitch(name, enabled):
            log("request: kill switch \(name) \(enabled ? "on" : "off")")
            try controller.setKillSwitch(name, enabled: enabled)
            return Response(ok: true, status: controller.status())
        case .doctor:
            return Response(ok: true, messages: controller.doctor())
        case let .applyPlace(settings):
            log("request: place \(settings == nil ? "restore" : "apply")")
            try controller.applyPlace(settings)
            return Response(ok: true)
        case .flushDNS:
            controller.flushDNS()
            return Response(ok: true)
        case let .shareTunnel(name, config, options, policy):
            guard Validation.isValidTunnelName(name) else { throw TunnelError.invalidName(name) }
            if let err = options.validationError() { throw TunnelError.interfaceStartFailed(err) }
            _ = try WGConfig(parsing: config) // never store something that can't run
            log("request: share \(name) (connect: \(policy.usersCanConnect), disconnect: \(policy.usersCanDisconnect))")
            try SharedStore.save(SharedTunnel(name: name, config: config, options: options, policy: policy, owner: uid))
            return Response(ok: true, shared: SharedStore.all().map(SharedStore.info))
        case let .setSharePolicy(name, policy):
            guard var t = SharedStore.load(name) else { throw TunnelError.notUp("shared '\(name)'") }
            t.policy = policy
            try SharedStore.save(t)
            log("request: share policy \(name) (connect: \(policy.usersCanConnect), disconnect: \(policy.usersCanDisconnect))")
            return Response(ok: true, shared: SharedStore.all().map(SharedStore.info))
        case let .unshareTunnel(name):
            log("request: unshare \(name)")
            if controller.status().contains(where: { $0.name == name }) { try? controller.down(name: name) }
            SharedStore.remove(name)
            return Response(ok: true, status: controller.status(), shared: SharedStore.all().map(SharedStore.info))
        case .listShared:
            return Response(ok: true, shared: SharedStore.all().map(SharedStore.info))
        case let .setDynamicRoutes(name, cidrs):
            try controller.setDynamicRoutes(name, cidrs)
            return Response(ok: true, status: controller.status())
        case let .upShared(name):
            guard let t = SharedStore.load(name) else { throw TunnelError.notUp("shared '\(name)'") }
            log("request: up shared \(name) by uid \(uid)")
            try controller.up(name: name, configText: t.config, options: t.options)
            return Response(ok: true, status: controller.status())
        case let .upWithOptions(name, config, options):
            log("request: up \(name) (split DNS: \(options.splitDNSDomains.count), exclusions: \(options.excludedCIDRs.count))")
            try controller.up(name: name, configText: config, options: options)
            return Response(ok: true, status: controller.status())
        case let .down(name):
            log("request: down \(name)")
            try controller.down(name: name)
            return Response(ok: true, status: controller.status())
        }
    } catch {
        return .failure(String(describing: error))
    }
}

func serve(_ fd: Int32) {
    UnixSocket.setTimeout(fd, seconds: 5)
    let (admin, uid) = isAdmin(fd)
    let response: Response
    let callerProblem = uid == 0 ? nil : CallerCheck.verify(fd)
    if let callerProblem {
        log("rejected connection from uid \(uid): \(callerProblem)", error: true)
        response = .failure("permission denied: \(callerProblem)")
    } else {
        do {
            let body = try UnixSocket.readFrame(fd, maxSize: maxRequestSize)
            let request = try IPCFraming.decodeBody(Request.self, from: body)
            response = controllerQueue.sync { handle(request, uid: uid, isAdmin: admin) }
        } catch {
            log("bad request from uid \(uid): \(error)", error: true)
            response = .failure("bad request: \(error)")
        }
    }
    if let frame = try? IPCFraming.encode(response) { try? UnixSocket.writeAll(fd, frame) }
}

// MARK: listen

let path = wgbarSocketPath
unlink(path)
let listener = socket(AF_UNIX, SOCK_STREAM, 0)
guard listener >= 0 else { log("socket() failed: \(errno)", error: true); exit(1) }
do {
    var addr = try UnixSocket.address(path)
    guard UnixSocket.withSockaddr(&addr, { bind(listener, $0, $1) }) == 0 else {
        log("bind \(path) failed: \(String(cString: strerror(errno)))", error: true); exit(1)
    }
} catch {
    log("\(error)", error: true); exit(1)
}
let staffGID = getgrnam("staff")?.pointee.gr_gid ?? 20
chown(path, 0, staffGID)
chmod(path, 0o660)
guard listen(listener, 8) == 0 else { log("listen failed", error: true); exit(1) }
log("wgbar-helper \(WGCore.version) listening on \(path)")

while true {
    let client = accept(listener, nil, nil)
    if client < 0 {
        if errno != EINTR { log("accept failed: \(String(cString: strerror(errno)))", error: true) }
        continue
    }
    serve(client)
    close(client)
}
