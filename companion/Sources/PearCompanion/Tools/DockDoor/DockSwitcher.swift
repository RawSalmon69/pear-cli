// Adapted from DockDoor (GPL-3.0), https://github.com/ejbills/DockDoor,
// commit 78b0862f — original: DockDoor/Utilities/KeybindHelper.swift and
// Views/Hover Window/WindowPreview Supporting/PreviewStateCoordinator.swift
// (cycleForward / cycleBackward / navigateWindowSwitcher).
//
// DockDoor drives its switcher from one always-on CGEvent tap that watches
// keyDown/keyUp/flagsChanged and swallows the Tab keystrokes. This port does NOT
// hold a permanent tap. Following this codebase's own key-interception rules:
//   • ⌥-tab / ⌥-⇧-tab are Carbon hotkeys (Services/HotKeyManager). Carbon
//     already CONSUMES the matched chord, so Tab never leaks to the frontmost
//     app — no tap is needed to swallow Tab. Each press opens the switcher (if
//     closed) or cycles the selection (if open).
//   • a session-scoped NSEvent flagsChanged monitor commits the selection when
//     ⌥ is released (DockDoor's flagsChanged modifier-release path).
//   • Escape cancels through a session-scoped KeySwallowTap (the same
//     create-on-open / invalidate-on-close pattern RadialTrigger uses),
//     degrading to a read-only monitor if the tap can't be created.
// Idle cost while enabled is exactly the two Carbon hotkeys — zero monitors,
// zero taps until ⌥-tab is pressed. Accessibility-gated like the hover path:
// `trigger` no-ops until Pear is trusted (the global monitors are silent
// without it anyway).

import AppKit
import Carbon.HIToolbox

/// Pure cycle math for the switcher, unit-tested without a live session.
enum DockSwitcherCycle {
    /// The index selected the instant the switcher opens: the *next* window
    /// forward, or the *last* backward — classic ⌥-tab behavior where the very
    /// first press already moves off the frontmost window.
    static func openIndex(count: Int, backward: Bool) -> Int {
        guard count > 0 else { return -1 }
        if backward { return count - 1 }
        return count > 1 ? 1 : 0
    }

    /// Advance the selection while the switcher stays open, wrapping around.
    static func advance(from current: Int, count: Int, backward: Bool) -> Int {
        guard count > 0 else { return -1 }
        let delta = backward ? -1 : 1
        return (current + delta + count) % count
    }
}

/// Owns the ⌥-tab window switcher: the always-on Carbon hotkeys and, only while
/// a switch is in progress, the overlay panel plus its release/cancel monitors.
@MainActor
final class DockSwitcher {
    private let panel = DockSwitcherPanel()

    private var forwardToken: HotKeyManager.Token?
    private var backwardToken: HotKeyManager.Token?

    /// State for one in-progress switch. Reference type so handlers mutate in
    /// place; snapshotted at open, so a window quitting mid-switch just no-ops.
    private final class Session {
        let entries: [DockSwitcherEntry]
        var index: Int
        init(entries: [DockSwitcherEntry], index: Int) {
            self.entries = entries
            self.index = index
        }
    }

    private var session: Session?
    /// Session-only NSEvent flagsChanged monitors (commit on ⌥ release).
    private var flagsMonitors: [Any] = []
    /// Session-only Escape swallow tap; nil ⇒ running on the read-only fallback.
    private var keyTap: KeySwallowTap?
    private var escMonitors: [Any] = []
    private var watchdog: Task<Void, Never>?

    // MARK: - Lifecycle (called by DockDoorTool)

    /// Register the hotkeys if the switcher setting is on. Idempotent.
    func start() {
        if DockDoorSettings.switcherEnabled() { registerHotkeys() }
    }

    /// Full teardown: close any open switch and drop the hotkeys.
    func stop() {
        teardownSession()
        unregisterHotkeys()
    }

    /// Live on/off from the settings toggle.
    func setEnabled(_ enabled: Bool) {
        if enabled {
            registerHotkeys()
        } else {
            teardownSession()
            unregisterHotkeys()
        }
    }

    // MARK: - Hotkeys

