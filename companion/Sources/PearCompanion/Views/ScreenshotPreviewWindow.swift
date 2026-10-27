import SwiftUI
import AppKit
import QuartzCore

/// Pure layout math for the preview stack, factored out so positions and the
/// eviction policy are unit-testable. Index 0 is the newest card, sitting
/// nearest the bottom-right corner; higher indices stack upward.
enum PreviewStackLayout {
    static func origin(index: Int, panelSize: NSSize, in visible: NSRect,
                       margin: CGFloat, gap: CGFloat) -> NSPoint {
        NSPoint(
            x: visible.maxX - panelSize.width - margin,
            y: visible.minY + margin + CGFloat(index) * (panelSize.height + gap)
        )
    }

    /// Off-screen just past the right edge, at the card's current row, so a
    /// slide-in / fling-off travels horizontally toward the nearest edge.
    static func offscreenOrigin(for home: NSPoint, panelSize: NSSize, in visible: NSRect) -> NSPoint {
        NSPoint(x: visible.maxX + panelSize.width, y: home.y)
    }

    /// Indices to evict when keeping only the `maxCount` newest cards.
    static func overflowIndices(count: Int, maxCount: Int) -> [Int] {
        guard count > maxCount else { return [] }
        return Array(maxCount..<count)
    }

    /// The overflow cards to evict, minus the `protected` ones (a card whose
    /// detail window is open), so the stack can run over its limit rather than
    /// close a window the user is reading.
    static func evictionVictims(count: Int, maxFit: Int, protected: Set<Int>) -> [Int] {
        overflowIndices(count: count, maxCount: maxFit).filter { !protected.contains($0) }
    }

    /// Whether a card times out: never while its detail window is open (the
    /// user is reading it), nor while VoiceOver is on, which cannot hover the
    /// card to hold it.
    static func autoDismisses(enabled: Bool, detailOpen: Bool, voiceOver: Bool) -> Bool {
        enabled && !detailOpen && !voiceOver
    }
}

/// What the detail window needs from the card that spawned it: the backing
/// file, the insights, and the very same action closures, so copy / save /
/// reveal / send have one implementation across both views.
@MainActor
private struct DetailContext {
    let url: URL
    let insights: ScreenshotInsights
    let canMarkup: Bool
    let canSend: Bool
    let canSave: Bool
    let canRemoveBackground: Bool
    let onCopy: () -> Void
    let onCopyText: ((String) -> Void)?
    let onQRTap: (([String]) -> Void)?
    let onSave: () -> Bool
    let onReveal: () -> Void
    let onMarkup: () -> Void
    let onRemoveBackground: () -> Void
    let onSend: () -> Void
}

/// One preview: its non-activating panel plus per-card timer / gesture state,
/// its insights, and the detail window it opens (created on first click).
@MainActor
private final class PreviewEntry {
    let id: UUID
    let panel: NSPanel
    /// The card's backing file. It is the card's whole state — the thumbnail is
    /// decoded from it once and every action re-reads it — so a card whose file
    /// has gone can do nothing and is dismissed (`dismissCards(backedBy:)`).
    let url: URL
    let detailContext: DetailContext
    var detail: ScreenshotDetailWindowController?
    var timer: Timer?
    /// The scratchpad's tested swipe primitive: horizontal-dominance, momentum
    /// suppression and one emission per physical gesture. A bare running total
    /// fired repeatedly through a single fling and never reset on a mouse wheel.
    var swipe = SwipeAccumulator()
    /// Pointer over the card, which holds its auto-dismiss.
    var hovering = false

    init(id: UUID, panel: NSPanel, url: URL, detailContext: DetailContext) {
        self.id = id
        self.panel = panel
        self.url = url
        self.detailContext = detailContext
    }
}

/// Floating post-capture previews: thumbnail cards that stack near the
/// bottom-right corner. New captures slide in and shift the others up; each
/// card persists until swiped away (or an optional auto-dismiss fires), and
/// swiping flings it off-screen while the rest close the gap.
///
/// One NSPanel per card (see the array below): under Swift 6 an array of small
/// panels is simpler and safer than one panel re-laying-out a hosted stack —
/// each card animates its own frame, and teardown is a per-panel orderOut with
/// no shared re-layout state to leak.
@MainActor
final class ScreenshotPreviewController {
    static let shared = ScreenshotPreviewController()

