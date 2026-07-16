import SwiftUI
import AppKit
import UserNotifications

@main
struct PearApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var environment = AppEnvironment.live()

    var body: some Scene {
        MenuBarExtra {
            PanelView()
                .environment(environment)
        } label: {
            if environment.runner.isEnabled {
                Image(nsImage: environment.runner.currentFrame)
                if environment.runner.showsCPU, let pct = environment.runner.cpuPercent {
                    Text("\(pct)%")
                }
            } else {
                Image(nsImage: MenuBarIcon.image(unread: environment.hasUnseenIncoming))
            }
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
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
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
