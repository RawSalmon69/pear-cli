import Foundation
import Combine

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

    private var cancellables = Set<AnyCancellable>()

    init(messaging: MessagingService, stats: StatsService, updater: UpdaterService?) {
        self.messaging = messaging
        self.stats = stats
        self.updater = updater
        self.screenshot = ScreenshotService(messaging: messaging)
        self.screenshot.registerHotKey()

        // Re-publish the messaging service's changes so views observing the
        // environment update. The main-queue hop lets the service's own value
        // settle first (objectWillChange fires before the change).
        messaging.changes
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)

        NotificationCenter.default
            .addObserver(forName: .pearRemoteNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.messaging.refresh() }
            }
    }

    static func live() -> AppEnvironment {
        let stats = MockStatsService()
        if let key = CoupleKey.load() {
            let service = CloudKitMessagingService(key: key, deviceRole: CoupleKey.deviceRole)
            return AppEnvironment(messaging: service, stats: stats, updater: nil)
        }
        // No key yet: mock backend, setup card in the panel.
        let mock = MockMessagingService(connectionState: .needsSetup)
        return AppEnvironment(messaging: mock, stats: stats, updater: nil)
    }
}