    private init() {
        observeCaptures()
        observeFocusedScreen()
        observeScreenChanges()
        observeVoiceOver()
    }

    private var entries: [PreviewEntry] = [] // index 0 = newest, nearest edge
    private var scrollMonitor: Any?
    /// Display the stack lives on — the screen the capture came from when the
    /// first card appears (see `show`), and thereafter the screen holding the
    /// focused window (see `followFocusedScreen`), so the cards are on the
    /// display the user is working on rather than the one they have left.
    /// Kept as an id, not a frame: `visibleFrame` changes whenever the Dock or
    /// menu bar moves, resizes or auto-hides, and a stored frame then matched
    /// no screen and threw the stack onto the primary display.
    private var anchorDisplay: CGDirectDisplayID?

    private var anchorScreen: NSScreen? {
        anchorDisplay.flatMap { id in NSScreen.screens.first { $0.displayID == id } }
    }

    /// The anchor display's live visible frame, read at layout time. Zero when
    /// the display has gone, which layout treats as "nowhere to put cards"
    /// until the screen-parameter change re-resolves the anchor.
    private var anchorVisible: NSRect { anchorScreen?.visibleFrame ?? .zero }

    /// Thumbnail (208×130) plus the card's glass rim on each side.
    private static let panelSize = NSSize(width: 208 + 2 * Theme.Space.xSmall,
                                          height: 130 + 2 * Theme.Space.xSmall)
    private static let margin: CGFloat = 20
    private static let gap: CGFloat = 12

    /// Shows a card for the capture at `url`. The card holds the URL and a
    /// thumbnail, never the capture's bytes: ten 6K shots left on screen used to
    /// pin 30–200 MB resident for as long as the user ignored them.
    func show(
        url: URL,
        canMarkup: Bool,
        canSend: Bool = FeatureFlags.coupleNote,
        canSave: Bool = false,
        canRemoveBackground: Bool = true,
        onCopy: @escaping () -> Void,
        onCopyText: ((String) -> Void)? = nil,
        onQRTap: (([String]) -> Void)? = nil,
        onReveal: @escaping () -> Void,
        onMarkup: @escaping () -> Void,
        onRemoveBackground: @escaping () -> Void = {},
        onSend: @escaping () -> Void,
        onSave: @escaping () -> Bool = { false },
        capturedOn screen: NSScreen? = nil
    ) {
        // The header alone says whether this is an image at all; the card
        // decodes its thumbnail off the main actor once it is up.
        let insights = ScreenshotInsights(url: url)
        guard insights.details.pixelWidth > 0 else { return }

        let id = UUID()
        // The actions that replace the card take it away with them, from the
        // card and from its detail window alike: Markup / background removal
        // re-present a fresh card, so a card left behind is a stale duplicate.
        let markup: () -> Void = { [weak self] in
            onMarkup()
            self?.dismiss(id: id)
        }
        let removeBackground: () -> Void = { [weak self] in
            onRemoveBackground()
            self?.dismiss(id: id)
        }
        let send: () -> Void = { [weak self] in
            onSend()
            self?.dismiss(id: id)
        }
        let content = ScreenshotPreviewView(
            url: url,
            canMarkup: canMarkup,
            canSend: canSend,
            canSave: canSave,
            canRemoveBackground: canRemoveBackground,
            insights: insights,
            onCopy: onCopy,
            onCopyText: onCopyText,
            onQRTap: onQRTap,
            onOpen: { [weak self] in self?.openDetail(id: id) },
            onPin: { [weak self] in self?.pin(id: id) },
            onSave: onSave,
            onReveal: onReveal,
            onMarkup: markup,
            onRemoveBackground: removeBackground,
            onSend: send,
            onDismiss: { [weak self] in self?.dismiss(id: id) },
            onHoverChange: { [weak self] hovering in self?.hoverChange(id: id, hovering: hovering) }
        )

        let panel = NonActivatingPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        let host = PreviewHostingView(rootView: content)
        host.clipToCard(radius: Theme.Radius.medium)
        panel.contentView = host

        let entry = PreviewEntry(
            id: id,
            panel: panel,
            url: url,
            detailContext: DetailContext(
                url: url,
                insights: insights,
                canMarkup: canMarkup,
                canSend: canSend,
                canSave: canSave,
                canRemoveBackground: canRemoveBackground,
                onCopy: onCopy,
                onCopyText: onCopyText,
                onQRTap: onQRTap,
                onSave: onSave,
                onReveal: onReveal,
                onMarkup: markup,
                onRemoveBackground: removeBackground,
                onSend: send
            )
        )
        // Fix the anchor screen when a fresh stack starts; existing stacks keep
        // theirs so the cards stay put rather than teleporting mid-stack. A
        // fresh stack with no capture screen (Recent strip, a re-presented
        // edit) opens on the focused screen: an emptied stack's display is
        // stale, however long ago it emptied.
        if entries.isEmpty {
            anchorDisplay = resolvedAnchor(capturedOn: screen, focused: NSScreen.main)
        }
        entries.insert(entry, at: 0)
        evictOverflow()
        layout(newItem: entry)
        installScrollMonitor()
        scheduleAutoDismiss(entry)
        // Card is on screen: only now start reading it, so OCR / barcode /
        // palette work can never delay the capture → preview hop.
        insights.scan()
    }

