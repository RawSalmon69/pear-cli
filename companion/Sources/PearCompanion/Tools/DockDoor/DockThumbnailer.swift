// Adapted from DockDoor (GPL-3.0), https://github.com/ejbills/DockDoor,
// commit 78b0862f — original: DockDoor/Utilities/Window Management/WindowUtil.swift
// (captureWindowImage / shouldCaptureWindowImages) and
// Components/PermissionsView/PermissionsChecker.swift.
//
// DockDoor's one-shot thumbnail path uses the PRIVATE CGS API
// CGSHWCaptureWindowList; this port uses the PUBLIC SCScreenshotManager
// (macOS 14+) instead — zero private-API surface — and matches AX windows to
// SCK windows by frame rather than the private _AXUIElementGetWindow. The
// screen-recording preflight (CGPreflightScreenCaptureAccess, passive, never
// prompts) mirrors PermissionsChecker.

import CoreGraphics
import ScreenCaptureKit

/// A window to capture, addressed by value so it can cross into the (off-main)
/// capture task. `index` maps the resulting image back to the caller's
/// `DockWindow`; `frame` is in AX space (top-left, global points) — the same
/// space SCK reports window frames in — so matching is a direct comparison.
struct DockCaptureTarget: Sendable {
    let index: Int
    let frame: CGRect
}

enum DockThumbnailer {
    /// Whether Screen Recording is granted, checked passively — this never
    /// prompts. SCK's own lazy TCC prompt still fires on the first real capture
    /// if the permission is newly needed; we never call the active
    /// CGRequestScreenCaptureAccess ourselves.
    static var canCapture: Bool { CGPreflightScreenCaptureAccess() }

    /// Capture a static thumbnail per target via the public SCScreenshotManager.
    /// Nonisolated + async: SCK runs off the main thread and the non-Sendable
    /// SCWindow objects never leave this function — only the Sendable
    /// `[index: CGImage]` map crosses back. Best-effort: a target with no
    /// matching on-screen SCK window (minimized, off-space, capture failure) is
    /// simply absent from the result and the tile keeps its app-icon fallback.
    ///
    /// ponytail: static one-shot captures refreshed on each hover are the v1
    /// slice. The live-video upgrade path is one SCStream per window
    /// (SCContentFilter(desktopIndependentWindow:) + an SCStreamOutput delegate),
    /// matching DockDoor's LiveWindowCapture — deferred to keep v1 at one
    /// AXObserver with no persistent streams.
    static func capture(
        app: DockApp,
        targets: [DockCaptureTarget],
        maxDimension: CGFloat
    ) async -> [Int: CGImage] {
        guard canCapture, !targets.isEmpty else { return [:] }
        guard let content = try? await SCShareableContent.excludingDesktopWindows(
            true, onScreenWindowsOnly: true
        ) else {
            return [:]
        }

        let appWindows = content.windows.filter { $0.owningApplication?.processID == app.pid }
        guard !appWindows.isEmpty else { return [:] }

        var claimed = Set<CGWindowID>()
        var images: [Int: CGImage] = [:]
        for target in targets {
            guard let scWindow = bestMatch(for: target, in: appWindows, excluding: claimed) else { continue }
            claimed.insert(scWindow.windowID)
            if let image = try? await captureImage(of: scWindow, maxDimension: maxDimension) {
                images[target.index] = image
            }
        }
        return images
    }

    /// A match farther than this (L1 corner+size points) is no match at all.
    /// Without a ceiling, "closest unclaimed" always returns SOMETHING — a
    /// zero-frame (minimized/off-Space) target would claim a real window's
    /// capture and show it on the wrong tile. Generous enough to absorb the
    /// small AX↔SCK frame drift of a live window mid-move.
    static let maxMatchDistance: CGFloat = 300

    /// L1 corner + size distance between an AX target frame and an SCK window
    /// frame — both in top-left global points, so an exact match scores ~0.
    /// Pure, so the ceiling policy is unit-testable without SCK.
    static func matchDistance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        abs(a.minX - b.minX) + abs(a.minY - b.minY)
            + abs(a.width - b.width) + abs(a.height - b.height)
    }

    /// The unclaimed SCK window whose frame is closest to the target's, or nil
    /// when even the closest is farther than `maxMatchDistance`.
    private static func bestMatch(
        for target: DockCaptureTarget,
        in windows: [SCWindow],
        excluding claimed: Set<CGWindowID>
    ) -> SCWindow? {
        var best: SCWindow?
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for window in windows where !claimed.contains(window.windowID) {
            let distance = matchDistance(target.frame, window.frame)
            if distance < bestDistance {
                bestDistance = distance
                best = window
            }
        }
        return bestDistance <= maxMatchDistance ? best : nil
    }

    private static func captureImage(of window: SCWindow, maxDimension: CGFloat) async throws -> CGImage {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        let longestEdge = max(window.frame.width, window.frame.height, 1)
        let scale = min(1, maxDimension / longestEdge)
        // 2× the fit size for crispness on Retina; SCK downsamples for us.
        config.width = max(1, Int(window.frame.width * scale * 2))
        config.height = max(1, Int(window.frame.height * scale * 2))
        config.showsCursor = false
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }
}
