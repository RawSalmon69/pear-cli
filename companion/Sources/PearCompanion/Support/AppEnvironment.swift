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
    /// Feeds the panel greeting's health line and mascot mood. What is left of
    /// the native samplers after the Monitor tool was removed in 2.26.1.
    let stats: PearStatsService
    /// Per-tool usage tally; see `UsageAnalytics` for what it does and does not
    /// record.
    let usage: UsageAnalytics
    let updater: UpdaterService?
    let tools: ToolRegistry
    /// Trial / licence state. Read by the settings pane and the locked state, and
    /// consulted by `tools` before it registers anything paid.
    let entitlement = EntitlementStore()
    /// Menu-bar runner (RunCat-style). The menu-bar label observes
    /// `runner.currentFrame` directly; off by default, 0% cost when off.
    let runner = RunnerModel()

    init(
        messaging: MessagingService, stats: PearStatsService, usage: UsageAnalytics,
        updater: UpdaterService?
    ) {
        self.messaging = messaging
        self.stats = stats
        self.usage = usage
        self.updater = updater

        // Adding a tool to the app is one registration here.
        let tools = ToolRegistry()
        tools.usage = usage
        // The paywall, in one line: a locked app registers no paid tool, so no
        // hotkey is claimed and no engine starts. Set before the first `offer`,
        // because `offer` is what consults it.
        let entitlement = self.entitlement
        tools.isLocked = {
            FeatureFlags.paywall && !entitlement.entitlement.unlocksTools
        }
        tools.offer(ScreenshotTool(messaging: messaging))
        tools.offer(ScreenshotTool(mode: .fullScreen, messaging: messaging))
        tools.offer(ScreenshotTool(mode: .window, messaging: messaging))
        tools.offer(OCRTool())
        tools.offer(QRTool())
        tools.offer(BackgroundRemoverTool())
        tools.offer(ClipboardTool())
        tools.offer(DiskTool())
        tools.offer(ShelfTool())
        tools.offer(ScratchpadTool())
        tools.offer(ColorPickerTool())
        tools.offer(WindowsTool())
        tools.offer(MenuBarTool())
        tools.offer(SwitchesTool())
        tools.offer(CleanModeTool())
        tools.offer(KeyCluTool())
        tools.offer(HighlightCopyTool())
        tools.offer(PanelTool())
        // A licence entered mid-session must bring the tools back without a
        // relaunch: `isLocked` is read live, but only re-registration restores
        // hotkeys and restarts engines.
        entitlement.onChange = { [weak tools] in tools?.reregister() }
        self.tools = tools

        runner.start() // no-op unless the user enabled it

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
        // Sparkle only works from a bundled .app (not `swift run`); guard so
        // dev runs don't crash trying to start it.
        let stats = PearStatsService()
        let usage = UsageAnalytics.live()
        let updater = Bundle.main.bundleIdentifier != nil ? UpdaterService() : nil
        // Couple-note hidden: inert mock, CloudKit never constructed.
        guard FeatureFlags.coupleNote else {
            let mock = MockMessagingService(connectionState: .online)
            return AppEnvironment(messaging: mock, stats: stats, usage: usage, updater: updater)
        }
        if let key = CoupleKey.load() {
            let service = CloudKitMessagingService(key: key, deviceRole: CoupleKey.deviceRole)
            return AppEnvironment(messaging: service, stats: stats, usage: usage, updater: updater)
        }
        // No key yet: mock backend, setup card in the panel.
        let mock = MockMessagingService(connectionState: .needsSetup)
        return AppEnvironment(messaging: mock, stats: stats, usage: usage, updater: updater)
    }
}
