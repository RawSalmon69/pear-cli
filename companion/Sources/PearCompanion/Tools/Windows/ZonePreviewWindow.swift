// Adapted from Loop (GPL-3.0), https://github.com/MrKai77/Loop
//
// Loop previews the would-be frame with a full-screen, click-through panel
// on the target screen (`PreviewController` + `PreviewView`), animating the
// highlighted rect between action changes and applying the resize only on
// release. Same model here: one screen-sized panel, a rounded accent rect
// that eases between zone frames, nothing interactive.

import AppKit
import SwiftUI

/// Owns the translucent would-be-frame overlay on the snap target's screen.
@MainActor
final class ZonePreviewController {
    private var panel: NSPanel?
    private var screen: NSScreen?
    private let model = ZonePreviewModel()

    /// Puts the (initially empty) overlay on `screen`; `update` reveals the
    /// zone rect once the user aims at a sector.
    func show(on screen: NSScreen) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        self.screen = screen

        model.rect = nil
        panel.setFrame(screen.frame, display: true)
        panel.orderFrontRegardless()
    }

    /// `globalRect` is the would-be frame in AppKit's global y-up space
    /// (or nil to hide the highlight while keeping the overlay up).
    func update(_ globalRect: NSRect?) {
        guard let screen else { return }
        guard let globalRect else {
            model.rect = nil
            return
        }
        // Convert into the panel's top-left-origin view space.
        model.rect = CGRect(
            x: globalRect.minX - screen.frame.minX,
            y: screen.frame.maxY - globalRect.maxY,
            width: globalRect.width,
            height: globalRect.height
        )
    }

    func hide() {
        model.rect = nil
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        // One below the ring so the ring always reads on top.
        panel.level = NSWindow.Level(NSWindow.Level.screenSaver.rawValue - 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: ZonePreviewView(model: model))
        return panel
    }
}

@MainActor
final class ZonePreviewModel: ObservableObject {
    /// Highlight rect in the panel's top-left-origin space; nil hides it.
    @Published var rect: CGRect?
}

/// The would-be frame: accent fill at 20% with a 1 pt accent border, easing
/// between zone frames (Loop's preview look, in Pear's accent).
struct ZonePreviewView: View {
    @ObservedObject var model: ZonePreviewModel

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let rect = model.rect {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Theme.accent.opacity(0.2))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(Theme.accent, lineWidth: 1)
                    )
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(.easeOut(duration: 0.15), value: model.rect)
        .allowsHitTesting(false)
    }
}
