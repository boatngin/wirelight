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
controller.recoverOnStart()

/// Only root or members of the `admin` group may talk to the helper.
func isAuthorized(_ fd: Int32) -> (Bool, uid_t) {
    var uid: uid_t = 0, gid: gid_t = 0
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

func handle(_ request: Request) -> Response {
    do {
        switch request {
        case .ping:
            return Response(ok: true)
        case .status:
            return Response(ok: true, status: controller.status())
        case let .up(name, config):
            log("request: up \(name)")
            try controller.up(name: name, configText: config)
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
    let (allowed, uid) = isAuthorized(fd)
    let response: Response
    if !allowed {
        log("rejected connection from uid \(uid) (not admin)", error: true)
        response = .failure("permission denied: user must be an administrator")
    } else {
        do {
            let body = try UnixSocket.readFrame(fd, maxSize: maxRequestSize)
            response = handle(try IPCFraming.decodeBody(Request.self, from: body))
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
