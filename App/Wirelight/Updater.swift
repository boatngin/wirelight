import Foundation
import Sparkle

/// Sparkle updates, checked against the appcast on GitHub Releases. Off when the
/// build carries no EdDSA public key (source builds), so nothing unsigned is offered.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    private let controller: SPUStandardUpdaterController?
    @Published var automatic: Bool {
        didSet { controller?.updater.automaticallyChecksForUpdates = automatic }
    }

    var available: Bool { controller != nil }

    private init() {
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        controller = key.isEmpty || TunnelStore.isDemo
            ? nil
            : SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        automatic = controller?.updater.automaticallyChecksForUpdates ?? false
    }

    func checkNow() { controller?.checkForUpdates(nil) }
}
