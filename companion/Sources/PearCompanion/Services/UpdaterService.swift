import Foundation
import Sparkle

/// Thin wrapper over Sparkle. Feed URL comes from SUFeedURL in Info.plist.
@MainActor
final class UpdaterService {
    private let controller: SPUStandardUpdaterController

    init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    var versionString: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }
}