    // MARK: Pin

    /// Pins the card's capture to the screen. The card stays; the pin reads the
    /// file once and outlives it. A failed read drops the card, like any other.
    private func pin(id: UUID) {
        guard let entry = entries.first(where: { $0.id == id }) else { return }
        // The screen of whatever was clicked: the card, or its detail window.
        let screen = NSApp.keyWindow?.screen ?? entry.panel.screen
        if !PinController.pin(url: entry.url, on: screen) {
            SoundEffects.play(.discard)
            dismiss(id: id)
        }
    }

    // MARK: Detail window

    /// Opens the big view for a card, or refocuses the one already open. The
    /// card stays put and stops auto-dismissing while its window is up.
    /// Markup / background-removal there close the window and run the card's own
    /// closure, which dismisses the card and re-presents a fresh one for the
    /// edited image.
    private func openDetail(id: UUID) {
        guard let entry = entries.first(where: { $0.id == id }) else { return }
        entry.timer?.invalidate()
        entry.timer = nil
        if let detail = entry.detail {
            detail.show()
            return
        }
        let context = entry.detailContext
        guard let image = NSImage(contentsOf: context.url) else {
            // The file went away under the card; every action it offers would
            // fail, so say so and drop it rather than open an empty window.
            SoundEffects.play(.discard)
            dismiss(id: id)
            return
        }
        let close = { [weak entry] in entry?.detail?.close() }
        let content = ScreenshotDetailView(
            image: image,
            insights: context.insights,
            canMarkup: context.canMarkup,
            canSend: context.canSend,
            canSave: context.canSave,
            canRemoveBackground: context.canRemoveBackground,
            onCopy: context.onCopy,
            onCopyText: context.onCopyText,
            onQRTap: context.onQRTap,
            onPin: { [weak self] in self?.pin(id: id) },
            onSave: context.onSave,
            onReveal: context.onReveal,
            onMarkup: { close(); context.onMarkup() },
            onRemoveBackground: { close(); context.onRemoveBackground() },
            onSend: { close(); context.onSend() }
        )
        let details = context.insights.details
        let pixelSize = NSSize(width: details.pixelWidth, height: details.pixelHeight)
        let controller = ScreenshotDetailWindowController(
            content: content,
            imageSize: pixelSize.width > 0 ? pixelSize : image.size,
            // The stack's display: focusing the window there leaves the stack
            // put. Not `panel.screen`, which a card opened in the same turn
            // reads from its off-screen slide-in start frame.
            screen: anchorScreen
        )
        controller.onClosed = { [weak self, weak entry] in
            guard let entry else { return }
            entry.detail = nil
            // Re-arm auto-dismiss (if enabled) once the big view is gone.
            self?.scheduleAutoDismiss(entry)
            // A card spared from eviction while this window was open may sit
            // past the fit, off the top of the screen; with auto-dismiss off
            // nothing else would ever take it. Next turn, never inline: this
            // runs inside `close()`, which eviction itself calls mid-loop.
            Task { @MainActor [weak self] in
                self?.evictOverflow(sparingOpenDetails: true)
                self?.layout(newItem: nil)
            }
        }
        entry.detail = controller
        controller.show()
    }

    /// Opens the detail window of the newest card backed by `url`. False when
    /// no card is.
    @discardableResult
    func openDetail(backedBy url: URL) -> Bool {
        guard let entry = entries.first(where: { $0.url == url }) else { return false }
        openDetail(id: entry.id)
        return true
    }

