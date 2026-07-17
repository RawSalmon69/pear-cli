// Adapted from DockDoor (GPL-3.0), https://github.com/ejbills/DockDoor,
// commit 78b0862f — original: DockDoor/Views/Hover Window/Shared Components/
// SharedPreviewWindowCoordinator.swift (the switcher panel) and
// WindowPreviewHoverContainer.swift (the tile grid).
//
// DockDoor's switcher shares its 1000-line coordinator with the hover preview,
// full of live SCStream thumbnails, search, and grid math. This is a much
// smaller, centered overlay: a borderless nonactivating NSPanel above the Dock
// (same .statusBar level as the hover panel) showing a bounded grid of
// app-icon + title tiles with the selection ringed. Thumbnails are deferred (see
// the ponytail marker) to keep the switcher's footprint to transient tiles.

import AppKit
import SwiftUI

/// Owns the switcher overlay NSPanel and its SwiftUI model. Reused across
/// switches: content is re-hosted and re-centered on each `show`.
@MainActor
final class DockSwitcherPanel {
    let model = DockSwitcherModel()
    private var panel: NSPanel?

    func show(entries: [DockSwitcherEntry], selected: Int, maxDimension: CGFloat) {
        // ponytail: switcher tiles show app icon + title only. Window thumbnails
        // would reuse DockThumbnailer.capture per app (dedup by pid, best-effort,
        // attached after show like the hover path), deferred to keep the
        // switcher's footprint to transient icon tiles rather than a burst of
        // SCScreenshotManager captures across every app on each ⌥-tab.
        model.tileMaxDimension = maxDimension
        model.selectedID = selected
        model.tiles = entries.map { entry in
            DockSwitcherTile(
                id: entry.id,
                appName: entry.app.name,
                title: entry.window.title,
                icon: entry.app.hydrate()?.icon,
                isMinimized: entry.window.isMinimized
            )
        }

        let host = NSHostingView(rootView: DockSwitcherView(model: model).glassCard(cornerRadius: 16))
        host.clipToCard(radius: 16)
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize

        let panel = ensurePanel()
        panel.contentView = host
        panel.setFrame(centeredFrame(size: size), display: true)
        panel.orderFrontRegardless() // nonactivating: no focus theft
    }

    func updateSelection(_ index: Int) {
        model.selectedID = index
    }

    func hide() {
        panel?.orderOut(nil)
        model.tiles = []
    }

    /// Centered on the screen under the cursor (falling back to main), clamped
    /// inside its visible frame — a tall many-window grid used to hang off the
    /// top and bottom of the screen (the old comment claimed a clamp that
    /// wasn't there; the pure geometry helper now actually does it).
    private func centeredFrame(size: CGSize) -> CGRect {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? .zero
        return DockGeometry.centeredFrame(size: size, in: visible)
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar // clears the Dock, matching the hover panel
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.animationBehavior = .none
        self.panel = panel
        return panel
    }
}

/// Backing state for the switcher overlay. The controller mutates this; the
/// view observes it, so a cycle re-renders only the highlight.
@MainActor
@Observable
final class DockSwitcherModel {
    var tiles: [DockSwitcherTile] = []
    var selectedID: Int = -1
    var tileMaxDimension = DockDoorSettings.defaultPreviewSize.maxDimension
}

/// One switcher tile's static state.
struct DockSwitcherTile: Identifiable {
    let id: Int
    let appName: String
    let title: String
    let icon: NSImage?
    let isMinimized: Bool
}

/// The switcher overlay content: a bounded grid of app-icon + title tiles with
/// the current selection ringed.
struct DockSwitcherView: View {
    @Bindable var model: DockSwitcherModel

    /// Cap the grid width; wrap into rows past this many tiles per row.
    private static let maxPerRow = 6

    private var columns: [GridItem] {
        let count = min(max(model.tiles.count, 1), Self.maxPerRow)
        return Array(repeating: GridItem(.fixed(tileWidth), spacing: Theme.itemGap), count: count)
    }

    private var tileWidth: CGFloat { model.tileMaxDimension * 0.7 }

    var body: some View {
        LazyVGrid(columns: columns, spacing: Theme.itemGap) {
            ForEach(model.tiles) { tile in
                DockSwitcherTileView(
                    tile: tile,
                    isSelected: tile.id == model.selectedID,
                    width: tileWidth
                )
            }
        }
        .padding(Theme.cardPadding)
        .fixedSize()
    }
}

private struct DockSwitcherTileView: View {
    let tile: DockSwitcherTile
    let isSelected: Bool
    let width: CGFloat

    private var iconSide: CGFloat { (width * 0.5).rounded() }

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                if let icon = tile.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: iconSide, height: iconSide)
                } else {
                    Image(systemName: "macwindow")
                        .font(.system(size: iconSide * 0.5))
                        .foregroundStyle(.secondary)
                        .frame(width: iconSide, height: iconSide)
                }

                if tile.isMinimized {
                    VStack {
                        Spacer()
                        HStack {
                            Image(systemName: "minus.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                    }
                }
            }
            .frame(width: width, height: iconSide + 12)

            Text(tile.title)
                .font(Theme.caption)
                .foregroundStyle(isSelected ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: width)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isSelected ? Theme.accentSoft : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isSelected ? Theme.accent : Color.clear, lineWidth: 2)
        )
        .help(tile.title)
    }
}
