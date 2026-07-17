import AppKit
import SwiftUI

/// The cheat-sheet contents: app header, then each menu group as a titled block
/// of title/glyph rows, laid out across up to three columns filled top-to-bottom
/// so reading down each column follows menu order. When the content is taller
/// than the screen the column area scrolls (the controller sets `scrollable`).
struct KeyCluOverlayView: View {
    let appName: String
    let appIcon: NSImage?
    let groups: [MenuGroup]
    /// Set by the controller when the natural height exceeds the screen: wraps
    /// the columns in a ScrollView and lets the height be driven by the panel
    /// frame instead of intrinsic content.
    var scrollable: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.itemGap) {
            header
            if groups.isEmpty {
                Text("No shortcuts found").font(Theme.body).foregroundStyle(.secondary)
            } else if scrollable {
                ScrollView(.vertical) { columnsRow }
            } else {
                columnsRow
            }
        }
        .padding(Theme.cardPadding)
        .glassCard(cornerRadius: 16)
        .fixedSize(horizontal: true, vertical: !scrollable)
    }

    private var header: some View {
        HStack(spacing: 8) {
            if let appIcon {
                Image(nsImage: appIcon).resizable().frame(width: 20, height: 20)
            }
            Text(appName).font(Theme.emphasis)
            Spacer(minLength: 24)
            Text("esc to close").font(Theme.body).foregroundStyle(.tertiary)
        }
    }

    private var columnsRow: some View {
        HStack(alignment: .top, spacing: 28) {
            ForEach(Array(columns().enumerated()), id: \.offset) { _, column in
                VStack(alignment: .leading, spacing: Theme.itemGap) {
                    ForEach(Array(column.enumerated()), id: \.offset) { _, group in
                        groupBlock(group)
                    }
                }
            }
        }
    }

    private func groupBlock(_ group: MenuGroup) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(group.title).font(Theme.emphasis).foregroundStyle(Theme.accent)
            ForEach(Array(group.shortcuts.enumerated()), id: \.offset) { _, shortcut in
                HStack(spacing: 16) {
                    Text(shortcut.title).font(Theme.body)
                    Spacer(minLength: 12)
                    Text(shortcut.glyph)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Split groups into up to three columns, filled top-to-bottom in contiguous
    /// chunks so reading down each column follows menu order (File, Edit, …).
    private func columns() -> [[MenuGroup]] {
        let count = min(3, max(1, groups.count))
        let perColumn = (groups.count + count - 1) / count
        return stride(from: 0, to: groups.count, by: perColumn).map {
            Array(groups[$0 ..< min($0 + perColumn, groups.count)])
        }
    }
}

/// Borderless non-activating panel that can take key focus so Esc dismisses.
private final class KeyCluPanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

/// Owns the single overlay panel. Fixed-size hosting (measure `fittingSize`
/// once) per the macOS-26 crash rule. Caps the panel to the visible screen and
/// scrolls when a huge menu overflows; auto-dismisses on app switch (stale).
@MainActor
final class KeyCluOverlayController {
    private var panel: NSPanel?
    private var appSwitchObserver: NSObjectProtocol?

    var isVisible: Bool { panel?.isVisible ?? false }

    func present(appName: String, appIcon: NSImage?, groups: [MenuGroup]) {
        hide()

        // Measure the natural (unbounded) content size.
        let measurer = NSHostingView(rootView: KeyCluOverlayView(
            appName: appName, appIcon: appIcon, groups: groups))
        measurer.sizingOptions = []
        let natural = measurer.fittingSize

        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(origin: .zero, size: natural)
        let maxHeight = max(200, visible.height - 40)
        let needsScroll = natural.height > maxHeight
        let size = NSSize(width: natural.width, height: min(natural.height, maxHeight))

        let host = NSHostingView(rootView: KeyCluOverlayView(
            appName: appName, appIcon: appIcon, groups: groups, scrollable: needsScroll))
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: size)

        let panel = KeyCluPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.onCancel = { [weak self] in self?.hide() }
        panel.contentView = host

        // Center, then clamp fully on-screen so no row renders off the edge.
        var origin = NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2)
        origin.x = min(max(visible.minX + 8, origin.x), visible.maxX - size.width - 8)
        origin.y = min(max(visible.minY + 8, origin.y), visible.maxY - size.height - 8)
        panel.setFrameOrigin(origin)

        panel.makeKeyAndOrderFront(nil)
        self.panel = panel

        appSwitchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
    }

    func hide() {
        if let appSwitchObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(appSwitchObserver)
            self.appSwitchObserver = nil
        }
        panel?.orderOut(nil)
        panel = nil
    }
}
