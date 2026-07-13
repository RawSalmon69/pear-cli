import AppKit

/// Runs a pear CLI command in Terminal so its own confirmations and safety
/// UX stay intact. Headless clean is deliberately v2.
enum TerminalRunner {
    static func run(_ command: String) {
        guard PearStatsService.pearBinary() != nil else { return }
        let script = """
        tell application "Terminal"
            activate
            do script "pear \(command)"
        end tell
        """
        Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            try? process.run()
        }
    }
}
