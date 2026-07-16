import AppKit

/// The one moving part of the menu-bar hider, behind a protocol so the
/// manager's state logic can be tested without a live status bar.
///
/// Adapted from SaneBar (MIT, https://github.com/sane-apps/SaneBar), whose
/// `HidingService.StatusItemProtocol` abstracts `NSStatusItem` down to its
/// `length` for exactly this reason. Extended here with the chevron glyph and
/// a click callback so the whole separator is one injectable seam.
@MainActor
protocol MenuBarSeparating: AnyObject {
    /// Slot width. Grown huge to push everything to its left off-screen,
    /// shrunk back to reveal them again.
    var length: CGFloat { get set }
    /// Fired when the user clicks the separator in the menu bar.
    var onClick: (() -> Void)? { get set }
    /// Flip the chevron to reflect collapsed (hidden) vs expanded (shown).
    func setChevron(collapsed: Bool)
}

/// Concrete separator backed by a single `NSStatusItem` — the tool's only
/// always-on cost. Owns the status item's lifetime: it is removed from the
/// system status bar when this wrapper deinits.
///
/// Adapted from SaneBar (MIT). SaneBar toggles `NSStatusItem.length` between a
/// small visual width and 10 000 pt; macOS draws status items from the right,
/// so a 10 000 pt slot shoves every item to the separator's left past the
/// screen edge. There is no public API to enumerate or move other apps'
/// items, which is why every hider (SaneBar, Hidden Bar, Dozer) uses this
/// length trick.
@MainActor
final class StatusBarSeparator: MenuBarSeparating {
    private let item: NSStatusItem
    private let trampoline = ClickTrampoline()

    var onClick: (() -> Void)? {
        get { trampoline.handler }
        set { trampoline.handler = newValue }
    }

    var length: CGFloat {
        get { item.length }
        set { item.length = newValue }
    }

    init(autosaveName: String) {
        item = NSStatusBar.system.statusItem(withLength: MenuBarManager.expandedLength)
        // Keeps the separator's menu-bar position across launches so the user's
        // ⌘-drag arrangement of hidden/visible icons stays put.
        item.autosaveName = autosaveName
        if let button = item.button {
            button.target = trampoline
            button.action = #selector(ClickTrampoline.fire)
            button.imageScaling = .scaleProportionallyDown
        }
        setChevron(collapsed: true)
    }

    func setChevron(collapsed: Bool) {
        guard let button = item.button else { return }
        let symbol = MenuBarManager.chevronSymbol(collapsed: collapsed)
        let image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: collapsed ? "Reveal hidden menu bar icons" : "Hide menu bar icons")
        image?.isTemplate = true
        button.image = image
    }

    // Defensive teardown: if the manager (and thus this wrapper) is ever
    // released, drop the status item so it never lingers in the menu bar.
    // These wrappers are only ever retained on the main actor, so the final
    // release — and this deinit — runs there.
    deinit {
        MainActor.assumeIsolated {
            NSStatusBar.system.removeStatusItem(item)
        }
    }
}

/// Bridges the status-item button's Objective-C target/action to a Swift
/// closure without forcing the `@Observable` manager to be an `NSObject`.
@MainActor
private final class ClickTrampoline: NSObject {
    var handler: (() -> Void)?
    @objc func fire() { handler?() }
}
