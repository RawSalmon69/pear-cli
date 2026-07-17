import AppKit
import SwiftUI

/// The cheat-sheet contents: app header, then each menu group as a titled block
/// of title/glyph rows, laid out across up to three balanced columns. Fixed
/// size (see controller) so the hosting panel never drives its own sizing.
struct KeyCluOverlayView: View {
    let appName: String
    let appIcon: NSImage?
    let groups: [MenuGroup]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.itemGap) {
            HStack(spacing: 8) {
                if let appIcon {
                    Image(nsImage: appIcon).resizable().frame(width: 20, height: 20)
                }
                Text(appName).font(Theme.emphasis)
                Spacer(minLength: 24)
                Text("esc to close").font(Theme.body).foregroundStyle(.tertiary)
            }

            if groups.isEmpty {
                Text("No shortcuts found").font(Theme.body).foregroundStyle(.secondary)
            } else {
                HStack(alignment: .top, spacing: 28) {
                    ForEach(Array(columns().enumerated()), id: \.offset) { _, column in
                        VStack(alignment: .leading, spacing: Theme.itemGap) {
                            ForEach(column, id: \.title) { group in
                                groupBlock(group)
                            }
                        }
                    }
                }
            }
        }
        .padding(Theme.cardPadding)
        .glassCard(cornerRadius: 16)
        .fixedSize()
    }

    private func groupBlock(_ group: MenuGroup) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(group.title).font(Theme.emphasis).foregroundStyle(Theme.accent)
            ForEach(group.shortcuts, id: \.title) { shortcut in
                HStack(spacing: 16) {
                    Text(shortcut.title).font(Theme.body)
                    Spacer(minLength: 12)
                    Text(shortcut.glyph)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Split groups round-robin into up to three columns so the sheet stays wide
    /// rather than tall.
    private func columns() -> [[MenuGroup]] {
        let count = min(3, max(1, groups.count))
        var buckets = Array(repeating: [MenuGroup](), count: count)
        for (index, group) in groups.enumerated() {
            buckets[index % count].append(group)
        }
        return buckets.filter { !$0.isEmpty }
    }
}

/// Borderless non-activating panel that can take key focus so Esc dismisses.
private final class KeyCluPanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

/// Owns the single overlay panel. Fixed-size hosting (measure `fittingSize`
/// once) per the macOS-26 crash rule. Auto-dismisses when the user switches to
/// another app, since the shown shortcuts would be stale.
@MainActor
final class KeyCluOverlayController {
    private var panel: NSPanel?
    private var appSwitchObserver: NSObjectProtocol?

    var isVisible: Bool { panel?.isVisible ?? false }

    func present(appName: String, appIcon: NSImage?, groups: [MenuGroup]) {
        hide()

        let host = NSHostingView(rootView: KeyCluOverlayView(
            appName: appName, appIcon: appIcon, groups: groups))
        let size = host.fittingSize

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

        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(
                x: visible.midX - size.width / 2,
                y: visible.midY - size.height / 2))
        }

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