    private func registerHotkeys() {
        guard forwardToken == nil else { return }
        forwardToken = HotKeyManager.shared.register(keyCode: kVK_Tab, modifiers: optionKey) { [weak self] in
            self?.trigger(backward: false)
        }
        backwardToken = HotKeyManager.shared.register(keyCode: kVK_Tab, modifiers: optionKey | shiftKey) { [weak self] in
            self?.trigger(backward: true)
        }
    }

    private func unregisterHotkeys() {
        if let forwardToken { HotKeyManager.shared.unregister(forwardToken) }
        if let backwardToken { HotKeyManager.shared.unregister(backwardToken) }
        forwardToken = nil
        backwardToken = nil
    }

    // MARK: - Trigger

    /// A ⌥-tab (or ⌥-⇧-tab) press: open the switcher or advance the selection.
    private func trigger(backward: Bool) {
        guard AXIsProcessTrusted() else { return } // accessibility-gated
        if session == nil {
            open(backward: backward)
        } else {
            advance(backward: backward)
        }
    }

    private func open(backward: Bool) {
        let entries = DockWindows.switcherEntries(scope: DockDoorSettings.switcherScope())
        guard !entries.isEmpty else { return }

        let index = DockSwitcherCycle.openIndex(count: entries.count, backward: backward)
        session = Session(entries: entries, index: index)

        let maxDimension = DockDoorSettings.previewSize().maxDimension
        panel.show(entries: entries, selected: index, maxDimension: maxDimension)

        installSessionMonitors()
        startWatchdog()
    }

    private func advance(backward: Bool) {
        guard let session else { return }
        session.index = DockSwitcherCycle.advance(
            from: session.index, count: session.entries.count, backward: backward
        )
        panel.updateSelection(session.index)
    }

    // MARK: - Commit / cancel

    /// ⌥ released → raise the selected window's app.
    private func commit() {
        guard let session else { return }
        let entry = session.entries.indices.contains(session.index) ? session.entries[session.index] : nil
        teardownSession()
        if let entry { entry.window.raise(app: entry.app) }
    }

    /// Escape → close without raising anything.
    private func cancel() {
        teardownSession()
    }

    private func teardownSession() {
        for monitor in flagsMonitors { NSEvent.removeMonitor(monitor) }
        flagsMonitors = []
        for monitor in escMonitors { NSEvent.removeMonitor(monitor) }
        escMonitors = []
        keyTap?.invalidate()
        keyTap = nil
        watchdog?.cancel()
        watchdog = nil
        panel.hide()
        session = nil
    }

    // MARK: - Session monitors (only while switching — 0% idle cost)

    private func installSessionMonitors() {
        // Commit when the summoning modifier is released.
        let mask: NSEvent.EventTypeMask = .flagsChanged
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.flagsChanged(event)
        }) {
            flagsMonitors.append(monitor)
        }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.flagsChanged(event)
            return event
        }) {
            flagsMonitors.append(monitor)
        }

        // Escape cancels. Prefer a session-scoped tap that swallows only Escape
        // (Tab is Carbon's to consume); fall back to read-only monitors.
        keyTap = KeySwallowTap { [weak self] event in
            self?.handleKeyDown(event) ?? false
        }
        if keyTap == nil {
            if let monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
                _ = self?.handleKeyDown(event)
            }) {
                escMonitors.append(monitor)
            }
            if let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
                (self?.handleKeyDown(event) ?? false) ? nil : event
            }) {
                escMonitors.append(monitor)
            }
        }
    }

    private func flagsChanged(_ event: NSEvent) {
        guard session != nil, !event.modifierFlags.contains(.option) else { return }
        commit()
    }

    /// Returns true when the key was handled (and should be swallowed): only
    /// Escape. Tab is consumed by the Carbon hotkey, never reaching here.
    private func handleKeyDown(_ event: NSEvent) -> Bool {
        guard session != nil, Int(event.keyCode) == kVK_Escape else { return false }
        cancel()
        return true
    }

    /// Global monitors go silent during secure input, so a release can be
    /// missed. Poll the live modifier state and commit if ⌥ is provably up
    /// (RadialTrigger solves the same wedge the same way).
    private func startWatchdog() {
        watchdog = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(300))
                guard let self, self.session != nil else { return }
                if !NSEvent.modifierFlags.contains(.option) {
                    self.commit()
                    return
                }
            }
        }
    }
}