    /// Display the stack anchors to: the screen the shot was taken on, so the
    /// card appears where the user was just looking instead of flying to
    /// another display.
    private func resolvedAnchor(capturedOn screen: NSScreen?,
                                focused: NSScreen? = nil) -> CGDirectDisplayID? {
        Self.anchor(
            captured: screen?.displayID,
            focused: focused?.displayID,
            current: anchorDisplay,
            available: NSScreen.screens.compactMap(\.displayID),
            fallback: NSScreen.screens.first?.displayID
        )
    }

    /// The anchor decision, on display ids so every branch is testable without
    /// a display attached. The first of `captured`, `focused`, `current` that is
    /// still plugged in (in `available`) wins.
    ///
    /// - `captured` is the screen the shot came from. A screen unplugged between
    ///   the capture and the card is no longer in `available`, so it is dropped.
    /// - `focused` is the focused window's screen, when following focus.
    /// - `current` alone means "keep where you are": a screen-parameter change.
    ///   A card added to a non-empty stack never re-resolves at all.
    /// - `fallback` is the menu-bar display, deliberately not `NSScreen.main`:
    ///   main follows the key window, so it drifts to whatever app is focused,
    ///   which is the unpredictability this anchor exists to avoid.
    static func anchor(
        captured: CGDirectDisplayID?, focused: CGDirectDisplayID? = nil,
        current: CGDirectDisplayID?, available: [CGDirectDisplayID],
        fallback: CGDirectDisplayID?
    ) -> CGDirectDisplayID? {
        for id in [captured, focused, current] {
            if let id, available.contains(id) { return id }
        }
        return fallback
    }

    /// How many stacked cards fit in `visible` before the top one runs off the
    /// screen — the cap on a short or scaled display, so cards never climb under
    /// the menu bar or off the top. At least one; unbounded if the frame is
    /// unset (defensive — the stack-size preference then governs).
    private static func maxCardsThatFit(in visible: NSRect) -> Int {
        guard visible.height > 0 else { return .max }
        let usable = visible.height - 2 * margin
        return max(1, Int((usable + gap) / (panelSize.height + gap)))
    }

    // MARK: Layout

    private func homeFrame(index: Int, in visible: NSRect) -> NSRect {
        NSRect(
            origin: PreviewStackLayout.origin(index: index, panelSize: Self.panelSize,
                                              in: visible, margin: Self.margin, gap: Self.gap),
            size: Self.panelSize
        )
    }

    /// Re-seats every card to its stack slot. A `newItem` starts off-screen and
    /// slides in; the rest animate to close or open the gap.
    private func layout(newItem: PreviewEntry?) {
        let visible = anchorVisible
        guard visible.width > 0 else { return }
        for (idx, entry) in entries.enumerated() {
            let home = homeFrame(index: idx, in: visible)
            if entry === newItem {
                let off = NSRect(
                    origin: PreviewStackLayout.offscreenOrigin(for: home.origin,
                                                               panelSize: Self.panelSize, in: visible),
                    size: Self.panelSize
                )
                entry.panel.setFrame(off, display: false)
                entry.panel.alphaValue = 0
                entry.panel.orderFrontRegardless()
                animate(0.32) {
                    entry.panel.animator().setFrame(home, display: true)
                    entry.panel.animator().alphaValue = 1
                }
            } else {
                animate(0.28) {
                    entry.panel.animator().setFrame(home, display: true)
                    entry.panel.animator().alphaValue = 1
                }
            }
        }
    }

    // MARK: Dismissal

    /// Swipe / close-button / timer dismiss: fling the card off the right edge
    /// with a fade, then remove it and let the survivors close the gap.
    private func dismiss(id: UUID) {
        guard let entry = entries.first(where: { $0.id == id }) else { return }
        entry.timer?.invalidate()
        entry.timer = nil
        let visible = anchorVisible
        guard visible.width > 0 else { remove(entry); return }
        let off = NSRect(
            x: visible.maxX + Self.panelSize.width,
            y: entry.panel.frame.minY,
            width: Self.panelSize.width,
            height: Self.panelSize.height
        )
        animate(0.26, {
            entry.panel.animator().setFrame(off, display: true)
            entry.panel.animator().alphaValue = 0
        }, completion: { [weak self] in self?.remove(entry) })
    }

