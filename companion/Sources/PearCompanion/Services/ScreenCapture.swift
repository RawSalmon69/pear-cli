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
    /// Interactive region drag (`-i`). `tool` is the id a failure is reported
    /// under (`ToolRegistry.reportError`).
    static func region(to url: URL, muted: Bool = true, tool: String) async -> Bool {
        await run(muted ? ["-i", "-x", url.path] : ["-i", url.path], writing: url, tool: tool)
    }

    /// The whole main display, instantly — no `-i`, so no selection UI.
    /// ponytail: main display only; per-display capture needs one path each.
    static func fullScreen(to url: URL, muted: Bool = true, tool: String) async -> Bool {
        // The only mode that captures without waiting for the user, so it is the
        // only one that has to wait for the window server to actually take Pear's
        // panels off the screen. The interactive modes get that for free: the
        // crosshair is up long before anyone finishes a drag.
        await run(muted ? ["-x", url.path] : [url.path], writing: url, tool: tool,
                  settleForRemovedWindows: .milliseconds(160))
    }

    /// Click a window (`-w` locks interaction to window mode, no drag): the
    /// window is captured cropped, with its shadow. Escape writes nothing.
    static func window(to url: URL, muted: Bool = true, tool: String) async -> Bool {
        await run(muted ? ["-i", "-w", "-x", url.path] : ["-i", "-w", url.path], writing: url,
                  tool: tool)
    }

    /// Runs the real `/usr/sbin/screencapture` and blocks until it exits. Split
    /// out so the ordering test can substitute a launcher that grabs nothing —
    /// calling the real one from a test would screenshot the developer's display.
    /// Returns false when the process could not be started at all.
    typealias Launcher = @Sendable ([String]) -> Bool

    static let screencapture: Launcher = { arguments in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = arguments
        do {
            try process.run()
            process.waitUntilExit()
            return true
        } catch {
            NSLog("Pear: screencapture failed: \(error.localizedDescription)")
            return false
        }
    }

    /// The failures a capture reports under its tool; Esc is not one.
    static let launchFailedMessage = "The system screenshot tool couldn't start"
    static let deniedMessage = "Screen Recording is off, so the capture produced nothing"

    /// One capture at a time, app-wide. A double-tap (or key auto-repeat) used
    /// to launch two `screencapture -i` fighting over one crosshair; and each
    /// screenshot mode, OCR and QR owns its own service, so ⌃⇧S then ⌃⇧W
    /// mid-drag ran two, and the first to finish brought the cards and pins
    /// back over the second. Internal for the refusal test.
    @MainActor static var gate = CaptureGate()

    /// Internal, not private, for the ordering test: "the panel is off the screen
    /// before the capture starts" is the whole point and is easy to regress.
    static func run(_ arguments: [String], writing url: URL, tool: String,
                    settleForRemovedWindows settle: Duration = .zero,
                    launch: @escaping Launcher = ScreenCapture.screencapture,
                    wroteNothing: @escaping @MainActor @Sendable () -> Bool = Permissions.captureWroteNothing,
                    report: @escaping @MainActor @Sendable (String, String) -> Void = {
                        ToolRegistry.live?.reportError($0, for: $1)
                    })
        async -> Bool {
        // Synchronous and on the main thread, so the panels are gone before
        // `screencapture` is launched below. A capture already in flight
        // refuses this one, silently, like a cancelled drag.
        let began = await MainActor.run {
            guard gate.begin() else { return false }
            NotificationCenter.default.post(name: .pearHideForCapture, object: nil)
            return true
        }
        guard began else { return false }
        if settle > .zero { try? await Task.sleep(for: settle) }
        let (launched, wrote) = await withCheckedContinuation {
            (continuation: CheckedContinuation<(Bool, Bool), Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let launched = launch(arguments)
                continuation.resume(returning: (launched, FileManager.default.fileExists(atPath: url.path)))
            }
        }
        await MainActor.run {
            gate.end()
            NotificationCenter.default.post(name: .pearRestoreAfterCapture, object: nil)
        }
        // Only a capture that wrote nothing asks about permission, so a good
        // capture reaches its preview without the extra hop. A plain Esc is not
        // an error and reports nothing.
        if !wrote {
            await MainActor.run {
                if !launched {
                    report(launchFailedMessage, tool)
                } else if wroteNothing() {
                    report(deniedMessage, tool)
                }
            }
        }
        return wrote
    }

    /// Captures never wait on a preflight: Pear attempts the capture, and only
    /// a capture that wrote nothing while preflight says no is a permission
    /// problem. Esc with the permission granted writes nothing too, and stays
    /// silent. `granted` is read only when no file was written.
    static func deniedByPermission(wroteFile: Bool, granted: @autoclosure () -> Bool) -> Bool {
        !wroteFile && !granted()
    }
}

/// "Is a capture already running?" as a plain value, so the rule is testable
/// without launching `screencapture`. A refused `begin` must not be paired with
/// an `end`; `ScreenCapture.run` only ends what it began.
struct CaptureGate {
    private var busy = false

    mutating func begin() -> Bool {
        guard !busy else { return false }
        busy = true
        return true
    }

    mutating func end() { busy = false }
}
