import AppKit
import Observation
import SwiftUI

extension Notification.Name {
    /// Posted by the `panel` pseudo-tool's global hotkey; the controller toggles
    /// the panel. Decouples the tool (registered inside the environment) from
    /// the controller (created later by the AppDelegate), so neither needs a
    /// reference to the other.
    static let pearTogglePanel = Notification.Name("pearTogglePanel")
}

/// Owns the menu-bar status item and the companion panel, replacing the old
/// `MenuBarExtra(.window)`. The point of the rewrite: a `MenuBarExtra` window
/// always dismisses on outside click, and no API disables that. A manual
/// non-activating `NSPanel` (the pattern the shelf and scratchpad already use)
/// stays open until you explicitly close it — status-item click, Esc, or the
/// ⌃⇧P hotkey.
///
/// The status item is always visible (`NSStatusItem.variableLength`, no length
/// tricks — the 2.1.0 lesson). Its button image is driven straight off the
/// `@Observable` runner via `withObservationTracking`, so a frame swap is one
/// `button.image =` assignment instead of a whole SwiftUI label re-render, and
/// there is no timer at rest.
@MainActor
final class PanelController: NSObject {
    private let env: AppEnvironment
    private let statusItem: NSStatusItem
    private var panel: NSPanel?
    private var host: PanelHostingView<AnyView>?
    /// The content size the panel was last sized to. A re-fit whose content
    /// size is unchanged is a no-op — this is what breaks the layout→setFrame→
    /// relayout loop that tripped AppKit's per-cycle update-constraints limit
    /// (owner crash on color pick, 2.5.x). The panel's width is fixed, so
    /// `fittingSize` depends only on content, never on the window frame we set.
    private var lastFittedSize: NSSize = .zero

    /// The user dragged the panel, so a later content re-fit must keep their
    /// position instead of snapping back under the menu-bar item. Reset on each
    /// open, so a freshly toggled panel always returns to hang under the item.
    private var userMoved = false
    /// The origin we last set programmatically. `windowDidMove` compares against
    /// it (with a 1 pt tolerance for sub-point frame rounding) to tell our own
    /// fit-driven moves apart from a real user drag.
    private var lastProgrammaticOrigin: NSPoint = .zero

    /// Persists the status item's bar position across launches. Without it the
    /// item is a fresh identity every launch, and macOS drops fresh items at
    /// the far LEFT of the status area — which, on a bar running the menu-bar
    /// hider, is inside the hidden zone: the icon silently vanished after the
    /// 2.4.0 rewrite (the 2.1.0 incident's shape, new entry point).
    private static let autosaveName = "com.pear.companion.statusitem"

