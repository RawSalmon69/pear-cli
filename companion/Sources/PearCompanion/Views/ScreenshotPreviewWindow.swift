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
}

/// One preview: its non-activating panel plus per-card timer / gesture state.
@MainActor
private final class PreviewEntry {
    let id: UUID
    let panel: NSPanel
    var timer: Timer?
    var scrollAccumulator: CGFloat = 0

    init(id: UUID, panel: NSPanel) {
        self.id = id
        self.panel = panel
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
    private var entries: [PreviewEntry] = [] // index 0 = newest, nearest edge
    private var scrollMonitor: Any?
    /// Visible frame the stack lives in — the primary display, resolved when the
    /// first card appears (see `show`). Fixed for the stack's lifetime so cards
    /// never jump displays, and always the primary so the preview is in one
    /// predictable spot rather than the focused-window screen (NSScreen.main).
    private var anchorVisible: NSRect = .zero

    private static let panelSize = NSSize(width: 216, height: 141)
    private static let margin: CGFloat = 20
    private static let gap: CGFloat = 12

    func show(
        imageData: Data,
        canMarkup: Bool,
        canSend: Bool = FeatureFlags.coupleNote,
        canSave: Bool = false,
        onCopy: @escaping () -> Void,
        onReveal: @escaping () -> Void,
        onMarkup: @escaping () -> Void,
        onRemoveBackground: @escaping () -> Void = {},
        onSend: @escaping () -> Void,
        onSave: @escaping () -> Void = {}
    ) {
        // 252 pt display width @2x — never inflate the full capture here.
        guard let image = Thumbnail.image(from: imageData, maxPixel: 504) else { return }

        let id = UUID()
        let content = ScreenshotPreviewView(
            image: image,
            canMarkup: canMarkup,
            canSend: canSend,
            canSave: canSave,
            onCopy: onCopy,
            onSave: onSave,
            onReveal: onReveal,
            onMarkup: { [weak self] in
                onMarkup()
                self?.dismiss(id: id)
            },
            onRemoveBackground: { [weak self] in
                onRemoveBackground()
                self?.dismiss(id: id)
            },
            onSend: { [weak self] in
                onSend()
                self?.dismiss(id: id)
            },
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
        let host = NSHostingView(rootView: content)
        host.clipToCard(radius: 12)
        panel.contentView = host

        let entry = PreviewEntry(id: id, panel: panel)
        // Fix the anchor screen when a fresh stack starts; existing stacks keep
        // theirs so the cards stay put on the capture display.
        if entries.isEmpty { anchorVisible = Self.anchorVisibleFrame() }
        entries.insert(entry, at: 0)
        evictOverflow()
        layout(newItem: entry)
        installScrollMonitor()
        scheduleAutoDismiss(entry)
    }

    /// Visible frame of the primary display — the preview always lives there, a
    /// fixed spot the user learns, rather than `NSScreen.main` (the key-window
    /// screen), which drifts to whatever display holds the focused app.
    private static func anchorVisibleFrame() -> NSRect {
        (NSScreen.screens.first ?? NSScreen.main)?.visibleFrame ?? .zero
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

    private func remove(_ entry: PreviewEntry) {
        entry.timer?.invalidate()
        entry.panel.orderOut(nil)
        entries.removeAll { $0 === entry }
        layout(newItem: nil)
        if entries.isEmpty, let monitor = scrollMonitor {
            NSEvent.removeMonitor(monitor)
            scrollMonitor = nil
        }
    }

    /// Fade out and drop the oldest cards beyond the stack limit.
    private func evictOverflow() {
        let maxCount = min(Prefs.previewMaxStack, Self.maxCardsThatFit(in: anchorVisible))
        while entries.count > maxCount {
            let victim = entries.removeLast()
            victim.timer?.invalidate()
            animate(0.24, { victim.panel.animator().alphaValue = 0 },
                    completion: { victim.panel.orderOut(nil) })
        }
    }

    // MARK: Auto-dismiss + hover

    private func scheduleAutoDismiss(_ entry: PreviewEntry) {
        entry.timer?.invalidate()
        entry.timer = nil
        guard Prefs.previewAutoDismiss else { return }
        let id = entry.id
        let timer = Timer(timeInterval: Prefs.previewAutoDismissSeconds, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.dismiss(id: id) }
        }
        RunLoop.main.add(timer, forMode: .common)
        entry.timer = timer
    }

    private func hoverChange(id: UUID, hovering: Bool) {
        guard let entry = entries.first(where: { $0.id == id }) else { return }
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
            entry.scrollAccumulator += event.scrollingDeltaX
            if abs(entry.scrollAccumulator) > 50 {
                self.dismiss(id: entry.id)
                return nil
            }
            if event.phase == .ended || event.momentumPhase == .ended {
                entry.scrollAccumulator = 0
            }
            return event
        }
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

/// Borderless panels refuse key status by default; buttons need it.
private final class NonActivatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// A sleek CleanShot-style card: just the thumbnail at rest; a slim icon-only
/// action bar and close button fade in on hover.
private struct ScreenshotPreviewView: View {
    let image: NSImage
    let canMarkup: Bool
    let canSend: Bool
    let canSave: Bool
    let onCopy: () -> Void
    let onSave: () -> Void
    let onReveal: () -> Void
    let onMarkup: () -> Void
    let onRemoveBackground: () -> Void
    let onSend: () -> Void
    let onDismiss: () -> Void
    let onHoverChange: (Bool) -> Void

    @State private var drag: CGSize = .zero
    @State private var hovering = false
    @State private var copied = false
    @State private var saved = false

    private static let thumbWidth: CGFloat = 200
    private static let thumbHeight: CGFloat = 125

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .scaledToFill()
            .frame(width: Self.thumbWidth, height: Self.thumbHeight)
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .overlay {
                RoundedRectangle(cornerRadius: 9).strokeBorder(.white.opacity(0.12), lineWidth: 1)
            }
            .overlay(alignment: .bottom) { if hovering { toolbar } }
            .overlay(alignment: .topTrailing) { if hovering { closeButton } }
            .padding(8)
            .glassCard(cornerRadius: 12)
            // Swipe right to flick it away; the panel then slides off-screen
            // with the content riding along, so the motion is continuous.
            .offset(x: drag.width, y: drag.height)
            .opacity(1.0 - min(Double(abs(drag.width)) / 240.0, 0.6))
            .gesture(dragGesture)
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.14)) { self.hovering = hovering }
                onHoverChange(hovering)
            }
    }

    /// Icon-only actions in a floating capsule over the thumbnail's lower edge.
    private var toolbar: some View {
        HStack(spacing: 2) {
            PreviewAction(symbol: copied ? "checkmark" : "doc.on.doc", help: "Copy") {
                onCopy(); withAnimation { copied = true }
            }
            if canSave {
                PreviewAction(symbol: saved ? "checkmark" : "square.and.arrow.down", help: "Save") {
                    onSave(); withAnimation { saved = true }
                }
            }
            PreviewAction(symbol: "folder", help: "Reveal", action: onReveal)
            PreviewAction(
                symbol: "person.and.background.dotted",
                help: "Remove background", action: onRemoveBackground)
            if canMarkup {
                PreviewAction(symbol: "pencil.tip.crop.circle", help: "Markup", action: onMarkup)
            }
            if canSend {
                PreviewAction(symbol: "paperplane.fill", help: "Send", tint: Theme.accent, action: onSend)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 1))
        .padding(.bottom, 7)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    private var closeButton: some View {
        Button(action: onDismiss) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(.white, .black.opacity(0.45))
                .padding(5)
        }
        .buttonStyle(.plain)
        .transition(.opacity)
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { drag = $0.translation }
            .onEnded { value in
                if value.translation.width > 90 {
                    onDismiss() // keep the offset; the panel exit is seamless
                } else {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { drag = .zero }
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
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(hovering ? Theme.accent : tint)
                .frame(width: 26, height: 24)
                .background(RoundedRectangle(cornerRadius: 7).fill(hovering ? Theme.accentSoft : .clear))
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(help)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}
