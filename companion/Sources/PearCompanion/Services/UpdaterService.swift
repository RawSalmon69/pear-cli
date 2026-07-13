import Foundation
import Sparkle

/// Thin wrapper over Sparkle. Feed URL comes from SUFeedURL in Info.plist.
/// Enables silent scheduled checks so the app updates itself without the
/// first-run permission prompt (awkward for a menu-bar-only app).
@MainActor
final class UpdaterService: ObservableObject {
    private let controller: SPUStandardUpdaterController

    @Published private(set) var canCheck = false

    init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        let updater = controller.updater
        updater.automaticallyChecksForUpdates = true
        updater.updateCheckInterval = 3600 // hourly
        canCheck = updater.canCheckForUpdates
    }

    /// Manual "Check for Updates…" — shows Sparkle's UI (up-to-date or found).
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    var versionString: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }
}
