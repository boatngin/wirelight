import Foundation
import SwiftUI

/// One probe: round-trip time (nil when every ping was lost) and loss in percent.
struct QualitySample: Identifiable, Equatable {
    let date: Date
    let rtt: Double?
    let loss: Double
    var id: Date { date }
}

enum QualityGrade: String {
    case good = "Good", fair = "Fair", poor = "Poor", unknown = "Measuring"

    var color: Color {
        switch self {
        case .good: return .green
        case .fair: return .orange
        case .poor: return .red
        case .unknown: return .secondary
        }
    }
}

/// Summary of the recent samples for one tunnel.
struct QualitySummary {
    let grade: QualityGrade
    let median: Double?
    let p95: Double?
    let loss: Double

    init(_ samples: [QualitySample], settings: QualitySettings) {
        // The last 10 probes decide the grade so it reacts within a few minutes.
        let recent = samples.suffix(10)
        let rtts = recent.compactMap(\.rtt).sorted()
        loss = recent.isEmpty ? 0 : recent.map(\.loss).reduce(0, +) / Double(recent.count)
        median = rtts.isEmpty ? nil : rtts[rtts.count / 2]
        p95 = rtts.isEmpty ? nil : rtts[min(rtts.count - 1, Int(Double(rtts.count) * 0.95))]
        if recent.count < 2 { grade = .unknown }
        else if median == nil || loss >= settings.poorLoss || (median ?? 0) >= settings.poorMs { grade = .poor }
        else if loss >= settings.fairLoss || (median ?? 0) >= settings.fairMs { grade = .fair }
        else { grade = .good }
    }
}

/// User choices for link quality probes. Off by default: probes cost a little traffic.
struct QualitySettings: Codable, Equatable {
    enum Target: String, Codable, CaseIterable { case server, custom }
    var enabled = false
    var target = Target.server
    /// Host pinged through the tunnel when `target == .custom`.
    var customHost = ""
    var interval: Int = 10
    var historyHours: Int = 1
    var fairMs: Double = 60
    var poorMs: Double = 150
    var fairLoss: Double = 1
    var poorLoss: Double = 3

    static let key = "qualitySettings"

    static func load() -> QualitySettings {
        guard let d = UserDefaults.standard.data(forKey: key),
              let s = try? JSONDecoder().decode(QualitySettings.self, from: d) else { return QualitySettings() }
        return s
    }

    func save() { UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: Self.key) }

    /// Rough cost so people know what they turn on: 3 pings of 64 bytes each way per probe.
    var bytesPerHourPerTunnel: Int { 3 * 2 * 84 * 3600 / max(interval, 1) }
    var samplesKept: Int { historyHours * 3600 / max(interval, 1) }
}

/// Runs `/sbin/ping` for each connected tunnel on a timer. No root needed.
enum Pinger {
    static func probe(_ host: String) async -> QualitySample {
        await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/sbin/ping")
                p.arguments = ["-c", "3", "-i", "0.2", "-t", "3", "-q", host]
                let out = Pipe()
                p.standardOutput = out
                p.standardError = Pipe()
                do { try p.run() } catch {
                    cont.resume(returning: QualitySample(date: Date(), rtt: nil, loss: 100)); return
                }
                let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                p.waitUntilExit()
                cont.resume(returning: parse(text))
            }
        }
    }

    /// Reads "x% packet loss" and "min/avg/max/stddev = a/b/c/d ms".
    static func parse(_ text: String, now: Date = Date()) -> QualitySample {
        var loss = 100.0, rtt: Double?
        for line in text.split(separator: "\n") {
            if line.contains("packet loss"),
               let part = line.split(separator: ",").first(where: { $0.contains("packet loss") }),
               let n = Double(part.trimmingCharacters(in: .whitespaces).split(separator: "%").first ?? "") {
                loss = n
            }
            if line.contains("min/avg/max"), let nums = line.split(separator: "=").last?.split(separator: "/"),
               nums.count >= 2 {
                rtt = Double(nums[1].trimmingCharacters(in: .whitespaces))
            }
        }
        return QualitySample(date: now, rtt: rtt, loss: loss)
    }
}

/// Counts bytes of one HTTPS download and stops at a size or time limit.
final class SpeedProbe: NSObject, URLSessionDataDelegate {
    struct Result { var bytes = 0; var seconds = 0.0; var error: String? }
    private var result = Result()
    private let start = Date()
    private let limitBytes: Int
    private let limitSeconds: Double
    private var done: CheckedContinuation<Result, Never>?

    private init(limitBytes: Int, limitSeconds: Double) {
        self.limitBytes = limitBytes; self.limitSeconds = limitSeconds
    }

    static func run(_ url: URL, limitBytes: Int, limitSeconds: Double) async -> Result {
        let probe = SpeedProbe(limitBytes: limitBytes, limitSeconds: limitSeconds)
        let session = URLSession(configuration: .ephemeral, delegate: probe, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return await withCheckedContinuation { cont in
            probe.done = cont
            session.dataTask(with: url).resume()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code != 200 { result.error = "server answered \(code)" }
        completionHandler(code == 200 ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        result.bytes += data.count
        if result.bytes >= limitBytes || Date().timeIntervalSince(start) >= limitSeconds { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        result.seconds = Date().timeIntervalSince(start)
        if let e = error as? URLError, e.code != .cancelled, result.error == nil { result.error = e.localizedDescription }
        done?.resume(returning: result)
        done = nil
    }
}