    // MARK: Staying out of the shot

    /// Takes the stack off the screen for the duration of a capture, and puts it
    /// back after. Cards sit in the bottom-right corner, which a full-screen shot
    /// includes and a region drag has to be worked around.
    ///
    /// Nothing is remembered about which panels were hidden: `entries` is the
    /// only source of truth, so a card auto-dismissed while hidden cannot be
    /// resurrected by the restore.
    private func setStackVisible(_ visible: Bool) {
        for entry in entries {
            if visible {
                entry.panel.orderFrontRegardless()
            } else {
                entry.panel.orderOut(nil)
            }
        }
    }

    /// Registered once, for the app's lifetime — the controller is a singleton,
    /// so there is nothing to tear down.
    private func observeCaptures() {
        for (name, visible) in [(Notification.Name.pearHideForCapture, false),
                                (Notification.Name.pearRestoreAfterCapture, true)] {
            NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: nil
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.setStackVisible(visible) }
            }
        }
    }

    /// Moves a live stack to whichever display now has the focused window.
    ///
    /// `NSScreen.main` is the focused window's screen, not this app's — the
    /// property the anchor comment calls out as drifting "to whatever app is
    /// focused" is exactly the wanted behaviour here. Re-anchoring runs through
    /// the same pure `anchor` decision as a capture, so an unplugged display or
    /// a nil `main` keeps the stack where it is rather than flinging it
    /// off-screen. Nothing happens with no cards up.
    ///
    /// App activation is the trigger: switching windows *within* one app across
    /// displays does not move the stack until the next app switch.
    /// ponytail: per-app AX focus observers would catch that too, at the cost of
    /// an AX client per running app; add only if the in-app case actually bites.
    private func observeFocusedScreen() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: nil
        ) { _ in
            // A beat after the activation: `main` follows the new key window,
            // which AppKit has not always installed by the time the notification
            // lands. The singleton is read inside the task rather than captured,
            // so nothing non-Sendable crosses the hop.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(150))
                ScreenshotPreviewController.shared.followFocusedScreen()
            }
        }
    }

    private func followFocusedScreen() {
        guard !entries.isEmpty else { return }
        let next = resolvedAnchor(capturedOn: nil, focused: NSScreen.main)
        guard next != anchorDisplay else { return }
        anchorDisplay = next
        // The new display can be shorter than the old one.
        evictOverflow(sparingOpenDetails: true)
        layout(newItem: nil)
    }

    /// A display unplugged, a resolution or arrangement change, a new primary,
    /// the Dock moving: re-resolve the anchor by id (gone → the menu-bar
    /// display, per `anchor`) and re-seat every card on the live frame, so no
    /// card animates to coordinates that are now off every screen. Registered
    /// once, like the activation observer; nothing happens with no cards up.
    private func observeScreenChanges() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }
    }

    private func screensChanged() {
        guard !entries.isEmpty else { return }
        anchorDisplay = resolvedAnchor(capturedOn: nil)
        // Same display or not, its visible frame may have shrunk.
        evictOverflow(sparingOpenDetails: true)
        layout(newItem: nil)
    }

    /// The files the cards on screen are backed by, which the store sweep keeps.
    var liveURLs: [URL] { entries.map(\.url) }

    /// Drops every card backed by `url`. Called when a read of that file fails:
    /// the card can no longer copy, save, open or send, so leaving it on screen
    /// would just offer buttons that do nothing.
    func dismissCards(backedBy url: URL) {
        for id in entries.filter({ $0.url == url }).map(\.id) { dismiss(id: id) }
    }

    private func remove(_ entry: PreviewEntry) {
        entry.timer?.invalidate()
        // Its detail window closes with it, so nothing else needs the scan.
        entry.detailContext.insights.cancel()
        entry.detail?.close()
        entry.panel.orderOut(nil)
        entries.removeAll { $0 === entry }
        layout(newItem: nil)
        if entries.isEmpty, let monitor = scrollMonitor {
            NSEvent.removeMonitor(monitor)
            scrollMonitor = nil
        }
    }

    /// Fade out and drop the oldest cards beyond the stack limit. A new card
    /// evicts outright; a stack that moved display (`sparingOpenDetails`) keeps
    /// any card whose detail window is open, because the user did not ask for
    /// that window to go and is likely reading it. A spared card sits past the
    /// fit until its detail window closes, which re-runs this (see `onClosed`).
    private func evictOverflow(sparingOpenDetails: Bool = false) {
        let maxCount = min(Prefs.previewMaxStack, Self.maxCardsThatFit(in: anchorVisible))
        let spared = sparingOpenDetails
            ? Set(entries.indices.filter { entries[$0].detail != nil }) : []
        let victims = PreviewStackLayout.evictionVictims(
            count: entries.count, maxFit: maxCount, protected: spared)
        for index in victims.reversed() {
            let victim = entries.remove(at: index)
            victim.timer?.invalidate()
            victim.detailContext.insights.cancel()
            // Same teardown `remove(_:)` does: the entry is the only strong
            // holder of its detail-window controller, and `NSWindow.delegate`
            // is weak — dropping it with the window open strands a window that
            // nothing can close and whose `onClosed` can never fire.
            victim.detail?.close()
            animate(0.24, { victim.panel.animator().alphaValue = 0 },
                    completion: { victim.panel.orderOut(nil) })
        }
    }

    // MARK: Auto-dismiss + hover

    private func scheduleAutoDismiss(_ entry: PreviewEntry) {
        entry.timer?.invalidate()
        entry.timer = nil
        guard PreviewStackLayout.autoDismisses(enabled: Prefs.previewAutoDismiss,
                                               detailOpen: entry.detail != nil,
                                               voiceOver: VoiceOverState.shared.isOn) else { return }
        let id = entry.id
        let timer = Timer(timeInterval: Prefs.previewAutoDismissSeconds, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.dismiss(id: id) }
        }
        RunLoop.main.add(timer, forMode: .common)
        entry.timer = timer
    }

    /// VoiceOver on stops every card's timer; off re-arms them. Re-registered
    /// on each change, since observation tracking fires once.
    private func observeVoiceOver() {
        withObservationTracking {
            _ = VoiceOverState.shared.isOn
        } onChange: {
            Task { @MainActor in ScreenshotPreviewController.shared.voiceOverChanged() }
        }
    }

    private func voiceOverChanged() {
        observeVoiceOver()
        // A hovered card stays held: `hoverChange` re-arms it on exit.
        for entry in entries where !entry.hovering { scheduleAutoDismiss(entry) }
    }

    private func hoverChange(id: UUID, hovering: Bool) {
        guard let entry = entries.first(where: { $0.id == id }) else { return }
        entry.hovering = hovering
        if hovering {
            entry.timer?.invalidate()
            entry.timer = nil
        } else {
            scheduleAutoDismiss(entry)
        }
    }

    // MARK: Scroll-to-dismiss

    /// One monitor for the whole stack: a decisive horizontal two-finger flick
    /// over a card dismisses that card (matched by its panel window).
    private func installScrollMonitor() {
        guard scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, let window = event.window,
                  let entry = self.entries.first(where: { $0.panel === window }) else { return event }
            guard let phase = Self.swipePhase(for: event) else { return event }
            if entry.swipe.feed(deltaX: event.scrollingDeltaX,
                                deltaY: event.scrollingDeltaY,
                                phase: phase) != nil {
                self.dismiss(id: entry.id)
                return nil
            }
            return event
        }
    }

    /// `NSEvent` scroll → `SwipePhase`; `nil` for a classic mouse wheel, which
    /// has no phase at all (so a running total never reset and drifted into a
    /// dismissal). Swipe-to-dismiss is a trackpad gesture, same as the
    /// scratchpad's swipe-to-switch.
    private static func swipePhase(for event: NSEvent) -> SwipePhase? {
        if !event.momentumPhase.isEmpty { return .momentum }
        if event.phase.contains(.began) { return .began }
        if event.phase.contains(.changed) { return .changed }
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) { return .ended }
        return nil
    }

    // MARK: Animation

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    private func animate(_ duration: TimeInterval, _ body: () -> Void,
                         completion: (@MainActor @Sendable () -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = reduceMotion ? 0 : duration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            body()
        }, completionHandler: completion.map { done -> @Sendable () -> Void in
            { MainActor.assumeIsolated { done() } }
        })
    }
}

