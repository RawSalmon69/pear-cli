import SwiftUI
import AppKit
import UserNotifications

@main
struct PearApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Menu-bar-only (LSUIElement): no visible scene. The status item and the
        // companion panel are driven imperatively by the AppDelegate's
        // PanelController — a MenuBarExtra window can't stay open on focus loss.
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private let environment = AppEnvironment.live()
    private var panelController: PanelController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        panelController = PanelController(env: environment)
        // Best-effort: unsigned dev builds have no push entitlement and land in
        // didFailToRegister — that's fine, the foreground poll covers delivery.
        if FeatureFlags.coupleNote {
            NSApplication.shared.registerForRemoteNotifications()
        }
    }

    func application(_ application: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]) {
        // Silent CloudKit push: refresh the pipe (which posts local
        // notifications for anything new incoming).
        NotificationCenter.default.post(name: .pearRemoteNotification, object: nil)
    }

    func application(_ application: NSApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {}

    func application(_ application: NSApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        NSLog("Pear: remote notifications unavailable: \(error.localizedDescription)")
    }

    // Show our local notifications even while the app is foreground.
    // `nonisolated`: unlike NSApplicationDelegate, UNUserNotificationCenterDelegate
    // isn't main-actor-isolated in the SDK, so a @MainActor impl can't receive its
    // non-Sendable params. This body touches no isolated state, so it's safe off-actor.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
