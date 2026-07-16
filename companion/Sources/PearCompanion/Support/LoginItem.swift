import Foundation
import ServiceManagement

/// Launch-at-login, backed by `SMAppService.mainApp` (macOS 13+). The service's
/// own status is the source of truth — there's no separate persisted flag to
/// drift. Opt-in: nothing registers until the user flips the Settings toggle.
@MainActor
enum LoginItem {
    /// True when the app is registered to open at login.
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// Register or unregister the app as a login item. A no-op under `swift
    /// test` so the suite never mutates the real login-item database.
    static func setEnabled(_ enabled: Bool) {
        guard !isRunningTests else { return }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("Pear: login item \(enabled ? "register" : "unregister") failed: \(error.localizedDescription)")
        }
    }

    private static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
}