    init(env: AppEnvironment) {
        self.env = env

        // First run of this identity: seed the preferred position near the
        // right edge (the value is the offset from the right) so the item
        // spawns beside the clock — to the right of any hider separator —
        // instead of leftmost. The user's own ⌘-drag then owns it via autosave.
        let positionKey = "NSStatusItem Preferred Position \(Self.autosaveName)"
        if UserDefaults.standard.object(forKey: positionKey) == nil {
            UserDefaults.standard.set(60, forKey: positionKey)
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = Self.autosaveName
        super.init()

        // Always visible — no length-hiding. The menu-bar hider tool manages its
        // own separate items; this one must never disappear.
        statusItem.isVisible = true
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp])
        }

        NotificationCenter.default.addObserver(
            forName: .pearTogglePanel, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.toggle() }
        }

        trackButton()
    }

    // MARK: - Status-item button

    /// Renders the button, then re-arms itself the moment any observed value
    /// changes. `withObservationTracking` fires `onChange` once per change on the
    /// mutating (main) actor; re-arming on the next turn re-reads the fresh
    /// values and re-registers the tracked set. Timer-free, no polling.
    private func trackButton() {
        withObservationTracking {
            renderButton()
        } onChange: { [weak self] in
            Task { @MainActor in self?.trackButton() }
        }
    }

    /// Mirrors the old `MenuBarExtra` label exactly: runner frame (+ optional
    /// CPU%) when the runner is on, else the pear glyph with an unread badge.
    private func renderButton() {
        guard let button = statusItem.button else { return }
        let runner = env.runner
        if runner.isEnabled {
            button.image = runner.currentFrame
            if runner.showsCPU, let pct = runner.cpuPercent {
                button.title = " \(pct)%"
                button.imagePosition = .imageLeft
            } else {
                button.title = ""
                button.imagePosition = .imageOnly
            }
        } else {
            button.image = MenuBarIcon.image(unread: env.hasUnseenIncoming)
            button.title = ""
            button.imagePosition = .imageOnly
        }
    }

    // MARK: - Panel

    @objc private func statusItemClicked() {
        toggle()
    }

    func toggle() {
        if panel == nil { show() } else { hide() }
    }

    /// Tears down the panel (and its hosting view) so the SwiftUI `.task`/timer
    /// stop and idle cost returns to ~0% — the recreate-per-open contract the
    /// panel's refresh logic assumed under `MenuBarExtra`.
    func hide() {
        panel?.orderOut(nil)
        panel = nil
        host = nil
        lastFittedSize = .zero
        userMoved = false
    }

    private func show() {
        // Standalone the view needs its own glass, or it renders transparent
        // over the desktop — the window chrome that `MenuBarExtra` used to
        // supply. (Same fix the standalone clipboard picker makes.)
        let root = PanelView()
            .environment(env)
            .glassCard(cornerRadius: 16)
            // The panel hangs from the menu bar, so on a notched Mac its safe-
            // area insets change every time it's repositioned. Left in, that
            // fed a constraint-invalidation loop: reposition → insets recompute
            // → hosting view re-marks the window for update → reposition …
            // Ignoring the safe area breaks that arm of the loop.
            .ignoresSafeArea()
        let host = PanelHostingView(rootView: AnyView(root))
        host.clipToCard(radius: 16)
        // Deferred one runloop turn: `layout()` is inside AppKit's constraint
        // pass, and calling `setFrame` from there re-enters the layout engine —
        // an exception AppKit escalates to a crash. The accent color well's
        // continuous drag (a re-render per tick) made this reliably fatal.
        // `fitPanelToContent` is idempotent and frame-guarded, so coalescing
        // several queued fits is harmless.
        host.onLayout = { [weak self] in
            Task { @MainActor in self?.fitPanelToContent() }
        }

        let panel = PearPanel(
            contentRect: NSRect(origin: .zero, size: NSSize(width: 392, height: 240)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar // floats above windows; hangs below the menu bar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        // Drag by any empty background area. Interactive SwiftUI controls
        // (tiles, buttons, the note field) report `mouseDownCanMoveWindow=false`,
        // so a press on them still interacts — same one-liner the scratchpad and
        // cleaner windows use with editable content.
        panel.isMovableByWindowBackground = true
        panel.onCancel = { [weak self] in self?.hide() }
        // Delegate drives the close-on-focus-loss toggle and drag detection.
        panel.delegate = self
        panel.contentView = host

        self.host = host
        self.panel = panel
        userMoved = false

        host.layoutSubtreeIfNeeded()
        fitPanelToContent()
        panel.makeKeyAndOrderFront(nil)
    }

    /// Sizes the panel to its SwiftUI content and anchors it just under the
    /// status item, clamped on-screen. Re-runs from the hosting view's `layout()`
    /// so the async stats fill-in (or a battery row appearing) never clips.
    private func fitPanelToContent() {
        guard let panel, let host,
              let buttonWindow = statusItem.button?.window else { return }
        let raw = host.fittingSize
        let size = NSSize(width: raw.width.rounded(), height: raw.height.rounded())
        guard size.width > 1, size.height > 1 else { return }
        // The loop-breaker: an unchanged content size does nothing. Rounded so
        // sub-point jitter can't retrigger a resize. Width is fixed, so this
        // size never depends on the frame we're about to set — the fit
        // converges in a single pass instead of feeding itself.
        guard size != lastFittedSize else { return }
        lastFittedSize = size
        let screen = buttonWindow.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? buttonWindow.frame
        var origin: NSPoint
        if userMoved {
            // Keep the user's top-left corner; only grow/shrink downward so a
            // late content change (a note arrives, the battery row appears)
            // doesn't yank the panel back under the menu bar.
            origin = NSPoint(x: panel.frame.minX, y: panel.frame.maxY - size.height)
        } else {
            origin = NSPoint(
                x: buttonWindow.frame.midX - size.width / 2,
                y: buttonWindow.frame.minY - size.height
            )
        }
        origin.x = min(max(visible.minX + 8, origin.x), visible.maxX - size.width - 8)
        origin.y = Self.clampedVerticalOrigin(desiredY: origin.y, height: size.height, visible: visible)
        let frame = NSRect(origin: origin, size: size)
        // Guarded so the setFrame → layout() → fit loop terminates.
        lastProgrammaticOrigin = frame.origin
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }

    /// Vertical origin (bottom-left, AppKit coords) for a panel of `height`
    /// whose desired position is `desiredY`, clamped so neither the top nor the
    /// bottom leaves `visible`. The top clamp comes first so a menu-bar-anchored
    /// panel whose top would sit above the visible area (greeting clipped
    /// off-screen) is pulled down; the bottom clamp then wins if the panel is
    /// taller than the visible height. Pure, so it's testable without AppKit.
    static func clampedVerticalOrigin(desiredY: CGFloat, height: CGFloat, visible: NSRect) -> CGFloat {
        max(visible.minY + 8, min(desiredY, visible.maxY - height))
    }

    /// Whether a resign-key should close the panel. Pure so the guard — never
    /// close while our own Settings/Help popover or the folder-picker sheet owns
    /// focus, and never if the panel took key back — is testable without AppKit.
    static func shouldAutoClose(
        prefEnabled: Bool,
        hasChildWindows: Bool,
        hasAttachedSheet: Bool,
        panelIsKey: Bool
    ) -> Bool {
        guard prefEnabled else { return false }
        return !(hasChildWindows || hasAttachedSheet || panelIsKey)
    }
}

extension PanelController: NSWindowDelegate {
    /// Close on focus loss when the user opted in (the default). Deferred one
    /// turn because opening our own Settings/Help popover — or the folder
    /// picker — resigns the panel's key status to a child window; re-checking
    /// next turn lets a self-owned popover keep the panel up.
    func windowDidResignKey(_ notification: Notification) {
        Task { @MainActor [weak self] in
            guard let self, let panel = self.panel else { return }
            let close = Self.shouldAutoClose(
                prefEnabled: Prefs.panelClosesOnFocusLoss,
                hasChildWindows: !(panel.childWindows?.isEmpty ?? true),
                hasAttachedSheet: panel.attachedSheet != nil,
                panelIsKey: panel.isKeyWindow
            )
            if close { self.hide() }
        }
    }

    /// A move whose origin differs from the one we last set (beyond sub-point
    /// rounding) is a user drag — remember it so the next fit keeps the position.
    func windowDidMove(_ notification: Notification) {
        guard let panel else { return }
        let origin = panel.frame.origin
        if abs(origin.x - lastProgrammaticOrigin.x) > 1
            || abs(origin.y - lastProgrammaticOrigin.y) > 1 {
            userMoved = true
        }
    }
}

/// Borderless, non-activating panel that stays open on focus loss — the whole
/// point — and closes only on Esc (routed to `onCancel`), the status-item click,
/// or the ⌃⇧P hotkey. Can become key so buttons and any text field respond;
/// first clicks land via `PanelHostingView.acceptsFirstMouse`.
private final class PearPanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // One dismissal grammar across every floating surface: Esc closes.
    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

/// Delivers the first click even when the panel isn't key, so a tile fires on
/// the first press instead of only promoting the panel to key (adapted from
/// Dropshit, MIT — the same trick the shelf/clipboard panels use). Also reports
/// SwiftUI content layout back so the controller keeps the panel sized to fit.
private final class PanelHostingView<Content: View>: NSHostingView<Content> {
    var onLayout: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        onLayout?()
    }
}
