import SwiftUI
import AppKit

/// Floating post-capture preview: thumbnail + Copy / Folder / Send 🍐.
/// Non-activating NSPanel pinned bottom-right; auto-dismisses after ~6 s,
/// hovering pauses the countdown. Plain styling — the design pass restyles.
@MainActor
final class ScreenshotPreviewController {
    private var panel: NSPanel?
    private var dismissTimer: Timer?

    private static let panelSize = NSSize(width: 264, height: 210)
    private static let dismissDelay: TimeInterval = 6
    private static let margin: CGFloat = 20

    func show(
        imageData: Data,
        onCopy: @escaping () -> Void,
        onReveal: @escaping () -> Void,
        onSend: @escaping () -> Void
    ) {
        dismiss() // one preview at a time

        guard let image = NSImage(data: imageData) else { return }

        let content = ScreenshotPreviewView(
            image: image,
            onCopy: onCopy,
            onReveal: onReveal,
            onSend: { [weak self] in
                onSend()
                self?.dismiss()
            },
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
        panel.contentView = NSHostingView(rootView: content)

        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(
                x: visible.maxX - Self.panelSize.width - Self.margin,
                y: visible.minY + Self.margin
            ))
        }
        panel.orderFrontRegardless()
        self.panel = panel
        scheduleDismiss()
    }

    func dismiss() {
        dismissTimer?.invalidate()
        dismissTimer = nil
        panel?.orderOut(nil)
        panel = nil
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
    let onCopy: () -> Void
    let onReveal: () -> Void
    let onSend: () -> Void
    let onHoverChange: (Bool) -> Void

    var body: some View {
        VStack(spacing: 8) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 240, maxHeight: 140)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            HStack(spacing: 8) {
                Button("Copy", action: onCopy)
                Button("Folder", action: onReveal)
                Button("Send 🍐", action: onSend)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .onHover(perform: onHoverChange)
    }
}
