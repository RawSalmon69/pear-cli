// Adapted from Loop (GPL-3.0), https://github.com/MrKai77/Loop, commit 3b632db5
// Original file: Loop/Window Action Indicators/Preview Window/PreviewView.swift
//
// Loop previews the would-be frame with a full-screen, click-through panel
// on the target screen (`PreviewController` + `PreviewView`), animating the
// highlighted rect between action changes and applying the resize only on
// release. Same model here: one screen-sized panel, a rounded accent rect
// that eases between zone frames, nothing interactive. `ZonePreviewView` now
// carries Loop's `PreviewView` styling verbatim (blur backing, accent-gradient
// fill at low opacity, quinary + accent-gradient borders, inset padding); only
// the plumbing (the screen-sized panel, the rect-offset placement) is Pear's.

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

/// The would-be frame, carrying Loop's `PreviewView` look (blur backing,
/// accent-gradient fill, quinary + accent borders, inset padding), in Pear's
/// accent. Eases between zone frames at the tool's animation speed.
struct ZonePreviewView: View {
    @ObservedObject var model: ZonePreviewModel

    @AppStorage(WindowSettings.Key.previewPadding)
    private var paddingStore = WindowSettings.defaultPreviewPadding
    @AppStorage(WindowSettings.Key.previewBlur)
    private var blurEnabled = WindowSettings.defaultPreviewBlur
    @AppStorage(WindowSettings.Key.animationSpeed)
    private var speedStore = WindowSettings.defaultAnimationSpeed.rawValue

    // Loop's preview constants not exposed as Pear settings.
    private let previewCornerRadius: CGFloat = 10 // Loop default
    private let previewBorderThickness: CGFloat = 4 // Loop default
    private let previewBackgroundAccentOpacity: Double = 0.1 // Loop default

    private var accent: Color { Theme.accent }
    private var padding: CGFloat {
        CGFloat(min(max(paddingStore, WindowSettings.previewPaddingRange.lowerBound),
                    WindowSettings.previewPaddingRange.upperBound))
    }

    private var glideAnimation: Animation {
        (WindowAnimationSpeed(rawValue: speedStore) ?? WindowSettings.defaultAnimationSpeed)
            .previewWindow ?? .linear(duration: 0)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let rect = model.rect {
                windowView
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(glideAnimation, value: model.rect)
        .allowsHitTesting(false)
    }

    private var windowView: some View {
        ZStack {
            ZStack {
                VisualEffectView(material: .hudWindow, blendingMode: .behindWindow, state: .active)
                    .opacity(blurEnabled ? 1 : 0)

                LinearGradient(
                    gradient: Gradient(colors: [accent, accent]),
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .opacity(previewBackgroundAccentOpacity)
            }
            .clipShape(.rect(cornerRadius: previewCornerRadius))

            RoundedRectangle(cornerRadius: previewCornerRadius)
                .strokeBorder(.quinary, lineWidth: 1)

            RoundedRectangle(cornerRadius: previewCornerRadius)
                .stroke(
                    LinearGradient(
                        gradient: Gradient(colors: [accent, accent]),
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: previewBorderThickness
                )
        }
        .padding(padding + previewBorderThickness / 2)
    }
}
