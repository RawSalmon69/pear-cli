import Foundation

/// Screen capture seam shared by the screenshot, QR and OCR tools. Runs the
/// (blocking) `screencapture` off the main thread. Returns true only if a file
/// was written — the user hitting Escape on a region drag writes nothing.
/// `muted: false` lets macOS play its native camera-shutter sound.
///
/// Every capture starts by getting Pear's own floating UI off the screen (see
/// `pearHideForCapture`). Doing it here rather than in each tool means a capture
/// triggered from a panel tile, a hotkey, or anything added later all behave the
/// same: the panel is not sitting over the region you are trying to grab, and
/// not in the shot.
enum ScreenCapture {
    /// Interactive region drag (`-i`).
    static func region(to url: URL, muted: Bool = true) async -> Bool {
        await run(muted ? ["-i", "-x", url.path] : ["-i", url.path], writing: url)
    }

    /// The whole main display, instantly — no `-i`, so no selection UI.
    /// ponytail: main display only; per-display capture needs one path each.
    static func fullScreen(to url: URL, muted: Bool = true) async -> Bool {
        // The only mode that captures without waiting for the user, so it is the
        // only one that has to wait for the window server to actually take Pear's
        // panels off the screen. The interactive modes get that for free: the
        // crosshair is up long before anyone finishes a drag.
        await run(muted ? ["-x", url.path] : [url.path], writing: url,
                  settleForRemovedWindows: .milliseconds(160))
    }

    /// Click a window (`-w` locks interaction to window mode, no drag): the
    /// window is captured cropped, with its shadow. Escape writes nothing.
    static func window(to url: URL, muted: Bool = true) async -> Bool {
        await run(muted ? ["-i", "-w", "-x", url.path] : ["-i", "-w", url.path], writing: url)
    }

    /// Runs the real `/usr/sbin/screencapture` and blocks until it exits. Split
    /// out so the ordering test can substitute a launcher that grabs nothing —
    /// calling the real one from a test would screenshot the developer's display.
    typealias Launcher = @Sendable ([String]) -> Void

    static let screencapture: Launcher = { arguments in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = arguments
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            NSLog("Pear: screencapture failed: \(error.localizedDescription)")
        }
    }

    /// Internal, not private, for the ordering test: "the panel is off the screen
    /// before the capture starts" is the whole point and is easy to regress.
    static func run(_ arguments: [String], writing url: URL,
                    settleForRemovedWindows settle: Duration = .zero,
                    launch: @escaping Launcher = ScreenCapture.screencapture) async -> Bool {
        // Synchronous and on the main thread, so the panels are gone before
        // `screencapture` is launched below.
        await MainActor.run {
            NotificationCenter.default.post(name: .pearHideForCapture, object: nil)
        }
        if settle > .zero { try? await Task.sleep(for: settle) }
        defer {
            Task { @MainActor in
                NotificationCenter.default.post(name: .pearRestoreAfterCapture, object: nil)
            }
        }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                launch(arguments)
                continuation.resume(returning: FileManager.default.fileExists(atPath: url.path))
            }
        }
    }
}
