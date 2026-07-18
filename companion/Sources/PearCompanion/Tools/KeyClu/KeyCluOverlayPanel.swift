import AppKit
import SwiftUI

/// The cheat-sheet contents: an app header, then each menu (File, Edit, …) as a
/// titled section, packed column-major into as many columns as fit the screen so
/// reading down then right follows the menu bar. Fixed-width columns keep the
/// glyphs aligned; long titles truncate rather than wrap. Fixed size overall
/// (see controller) so the hosting panel never drives its own sizing.
struct KeyCluOverlayView: View {
    let appName: String
    let appIcon: NSImage?
    let groups: [MenuGroup]
    /// Ceiling on columns, from the controller's screen-width measurement.
    var maxColumns: Int = 6
    /// Set when the packed content is still taller than the screen: wraps the
    /// grid in a ScrollView and lets the panel frame drive the height.
    var scrollable: Bool = false

    /// Shared with the controller so its width/clamp math matches the layout.
    static let columnWidth: CGFloat = 240
    static let columnGap: CGFloat = 32
    /// Rough per-column row budget used to choose the column count.
    private static let rowsPerColumn = 22

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if groups.isEmpty {
                Text("No shortcuts found")
                    .font(Theme.body)
                    .foregroundStyle(.secondary)
            } else if scrollable {
                ScrollView(.vertical) { grid }
            } else {
                grid
            }
        }
        .padding(22)
        .glassCard(cornerRadius: 18)
        .fixedSize(horizontal: true, vertical: !scrollable)
    }

    private var header: some View {
        HStack(spacing: 10) {
            if let appIcon {
                Image(nsImage: appIcon).resizable().frame(width: 24, height: 24)
            }
            Text(appName).font(Theme.title)
            Spacer(minLength: 32)
            Text("esc to close").font(Theme.rounded(12)).foregroundStyle(.tertiary)
        }
    }

    private var grid: some View {
        let cols = columns()
        return HStack(alignment: .top, spacing: 20) {
            ForEach(Array(cols.enumerated()), id: \.offset) { index, column in
                columnStack(column)
                    .overlay(alignment: .trailing) {
                        if index < cols.count - 1 {
                            // A subtle full-column separator, drawn in the gap.
                            // (A plain Divider collapses inside the fixed-size
                            // panel, so use an explicit column-height rule.)
                            Rectangle()
                                .fill(Color.primary.opacity(0.10))
                                .frame(width: 1)
                                .offset(x: 10)
                        }
                    }
            }
        }
    }

    private func columnStack(_ groups: [MenuGroup]) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                section(group)
            }
        }
        .frame(width: Self.columnWidth, alignment: .leading)
    }

    private func section(_ group: MenuGroup) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(group.title)
                .font(Theme.rounded(13, .semibold))
                .foregroundStyle(Theme.accent)
                .padding(.bottom, 4)
            ForEach(Array(group.shortcuts.enumerated()), id: \.offset) { _, shortcut in
                HStack(spacing: 16) {
                    Text(shortcut.title)
                        .font(Theme.body)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(shortcut.glyph)
                        .font(Theme.body)
                        .tracking(2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Pack sections column-major, balanced by row count, kept whole and in menu
    /// order (so reading down a column then moving right follows the menu bar).
    /// Column count scales with content but is capped to what fits the screen
    /// (`maxColumns`); anything still too tall scrolls vertically.
    private func columns() -> [[MenuGroup]] {
        let weights = groups.map { $0.shortcuts.count + 2 }  // header + gap ≈ 2 rows
        let total = weights.reduce(0, +)
        let wanted = max(1, Int((Double(total) / Double(Self.rowsPerColumn)).rounded(.up)))
        let count = min(max(1, maxColumns), wanted)
        let target = Int((Double(total) / Double(count)).rounded(.up))

        var result: [[MenuGroup]] = []
        var current: [MenuGroup] = []
        var height = 0
        for (index, group) in groups.enumerated() {
            if !current.isEmpty, height + weights[index] > target, result.count < count - 1 {
                result.append(current)
                current = []
                height = 0
            }
            current.append(group)
            height += weights[index]
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}

/// Borderless non-activating panel that can take key focus so Esc dismisses.
private final class KeyCluPanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

/// Owns the single overlay panel. Fixed-size hosting (measure `fittingSize`
/// once) per the macOS-26 crash rule. Chooses a column count that fits the
/// screen width, caps the panel to the visible frame, scrolls when a huge menu
/// still overflows, and auto-dismisses on app switch (stale).
@MainActor
final class KeyCluOverlayController {
    private var panel: NSPanel?
    private var appSwitchObserver: NSObjectProtocol?

    var isVisible: Bool { panel?.isVisible ?? false }

    func present(appName: String, appIcon: NSImage?, groups: [MenuGroup]) {
        hide()

        // The active screen — where the frontmost app and menu bar are, i.e.
        // where the user is looking. (Mouse-location screen drifted onto the
        // wrong display in multi-monitor setups.)
        let screen = NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        // How many fixed-width columns fit the visible width (with side margins).
        let margin: CGFloat = 24
        let columnStride = KeyCluOverlayView.columnWidth + KeyCluOverlayView.columnGap
        let available = visible.width - margin * 2 + KeyCluOverlayView.columnGap
        let maxColumns = max(1, Int(available / columnStride))

        // Measure the natural (unbounded) content size at that column count.
        let measurer = NSHostingView(rootView: KeyCluOverlayView(
            appName: appName, appIcon: appIcon, groups: groups, maxColumns: maxColumns))
        measurer.sizingOptions = []
        let natural = measurer.fittingSize

        let maxHeight = max(200, visible.height - 40)
        let needsScroll = natural.height > maxHeight
        let size = NSSize(width: natural.width, height: min(natural.height, maxHeight))

        let host = NSHostingView(rootView: KeyCluOverlayView(
            appName: appName, appIcon: appIcon, groups: groups,
            maxColumns: maxColumns, scrollable: needsScroll))
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

        // Centered on the active screen, nudged a little above the middle
        // (KeyClu-like). Clamp fully on-screen so no row renders off an edge.
        let centerY = visible.midY + visible.height * 0.06
        var origin = NSPoint(
            x: visible.midX - size.width / 2,
            y: centerY - size.height / 2)
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
