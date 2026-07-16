import Foundation
import Observation

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
    let tools: ToolRegistry
    /// Native clean/optimize progress panel (no Terminal window).
    @ObservationIgnored let cleaner = CleanerWindowController()

    init(messaging: MessagingService, stats: PearStatsService, updater: UpdaterService?) {
        self.messaging = messaging
        self.stats = stats
        self.updater = updater

        // Adding a tool to the app is one registration here.
        let tools = ToolRegistry()
        tools.offer(ScreenshotTool(messaging: messaging))
        tools.offer(OCRTool())
        tools.offer(ClipboardTool())
        tools.offer(DiskTool())
        tools.offer(ShelfTool())
        tools.offer(ScratchpadTool())
        tools.offer(ColorPickerTool())
        tools.offer(MonitorTool())
        tools.offer(WindowsTool())
        tools.offer(MenuBarTool())
        self.tools = tools

        if FeatureFlags.coupleNote {
            NotificationCenter.default
                .addObserver(forName: .pearRemoteNotification, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor in await self?.messaging.refresh() }
                }
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
        // Couple-note hidden: inert mock, CloudKit never constructed.
        guard FeatureFlags.coupleNote else {
            let mock = MockMessagingService(connectionState: .online)
            return AppEnvironment(messaging: mock, stats: stats, updater: updater)
        }
        if let key = CoupleKey.load() {
            let service = CloudKitMessagingService(key: key, deviceRole: CoupleKey.deviceRole)
            return AppEnvironment(messaging: service, stats: stats, updater: updater)
        }
        // No key yet: mock backend, setup card in the panel.
        let mock = MockMessagingService(connectionState: .needsSetup)
        return AppEnvironment(messaging: mock, stats: stats, updater: updater)
    }
}
