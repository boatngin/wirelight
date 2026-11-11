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
"""

let args = Array(CommandLine.arguments.dropFirst())
let request: Request
switch (args.first, args.count) {
case ("ping", 1): request = .ping
case ("status", 1): request = .status
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
