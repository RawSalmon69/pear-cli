import SwiftUI
import AppKit

/// Floating post-capture preview: thumbnail + Copy / Folder / Send 🍐.
/// Non-activating NSPanel pinned bottom-right; auto-dismisses after ~6 s,
/// hovering pauses the countdown. Plain styling — the design pass restyles.
@MainActor
final class ScreenshotPreviewController {
    private var panel: NSPanel?
    private var dismissTimer: Timer?
    private var scrollMonitor: Any?
    private var scrollAccumulator: CGFloat = 0

    private static let panelSize = NSSize(width: 280, height: 236)
    private static let dismissDelay: TimeInterval = 6
    private static let margin: CGFloat = 20

    func show(
        imageData: Data,
        canMarkup: Bool,
        canSend: Bool = FeatureFlags.coupleNote,
        onCopy: @escaping () -> Void,
        onReveal: @escaping () -> Void,
        onMarkup: @escaping () -> Void,
        onSend: @escaping () -> Void
    ) {
        dismiss() // one preview at a time

        // 252 pt display width @2x — never inflate the full capture here.
        guard let image = Thumbnail.image(from: imageData, maxPixel: 504) else { return }

        let content = ScreenshotPreviewView(
            image: image,
            canMarkup: canMarkup,
            canSend: canSend,
            onCopy: onCopy,
            onReveal: onReveal,
            onMarkup: { [weak self] in
                onMarkup()
                self?.dismiss()
            },
            onSend: { [weak self] in
                onSend()
                self?.dismiss()
            },
            onDismiss: { [weak self] in self?.dismiss() },
            onHoverChange: { [weak self] hovering in
                if hovering {
                    self?.dismissTimer?.invalidate()
                    self?.dismissTimer = nil
                } else {
                    self?.scheduleDismiss()
                }
            }
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
        host.clipToCard()
        panel.contentView = host

        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(
                x: visible.maxX - Self.panelSize.width - Self.margin,
                y: visible.minY + Self.margin
            ))
        }
        panel.orderFrontRegardless()
        self.panel = panel
        installScrollDismiss(on: panel)
        scheduleDismiss()
    }

    func dismiss() {
        dismissTimer?.invalidate()
        dismissTimer = nil
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        scrollMonitor = nil
        panel?.orderOut(nil)
        panel = nil
    }

    /// Two-finger trackpad swipe (right or down) over the preview flicks it
    /// away — the gesture people reach for, alongside the click-drag flick.
    private func installScrollDismiss(on panel: NSPanel) {
        scrollAccumulator = 0
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) {
            [weak self, weak panel] event in
            guard let self, let panel, event.window === panel else { return event }
            self.scrollAccumulator += max(event.scrollingDeltaX, -event.scrollingDeltaY)
            if self.scrollAccumulator > 60 {
                self.dismiss()
                return nil
            }
            if event.phase == .ended || event.momentumPhase == .ended {
                self.scrollAccumulator = 0
            }
            return event
        }
    }

    private func scheduleDismiss() {
        dismissTimer?.invalidate()
        let timer = Timer(timeInterval: Self.dismissDelay, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.dismiss() }
        }
        RunLoop.main.add(timer, forMode: .common)
        dismissTimer = timer
    }
}

/// Borderless panels refuse key status by default; buttons need it.
private final class NonActivatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private struct ScreenshotPreviewView: View {
    let image: NSImage
    let canMarkup: Bool
    let canSend: Bool
    let onCopy: () -> Void
    let onReveal: () -> Void
    let onMarkup: () -> Void
    let onSend: () -> Void
    let onDismiss: () -> Void
    let onHoverChange: (Bool) -> Void

    @State private var appeared = false
    @State private var drag: CGSize = .zero
    @State private var copied = false

    var body: some View {
        VStack(spacing: 10) {
            // Fill a fixed rounded frame so the image meets the card's curve
            // cleanly with no square corners or letterbox gaps.
            RoundedRectangle(cornerRadius: 10)
                .fill(.black.opacity(0.15))
                .frame(width: 252, height: 150)
                .overlay {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 252, height: 150)
                }
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.25), radius: 6, y: 3)

            HStack(spacing: 6) {
                PreviewAction(symbol: copied ? "checkmark" : "doc.on.doc",
                              label: copied ? "Copied" : "Copy") {
                    onCopy()
                    withAnimation { copied = true }
                }
                PreviewAction(symbol: "folder", label: "Reveal", action: onReveal)
                if canMarkup {
                    PreviewAction(symbol: "pencil.tip.crop.circle", label: "Markup", action: onMarkup)
                }
                if canSend {
                    PreviewAction(symbol: "paperplane.fill", label: "Send",
                                  tint: Theme.accent, action: onSend)
                }
            }
        }
        .padding(12)
        .glassCard(cornerRadius: 16)
        .overlay(alignment: .topTrailing) {
            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .padding(6)
            }
            .buttonStyle(.plain)
            .opacity(0.7)
        }
        // Swipe/drag down or right to flick it away.
        .offset(x: drag.width, y: drag.height)
        .opacity(appeared ? 1 : 0)
        .scaleEffect(appeared ? 1 : 0.92)
        .gesture(
            DragGesture()
                .onChanged { drag = $0.translation }
                .onEnded { value in
                    if abs(value.translation.width) > 90 || value.translation.height > 90 {
                        onDismiss()
                    } else {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { drag = .zero }
                    }
                }
        )
        .onHover(perform: onHoverChange)
        .onAppear {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) { appeared = true }
        }
    }
}

/// Compact labeled icon button used in the preview action row.
private struct PreviewAction: View {
    let symbol: String
    let label: String
    var tint: Color = .primary
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .medium))
                Text(label)
                    .font(.system(size: 9, weight: .medium, design: .rounded))
            }
            .foregroundStyle(hovering ? Theme.accent : tint)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(hovering ? Theme.accentSoft : .clear)
            )
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}
