import AppKit
import ApplicationServices
import CoreGraphics

/// A privacy permission Pear can be missing. Plain values, so `PanelProblem`
/// can name one without any system call.
enum Permission {
    case screenRecording, accessibility

    /// The System Settings pane. The legacy `com.apple.preference.security`
    /// anchors still resolve on macOS 14 through 26: the Privacy & Security
    /// extension declares that legacy bundle id and both anchors.
    var settingsURL: URL {
        switch self {
        case .screenRecording:
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        case .accessibility:
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        }
    }

    var paneName: String {
        switch self {
        case .screenRecording: "Screen Recording"
        case .accessibility: "Accessibility"
        }
    }
}

enum PermissionStatus {
    case granted, missing
    /// Screen Recording before any capture has shown whether it works.
    case unconfirmed
}

/// The one place Pear makes the permission system calls: Screen Recording
/// preflight and request, the Accessibility trust check and prompt, and the two
/// settings panes. System calls only, so untested; every decision about what to
/// show lives in `PanelProblem`. Nothing here runs at launch: the checks are
/// read when the panel opens or a tool is used, and the request / prompt calls
/// only when the user acts.
@MainActor
enum Permissions {
    /// No prompt; safe to read on every panel open.
    static var accessibilityTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system Accessibility prompt, which also lists Pear in the pane.
    /// The string key: `kAXTrustedCheckOptionPrompt` is a non-Sendable global in
    /// Swift 6.
    static func requestAccessibility() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    /// A capture wrote nothing while preflight said no. Captures never wait on
    /// preflight; this only records the failure afterwards.
    private static var captureDenied = false

    /// `ScreenCapture.run` calls this when a capture wrote no file; true when
    /// that was the missing grant rather than a cancel.
    @discardableResult
    static func captureWroteNothing() -> Bool {
        let denied = ScreenCapture.deniedByPermission(
            wroteFile: false, granted: CGPreflightScreenCaptureAccess())
        if denied { captureDenied = true }
        return denied
    }

    /// Read once per panel open: a recorded failure clears as soon as preflight
    /// passes, so the warning is gone the next time the panel opens.
    static func screenRecordingMissing() -> Bool {
        if captureDenied, CGPreflightScreenCaptureAccess() { captureDenied = false }
        return captureDenied
    }

    /// A tool page's permission row. Read-only, never a prompt. Screen Recording
    /// is "granted" only when preflight says so; a no is shown as "missing" only
    /// once a capture failed for it, since preflight can stay false after a grant
    /// until Pear relaunches (captures are attempted first, never gated on it).
    static func status(of permission: Permission) -> PermissionStatus {
        switch permission {
        case .accessibility:
            accessibilityTrusted ? .granted : .missing
        case .screenRecording:
            CGPreflightScreenCaptureAccess() ? .granted : captureDenied ? .missing : .unconfirmed
        }
    }

    /// The Fix action: the system request first, which puts Pear in the pane's
    /// list (and shows the system's own prompt the first time only), then the pane.
    static func fix(_ permission: Permission) {
        switch permission {
        case .screenRecording: _ = CGRequestScreenCaptureAccess()
        case .accessibility: requestAccessibility()
        }
        NSWorkspace.shared.open(permission.settingsURL)
    }
}
