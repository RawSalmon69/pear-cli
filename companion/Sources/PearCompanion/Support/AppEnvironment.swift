import Foundation
import Combine
import Carbon.HIToolbox

extension Notification.Name {
    /// Posted by the AppDelegate when APNs wakes us; the environment refreshes.
    static let pearRemoteNotification = Notification.Name("pearRemoteNotification")
}

/// Dependency container. `live()` picks the CloudKit backend when a couple key
/// exists and the mock (surfacing `.needsSetup`) otherwise. The messaging
/// protocol stays the only swap-in seam.
@MainActor
final class AppEnvironment: ObservableObject {
    let messaging: MessagingService
    let stats: StatsService
    let updater: UpdaterService?
    let screenshot: ScreenshotService
    let ocr: OCRService
    let clipboard: ClipboardHistoryService
    private let clipboardWindow = ClipboardWindowController()

    private var cancellables = Set<AnyCancellable>()

    init(messaging: MessagingService, stats: StatsService, updater: UpdaterService?) {
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

        clipboard.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)

        // Re-publish the messaging service's changes so views observing the
        // environment update. The main-queue hop lets the service's own value
        // settle first (objectWillChange fires before the change).
        messaging.changes
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)

        if let observableStats = stats as? PearStatsService {
            observableStats.objectWillChange
                .receive(on: DispatchQueue.main)
                .sink { [weak self] in self?.objectWillChange.send() }
                .store(in: &cancellables)
        }

        NotificationCenter.default
            .addObserver(forName: .pearRemoteNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.messaging.refresh() }
            }
    }

    // Panel conveniences derived from the concrete services.

    var diskUsedFraction: Double? {
        (stats as? PearStatsService)?.diskUsedFraction
    }

    var statsCLIMissing: Bool {
        (stats as? PearStatsService)?.cliMissing ?? false
    }

    var uptime: String? { (stats as? PearStatsService)?.uptime }
    var healthScore: Int? { (stats as? PearStatsService)?.healthScore }
    var healthMessage: String? { (stats as? PearStatsService)?.healthMessage }

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
