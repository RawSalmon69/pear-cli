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
        // Notes whether the HD model is on disk, for the settings UI. It is NOT
        // loaded here: compiled, it is ~160 MB resident for a feature most
        // sessions never touch, so the first cutout loads it (`prepared()`).
        HDBackgroundModelManager.shared.prepare()
        // Unsaved captures are kept for a week, then dropped. Launch-time only:
        // preview cards are in-memory, so nothing from a previous run is still
        // in use. `sweepStaleTempFiles` clears the temp-dir backlog builds
        // ≤ 2.14.1 left behind, before captures moved into the store.
        Task.detached(priority: .background) {
            CaptureStore.sweep()
            _ = ScreenshotService.sweepStaleTempFiles()
        }
        // The weekly refund check. Background priority and off the launch path
        // because it makes a network request, and gated on the paywall flag so
        // the app reaches the network for this only once the feature is real and
        // the privacy policy lists it. Fail-open throughout: a 404 or a dead
        // domain cannot touch anyone's entitlement.
        if FeatureFlags.paywall {
            let entitlement = environment.entitlement
            Task(priority: .background) { await entitlement.checkRevocationIfDue() }
        }
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

    // Open the URL a QR notification carries — from the "Open Link" button or
    // a plain tap on the banner. Non-QR notifications carry no URL key.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let urlString = info[QRService.urlUserInfoKey] as? String,
              let url = URL(string: urlString) else { return }
        guard response.actionIdentifier == QRService.openActionIdentifier
            || response.actionIdentifier == UNNotificationDefaultActionIdentifier else { return }
        _ = await MainActor.run { NSWorkspace.shared.open(url) }
    }
}
