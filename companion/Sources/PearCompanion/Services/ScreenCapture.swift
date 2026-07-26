import Foundation

/// Screen capture seam shared by the screenshot and OCR tools. Runs the
/// (blocking) `screencapture` off the main thread. Returns true only if a file
/// was written — the user hitting Escape on a region drag writes nothing.
/// `muted: false` lets macOS play its native camera-shutter sound.
enum ScreenCapture {
    /// Interactive region drag (`-i`).
    static func region(to url: URL, muted: Bool = true) async -> Bool {
        await run(muted ? ["-i", "-x", url.path] : ["-i", url.path], writing: url)
    }

    /// The whole main display, instantly — no `-i`, so no selection UI.
    /// ponytail: main display only; per-display capture needs one path each.
    static func fullScreen(to url: URL, muted: Bool = true) async -> Bool {
        await run(muted ? ["-x", url.path] : [url.path], writing: url)
    }

    private static func run(_ arguments: [String], writing url: URL) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                process.arguments = arguments
                do {
                    try process.run()
                    process.waitUntilExit()
                } catch {
                    NSLog("Pear: screencapture failed: \(error.localizedDescription)")
                }
                continuation.resume(returning: FileManager.default.fileExists(atPath: url.path))
            }
        }
    }
}