/// Whether VoiceOver is running, kept live from AppKit's KVO-observable
/// `NSWorkspace.isVoiceOverEnabled`. SwiftUI's environment value is unproven in
/// a short-lived non-activating panel's hosting view.
@MainActor @Observable
final class VoiceOverState {
    static let shared = VoiceOverState()

    private(set) var isOn = NSWorkspace.shared.isVoiceOverEnabled
    @ObservationIgnored private var observation: NSKeyValueObservation?

    private init() {
        observation = NSWorkspace.shared.observe(\.isVoiceOverEnabled) { [weak self] _, _ in
            Task { @MainActor in
                let on = NSWorkspace.shared.isVoiceOverEnabled
                if self?.isOn != on { self?.isOn = on }
            }
        }
    }
}

private extension NSScreen {
    /// The display's `CGDirectDisplayID`: stable while it stays plugged in,
    /// unlike `visibleFrame`, which follows the Dock and the menu bar.
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

/// Borderless panels refuse key status by default; buttons need it.
private final class NonActivatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// A non-activating panel eats the first click to take key status, so opening
/// the detail view took two clicks — one to wake the card, one to hit it. First
/// mouse goes straight through to the content, same fix the companion panel and
/// the shelf already carry.
private final class PreviewHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// A sleek CleanShot-style card: just the thumbnail at rest; a slim icon-only
/// action bar and close button fade in on hover.
private struct ScreenshotPreviewView: View {
    let url: URL
    let canMarkup: Bool
    let canSend: Bool
    let canSave: Bool
    let canRemoveBackground: Bool
    let insights: ScreenshotInsights
    let onCopy: () -> Void
    let onCopyText: ((String) -> Void)?
    let onQRTap: (([String]) -> Void)?
    let onOpen: () -> Void
    let onPin: () -> Void
    let onSave: () -> Bool
    let onReveal: () -> Void
    let onMarkup: () -> Void
    let onRemoveBackground: () -> Void
    let onSend: () -> Void
    let onDismiss: () -> Void
    let onHoverChange: (Bool) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drag: CGSize = .zero
    @State private var hovering = false
    @State private var copied = false
    @State private var saved = false
    /// Decoded off the main actor; a flat placeholder of the same fixed size
    /// shows for the frame or two before it lands.
    @State private var image: NSImage?

