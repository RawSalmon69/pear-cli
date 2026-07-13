import SwiftUI

@main
struct PearApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var environment = AppEnvironment.live()

    var body: some Scene {
        MenuBarExtra {
            PanelView()
                .environmentObject(environment)
        } label: {
            // Placeholder glyph; the real pear template icon lands in the design pass.
            Image(systemName: "leaf.fill")
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Push registration and CloudKit subscription setup attach here later.
    }
}
