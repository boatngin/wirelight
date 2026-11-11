import Foundation
import WGCore

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data("wgbarctl: \(msg)\n".utf8))
    exit(1)
}

let usage = """
usage: wgbarctl ping
       wgbarctl status
       wgbarctl up <name> <file.conf>
       wgbarctl down <name>
       wgbarctl refresh
       wgbarctl doctor
"""

/// Client-side checks that need no helper, then the helper's own report.
func doctor() -> Never {
    var failed = false
    func report(_ ok: Bool, _ msg: String, warnOnly: Bool = false) {
        print("\(ok ? "ok  " : (warnOnly ? "warn" : "FAIL"))  \(msg)")
        if !ok && !warnOnly { failed = true }
    }
    let fm = FileManager.default
    report(fm.fileExists(atPath: "/Library/LaunchDaemons/com.thanaboat.wgbar.helper.plist"),
           "LaunchDaemon plist installed")
    report(fm.isExecutableFile(atPath: "/Library/PrivilegedHelperTools/wgbar-helper"), "helper binary installed")

    if let attrs = try? fm.attributesOfItem(atPath: wgbarSocketPath) {
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        let owner = (attrs[.ownerAccountName] as? String) ?? "?"
        let group = (attrs[.groupOwnerAccountName] as? String) ?? "?"
        report(perms == 0o660 && owner == "root" && group == "staff",
               "socket \(wgbarSocketPath) \(owner):\(group) \(String(perms, radix: 8))")
    } else {
        report(false, "socket \(wgbarSocketPath) missing (helper not running?)")
    }

    let isAdmin = (getgrnam("admin")?.pointee.gr_gid).map { gid -> Bool in
        var groups = [gid_t](repeating: 0, count: 64)
        let n = getgroups(Int32(groups.count), &groups)
        return n > 0 && groups.prefix(Int(n)).contains(gid)
    } ?? false
    report(isAdmin, "current user is in group admin")

    do {
        let r = try UnixSocket.request(.doctor, timeout: 10)
        report(r.ok, "helper responds")
        for line in r.messages ?? [] {
            print(line)
            if line.hasPrefix("FAIL") { failed = true }
        }
    } catch {
        report(false, "helper responds: \(error)")
    }
    exit(failed ? 1 : 0)
}

let args = Array(CommandLine.arguments.dropFirst())
let request: Request
switch (args.first, args.count) {
case ("ping", 1): request = .ping
case ("status", 1): request = .status
case ("refresh", 1): request = .refresh
case ("doctor", 1): doctor()
case ("down", 2): request = .down(name: args[1])
case ("up", 3):
    // The file is read here, by the user; the helper never accepts paths.
    let path = (args[2] as NSString).expandingTildeInPath
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { fail("cannot read \(path)") }
    request = .up(name: args[1], config: text)
default:
    print(usage)
    exit(2)
}

let response: Response
do {
    response = try UnixSocket.request(request, timeout: 30)
} catch {
    fail("cannot reach helper at \(wgbarSocketPath): \(error)")
}

guard response.ok else { fail(response.error ?? "unknown error") }
if let status = response.status, request != .ping {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    enc.dateEncodingStrategy = .iso8601
    print(String(decoding: (try? enc.encode(status)) ?? Data(), as: UTF8.self))
} else {
    print("ok")
}
