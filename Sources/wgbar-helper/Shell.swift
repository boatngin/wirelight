import Foundation
import os

let logger = Logger(subsystem: "com.thanaboat.wgbar", category: "helper")

/// Logs to os_log and stderr. Never pass key material here.
func log(_ message: String, error: Bool = false) {
    if error { logger.error("\(message, privacy: .public)") } else { logger.info("\(message, privacy: .public)") }
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

/// Binaries the helper may execute, resolved from a fixed allowlist of absolute paths.
enum Tool: String {
    case wireguardGo = "wireguard-go", wg, ifconfig, route, networksetup

    var candidates: [String] {
        switch self {
        case .wireguardGo, .wg: return ["/opt/homebrew/bin/\(rawValue)", "/usr/local/bin/\(rawValue)"]
        case .ifconfig: return ["/sbin/ifconfig"]
        case .route: return ["/sbin/route"]
        case .networksetup: return ["/usr/sbin/networksetup"]
        }
    }
}

struct ShellResult {
    let status: Int32
    let stdout: String
    let stderr: String
    var ok: Bool { status == 0 }
}

enum ShellError: Error, CustomStringConvertible {
    case binaryNotFound(String)
    case failed(tool: String, args: [String], status: Int32, stderr: String)

    var description: String {
        switch self {
        case let .binaryNotFound(t): return "\(t) not found (install with: brew install wireguard-tools wireguard-go)"
        case let .failed(t, a, s, e):
            let msg = e.trimmingCharacters(in: .whitespacesAndNewlines)
            return "\(t) \(a.joined(separator: " ")) exited \(s)\(msg.isEmpty ? "" : ": \(msg)")"
        }
    }
}

private final class DataBox: @unchecked Sendable { var data = Data() }

/// Runs a binary with a fixed argv. There is deliberately no way to run a shell string.
enum Shell {
    static func resolve(_ tool: Tool) throws -> URL {
        for p in tool.candidates where FileManager.default.isExecutableFile(atPath: p) {
            return URL(fileURLWithPath: p)
        }
        throw ShellError.binaryNotFound(tool.rawValue)
    }

    /// - Parameter captureOutput: false for daemonizing tools (wireguard-go), whose
    ///   background child would otherwise keep our pipes open forever.
    @discardableResult
    static func run(_ tool: Tool, _ args: [String], env: [String: String] = [:],
                    captureOutput: Bool = true, check: Bool = true) throws -> ShellResult {
        let p = Process()
        p.executableURL = try resolve(tool)
        p.arguments = args
        p.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"].merging(env) { $1 }
        p.standardInput = FileHandle.nullDevice

        let out = Pipe(), err = Pipe()
        if captureOutput {
            p.standardOutput = out
            p.standardError = err
        } else {
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
        }
        try p.run()

        let outBox = DataBox(), errBox = DataBox()
        if captureOutput {
            let group = DispatchGroup()
            group.enter()
            DispatchQueue.global().async {
                errBox.data = err.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }
            outBox.data = out.fileHandleForReading.readDataToEndOfFile()
            group.wait()
        }
        p.waitUntilExit()

        let result = ShellResult(status: p.terminationStatus,
                                 stdout: String(decoding: outBox.data, as: UTF8.self),
                                 stderr: String(decoding: errBox.data, as: UTF8.self))
        if check && !result.ok {
            throw ShellError.failed(tool: tool.rawValue, args: args, status: result.status, stderr: result.stderr)
        }
        return result
    }
}
