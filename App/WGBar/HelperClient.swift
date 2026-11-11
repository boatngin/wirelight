import Foundation
import WGCore

/// Async wrapper over the blocking Unix-socket client in WGCore.
enum HelperClient {
    static func send(_ request: Request, timeout: Int = 3) async throws -> Response {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                do { cont.resume(returning: try UnixSocket.request(request, timeout: timeout)) }
                catch { cont.resume(throwing: error) }
            }
        }
    }
}