    /// ~2.4× the 208pt thumbnail — headroom for scaledToFill's crop without
    /// ever inflating the full capture.
    private static let thumbMaxPixel = 504
    private static let thumbWidth: CGFloat = 208
    private static let thumbHeight: CGFloat = 130
    /// Slim glass rim: the card reads as a framed thumbnail, not a thumbnail
    /// floating in a panel. The inner radius is `cardRadius - inset` (10 − 4 =
    /// `Radius.small`), so the two corners stay concentric.
    private static let inset = Theme.Space.xSmall
    private static let cardRadius = Theme.Radius.medium

    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.05))
            .overlay {
                if let image { Image(nsImage: image).resizable().scaledToFill() }
            }
            .frame(width: Self.thumbWidth, height: Self.thumbHeight)
            .clipShape(RoundedRectangle(cornerRadius: Self.cardRadius - Self.inset))
            .overlay {
                RoundedRectangle(cornerRadius: Self.cardRadius - Self.inset)
                    .strokeBorder(.white.opacity(0.08), lineWidth: 0.5)
            }
            // Click the shot itself for the big view; the buttons layered on top
            // consume their own clicks, and a drag still becomes a swipe.
            .onTapGesture(perform: onOpen)
            .accessibilityLabel("Screenshot")
            .accessibilityHint("Opens the screenshot in a window")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(.default, onOpen)
            // VoiceOver cannot hover, so with it on the actions stay up.
            .overlay(alignment: .bottom) { if hovering || VoiceOverState.shared.isOn { toolbar } }
            .overlay(alignment: .topTrailing) { if hovering || VoiceOverState.shared.isOn { closeButton } }
            .overlay(alignment: .topLeading) {
                if insights.showsQRBadge { qrBadge }
            }
            .padding(Self.inset)
            .glassCard(cornerRadius: Self.cardRadius)
            // Swipe right to flick it away; the panel then slides off-screen
            // with the content riding along, so the motion is continuous.
            .offset(x: drag.width, y: drag.height)
            .opacity(1.0 - min(Double(abs(drag.width)) / 240.0, 0.6))
            .gesture(dragGesture)
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.14)) { self.hovering = hovering }
                onHoverChange(hovering)
            }
            .task {
                let url = url, maxPixel = Self.thumbMaxPixel
                image = await Task.detached(priority: .userInitiated) {
                    Thumbnail.image(at: url, maxPixel: maxPixel)
                }.value
                // The header read but the pixels would not: a failed read
                // dismisses the card, like any other.
                if image == nil { onDismiss() }
            }
            // The Copy checkmark is a brief confirmation, like the detail
            // window's; on the body, not the hover-only toolbar, so it resets.
            .task(id: copied) {
                guard copied, (try? await Task.sleep(for: .seconds(1.5))) != nil else { return }
                withAnimation { copied = false }
            }
    }

    /// Icon-only actions in a floating capsule over the thumbnail's lower edge.
    private var toolbar: some View {
        // Exception: 2 pt gaps, so up to eight 26 pt actions fit the 208 pt
        // thumbnail; the scale's smallest step (4) would push the bar past it.
        HStack(spacing: 2) {
            PreviewAction(symbol: copied ? "checkmark" : "doc.on.doc", help: "Copy") {
                onCopy(); withAnimation { copied = true }
            }
            // Only once the scan has text: copies what it read, no second pass.
            if let onCopyText, !insights.text.isEmpty {
                PreviewAction(symbol: "text.viewfinder", help: "Copy text") { onCopyText(insights.text) }
            }
            if canSave {
                PreviewAction(symbol: saved ? "checkmark" : "square.and.arrow.down", help: "Save") {
                    if onSave() { withAnimation { saved = true } }
                }
            }
            PreviewAction(symbol: "folder", help: "Reveal", action: onReveal)
            PreviewAction(symbol: "pin", help: "Pin to screen", action: onPin)
                .accessibilityLabel("Pin to screen")
            if canRemoveBackground {
                PreviewAction(
                    symbol: "person.and.background.dotted",
                    help: "Remove background", action: onRemoveBackground)
            }
            if canMarkup {
                PreviewAction(symbol: "pencil.tip.crop.circle", help: "Markup", action: onMarkup)
            }
            if canSend {
                PreviewAction(symbol: "paperplane.fill", help: "Send", tint: Theme.accent, action: onSend)
            }
        }
        .padding(Theme.Space.xSmall)
        // A flat fill, not glass: the card is already glass. 24 + 2 × 4 = 32 pt
        // tall, so the large radius is a capsule.
        .background(Color(nsColor: .windowBackgroundColor),
                    in: RoundedRectangle(cornerRadius: Theme.Radius.large))
        .padding(.bottom, Theme.Space.small)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    private var closeButton: some View {
        Button(action: onDismiss) {
            Image(systemName: "xmark.circle.fill")
                .font(Theme.Typography.large())
                .foregroundStyle(.white, .black.opacity(0.45))
                .padding(Theme.Space.xSmall)
        }
        .buttonStyle(.plain)
        .help("Close")
        .accessibilityLabel("Close")
        .transition(.opacity)
    }

    private var qrBadge: some View {
        Button(action: { onQRTap?(insights.payloads) }) {
            Image(systemName: "qrcode")
                .font(Theme.Typography.small(.semibold))
                .foregroundStyle(.white)
                .padding(Theme.Space.xSmall)
                .background(Circle().fill(.black.opacity(0.55)))
        }
        .buttonStyle(.plain)
        .help("QR code found. Copy its contents.")
        .accessibilityLabel("Copy QR code contents")
        .padding(Theme.Space.small)
        .transition(.opacity)
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { drag = $0.translation }
            .onEnded { value in
                if value.translation.width > 90 {
                    onDismiss() // keep the offset; the panel exit is seamless
                } else {
                    withAnimation(Theme.motion(.spring(response: 0.3, dampingFraction: 0.7),
                                               reduce: reduceMotion)) { drag = .zero }
                }
            }
    }
}

/// Compact icon-only button for the hover action bar; the label lives in the
/// tooltip so the bar stays slim.
private struct PreviewAction: View {
    let symbol: String
    let help: String
    var tint: Color = .primary
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(Theme.Typography.body(.medium))
                .foregroundStyle(hovering ? Theme.accent : tint)
                .frame(width: 26, height: 24)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.small).fill(hovering ? Theme.accentSoft : .clear))
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(help)
        .accessibilityLabel(help)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}
