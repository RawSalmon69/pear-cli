// Adapted from DockDoor (GPL-3.0), https://github.com/ejbills/DockDoor,
// commit 78b0862f — original: DockDoor/Views/Hover Window/{WindowPreview,
// WindowPreviewHoverContainer}.swift and WindowPreviewInteractionModifier.swift.
//
// The grid/tile look is rebuilt in Pear's own Theme; the interaction is
// DockDoor's tap-to-raise, trimmed to a plain SwiftUI onTapGesture (no
// middle-click / trackpad-swipe / context menu). Thumbnails render from a
// Sendable CGImage the capture task hands back; tiles fall back to the app icon
// when no capture exists (minimized window, or Screen Recording denied).

import SwiftUI

/// One preview tile's live state. `@Observable` class so attaching a thumbnail
/// after capture re-renders only that tile, not the whole panel.
@MainActor
@Observable
final class DockWindowTile: Identifiable {
    let id: Int
    let title: String
    let isMinimized: Bool
    var image: CGImage?
    /// Raise the window and hide the panel.
    @ObservationIgnored let activate: () -> Void

    init(id: Int, title: String, isMinimized: Bool, image: CGImage?, activate: @escaping () -> Void) {
        self.id = id
        self.title = title
        self.isMinimized = isMinimized
        self.image = image
        self.activate = activate
    }
}

/// Backing state for the hover panel's content. The controller mutates this;
/// the view observes it.
@MainActor
@Observable
final class DockPreviewModel {
    var appName = ""
    var appIcon: NSImage?
    var tiles: [DockWindowTile] = []
    var showTitles = DockDoorSettings.defaultShowTitles
    var tileMaxDimension = DockDoorSettings.defaultPreviewSize.maxDimension
    /// Reports the mouse entering (true) or leaving (false) the panel content,
    /// so the controller can cancel or schedule the hide. Not observed.
    @ObservationIgnored var onHoverChange: ((Bool) -> Void)?
}

/// The hover panel's content: a row of window thumbnails with titles.
struct DockPreviewView: View {
    @Bindable var model: DockPreviewModel

    var body: some View {
        HStack(alignment: .top, spacing: Theme.itemGap) {
            ForEach(model.tiles) { tile in
                DockTileView(
                    tile: tile,
                    appIcon: model.appIcon,
                    showTitle: model.showTitles,
                    maxDimension: model.tileMaxDimension
                )
            }
        }
        .padding(Theme.cardPadding)
        .fixedSize()
        .contentShape(Rectangle())
        .onHover { model.onHoverChange?($0) }
    }
}

/// A single window tile: thumbnail (or app-icon fallback) plus an optional
/// title, raising the window on tap.
private struct DockTileView: View {
    let tile: DockWindowTile
    let appIcon: NSImage?
    let showTitle: Bool
    let maxDimension: CGFloat

    @State private var hovering = false

    private var tileWidth: CGFloat { maxDimension }
    private var tileHeight: CGFloat { (maxDimension * 0.62).rounded() }

    var body: some View {
        Button(action: tile.activate) {
            VStack(spacing: 5) {
                thumbnail
                    .frame(width: tileWidth, height: tileHeight)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.secondary.opacity(0.10))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(hovering ? Theme.accent : Color.secondary.opacity(0.20), lineWidth: hovering ? 2 : 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                if showTitle {
                    Text(tile.title)
                        .font(Theme.caption)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: tileWidth)
                }
            }
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(tile.title)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    @ViewBuilder
    private var thumbnail: some View {
        ZStack {
            if let image = tile.image {
                Image(decorative: image, scale: 2, orientation: .up)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else if let appIcon {
                Image(nsImage: appIcon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: tileHeight * 0.5, height: tileHeight * 0.5)
                    .opacity(0.9)
            } else {
                Image(systemName: "macwindow")
                    .font(.system(size: 22))
                    .foregroundStyle(.secondary)
            }

            if tile.isMinimized {
                VStack {
                    Spacer()
                    HStack {
                        Image(systemName: "minus.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .padding(4)
                        Spacer()
                    }
                }
            }
        }
    }
}
