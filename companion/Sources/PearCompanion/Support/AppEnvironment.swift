import Foundation

/// Dependency container. `live()` wires mocks until the real services land;
/// swap-in points stay here only.
@MainActor
final class AppEnvironment: ObservableObject {
    let messaging: MessagingService
    let stats: StatsService
    let updater: UpdaterService?

    init(messaging: MessagingService, stats: StatsService, updater: UpdaterService?) {
        self.messaging = messaging
        self.stats = stats
        self.updater = updater
    }

    static func live() -> AppEnvironment {
        AppEnvironment(
            messaging: MockMessagingService(),
            stats: MockStatsService(),
            updater: nil // Sparkle needs a bundled app; enabled by build.sh builds.
        )
    }
}
