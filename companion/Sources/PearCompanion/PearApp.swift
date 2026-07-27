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
        runSettingsMigrations()
        // If High-quality mode is on AND the model is already downloaded, compile
        // it now so the first cutout is instant; no-op (and no download)
        // otherwise. Gated on the pref: compiling and holding a 205 MB Core ML
        // model resident at every launch for a feature the user turned off is
        // pure footprint. Flipping the toggle on calls `prepare()` itself.
        if Prefs.hdBackgroundRemoval {
            HDBackgroundModelManager.shared.prepare()
        }
        // Unsaved captures are kept for a week, then dropped. Launch-time only:
        // preview cards are in-memory, so nothing from a previous run is still
        // in use. `sweepStaleTempFiles` clears the temp-dir backlog builds
        // ≤ 2.14.1 left behind, before captures moved into the store.
        Task.detached(priority: .background) {
            CaptureStore.sweep()
            _ = ScreenshotService.sweepStaleTempFiles()
        }
        UNUserNotificationCenter.current().delegate = self
        // Quitting must not orphan a live `pear clean` — least of all the
        // privileged `--system` variant, which would keep sweeping system caches
        // with no window, no transcript and nothing left to stop it.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [environment] _ in
            // `queue: .main` guarantees this body runs on the main thread, so the
            // hop is an assertion rather than a real isolation change — and it
            // must be synchronous: a `Task` would not outlive the quit.
            MainActor.assumeIsolated { environment.cleaner.runner.terminateForQuit() }
        }
        panelController = PanelController(env: environment)
        // Best-effort: unsigned dev builds have no push entitlement and land in
        // didFailToRegister — that's fine, the foreground poll covers delivery.
        if FeatureFlags.coupleNote {
            NSApplication.shared.registerForRemoteNotifications()
        }
    }

    /// One-time settings migrations, each gated by its own ran-once flag so it
    /// fires exactly once and never fights a later user change.
    private func runSettingsMigrations() {
        let defaults = UserDefaults.standard
        // Reset the Dock-preview placement to Auto (follow Dock) for everyone
        // once: some users were left on a stale value whose preview ignored the
        // Dock edge. Auto is the default, so this only touches changed installs;
        // they can re-pick a manual anchor afterward.
        let placementAutoFlag = "migration.dockdoorPlacementAuto.v1"
        if !defaults.bool(forKey: placementAutoFlag) {
            defaults.set(DockPreviewPlacement.auto.rawValue, forKey: DockDoorSettings.Key.previewPlacement)
            defaults.set(true, forKey: placementAutoFlag)
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
