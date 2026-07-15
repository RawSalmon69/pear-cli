import Foundation
import Observation
import Carbon.HIToolbox

extension Notification.Name {
    /// Posted by the AppDelegate when APNs wakes us; the environment refreshes.
    static let pearRemoteNotification = Notification.Name("pearRemoteNotification")
}

/// Dependency container. `live()` picks the CloudKit backend when a couple key
/// exists and the mock (surfacing `.needsSetup`) otherwise. Services are
/// `@Observable`; views read the specific service they use, so a clipboard
/// tick re-renders only clipboard views, never the whole panel.
@MainActor
@Observable
final class AppEnvironment {
    let messaging: MessagingService
    let stats: PearStatsService
    let updater: UpdaterService?
    let screenshot: ScreenshotService
    let ocr: OCRService
    let clipboard: ClipboardHistoryService
    @ObservationIgnored private let clipboardWindow = ClipboardWindowController()

    init(messaging: MessagingService, stats: PearStatsService, updater: UpdaterService?) {
        self.messaging = messaging
        self.stats = stats
        self.updater = updater
        self.screenshot = ScreenshotService(messaging: messaging)
        self.ocr = OCRService()
        self.clipboard = ClipboardHistoryService()
        self.screenshot.registerHotKey()
        self.ocr.registerHotKey()
        self.clipboard.start()
        HotKeyManager.shared.register(keyCode: kVK_ANSI_C, modifiers: controlKey | shiftKey) {
            [weak self] in
            guard let self else { return }
            self.clipboardWindow.toggle(env: self)
        }
        self.screenshot.onMarkupRequest = { image, done in
            MarkupWindow.present(image: image, onComplete: done)
        }

        NotificationCenter.default
            .addObserver(forName: .pearRemoteNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.messaging.refresh() }
            }
    }

    var hasUnseenIncoming: Bool {
        messaging.messages.contains {
            $0.senderDevice != CoupleKey.deviceRole && $0.seenAt == nil
        }
    }

    static func live() -> AppEnvironment {
        let stats = PearStatsService()
        // Sparkle only works from a bundled .app (not `swift run`); guard so
        // dev runs don't crash trying to start it.
        let updater = Bundle.main.bundleIdentifier != nil ? UpdaterService() : nil
        if let key = CoupleKey.load() {
            let service = CloudKitMessagingService(key: key, deviceRole: CoupleKey.deviceRole)
            return AppEnvironment(messaging: service, stats: stats, updater: updater)
        }
        // No key yet: mock backend, setup card in the panel.
        let mock = MockMessagingService(connectionState: .needsSetup)
        return AppEnvironment(messaging: mock, stats: stats, updater: updater)
    }
}
