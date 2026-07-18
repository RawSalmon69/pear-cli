import AppKit

/// The menu-bar hider's live surface, behind a protocol so the manager's state
/// logic can be tested without a real status bar.
///
/// Multi-item model ported from Hidden Bar (MIT,
/// https://github.com/dwarvesf/hidden) `StatusBarController`: an always-visible
/// chevron, a stretch separator to its left that does the length-hide trick,
/// and an optional always-hidden separator further left. The length trick
/// itself (grow a status item huge to shove everything to its left off-screen)
/// is the mechanism every hider uses — SaneBar (MIT), Hidden Bar, Dozer — since
/// there is no public API to enumerate or move other apps' items.
@MainActor
protocol MenuBarSurface: AnyObject {
    /// Chevron left-click — expand/collapse the hideable zone.
    var onToggle: (() -> Void)? { get set }
    /// Chevron ⌥-click — reveal everything, including the always-hidden zone.
    var onOptionToggle: (() -> Void)? { get set }
    /// Width of the stretch separator: huge to hide everything to its left,
    /// small to reveal it. (Hidden Bar's `btnSeparate`.)
    var separatorLength: CGFloat { get set }
    /// Width of the always-hidden separator when it exists (no-op otherwise):
    /// huge keeps the always-hidden zone hidden, small reveals it.
    /// (Hidden Bar's `btnAlwaysHidden`.)
    var alwaysHiddenLength: CGFloat { get set }
    /// Flip the chevron glyph to reflect collapsed (hidden) vs expanded (shown).
    func setChevron(collapsed: Bool)
    /// Show or hide the stretch separator's visible line. Hidden leaves the slot
    /// as a blank drag gap so the chevron alone marks the boundary; the hide
    /// mechanism (its length) is unaffected either way.
    func setDividerVisible(_ visible: Bool)
    /// True when the chevron sits to the right of the stretch separator, so a
    /// collapse can't push the only always-visible control off-screen. Port of
    /// Hidden Bar's `isBtnSeparateValidPosition`.
    var isChevronRightOfSeparator: Bool { get }
    /// Create or drop the always-hidden separator (live Rule-B toggle).
    func setAlwaysHiddenEnabled(_ enabled: Bool)
    /// Drop every status item this surface owns. Called on teardown; the manager
    /// reveals both zones first so nothing lingers hidden.
    func removeAll()
}

/// Concrete surface backed by three `NSStatusItem`s. Owns their lifetime: they
/// are removed from the system status bar on `removeAll()` and on deinit.
///
/// Ported from Hidden Bar (MIT, https://github.com/dwarvesf/hidden). The chevron
/// is created first and the separator second so macOS — which inserts each new
/// status item to the left of the previous — lands the separator left of the
/// chevron. That is the arrangement the collapse relies on: the chevron stays
/// right of the separator, so inflating the separator never hides the chevron.
@MainActor
final class StatusBarSurface: MenuBarSurface {
    private let chevron: NSStatusItem
    private let separator: NSStatusItem
    private var alwaysHidden: NSStatusItem?
    private let autosavePrefix: String
    private let trampoline = ChevronTrampoline()

    var onToggle: (() -> Void)? {
        get { trampoline.onToggle }
        set { trampoline.onToggle = newValue }
    }

    var onOptionToggle: (() -> Void)? {
        get { trampoline.onOptionToggle }
        set { trampoline.onOptionToggle = newValue }
    }

    var separatorLength: CGFloat {
        get { separator.length }
        set { separator.length = newValue }
    }

    var alwaysHiddenLength: CGFloat = MenuBarManager.collapsedLength {
        didSet { alwaysHidden?.length = alwaysHiddenLength }
    }

    init(autosavePrefix: String) {
        self.autosavePrefix = autosavePrefix
        // Seed first-run positions near the right edge so the items spawn beside
        // the clock rather than at the far left — which on a crowded, notched bar
        // is behind the notch, leaving the dividers invisible (owner report).
        // Larger offset == further left, so chevron sits rightmost, the stretch
        // separator to its left, the always-hidden zone further left still.
        // Re-pinned on every install (see seedPosition) so a disable→re-enable
        // always restores this safe order instead of a stale persisted one.
        Self.seedPosition("\(autosavePrefix).chevron", 100)
        Self.seedPosition("\(autosavePrefix).separator", 130)

        chevron = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        separator = NSStatusBar.system.statusItem(withLength: MenuBarManager.expandedLength)

        // Keep each item's menu-bar position across launches so the user's
        // ⌘-drag arrangement of hidden/visible icons stays put.
        chevron.autosaveName = "\(autosavePrefix).chevron"
        separator.autosaveName = "\(autosavePrefix).separator"

        // A ⌘-drag off the bar is persisted by macOS via autosaveName and would
        // leave the app's controls unreachable; force our items back on every
        // launch. (Hidden Bar's `restoreRemovedStatusItems`.)
        chevron.isVisible = true
        separator.isVisible = true

        if let button = separator.button {
            button.image = Self.dividerImage()
            button.imageScaling = .scaleProportionallyDown
        }
        if let button = chevron.button {
            button.target = trampoline
            button.action = #selector(ChevronTrampoline.fire)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imageScaling = .scaleProportionallyDown
        }
        setChevron(collapsed: true)
    }

    func setChevron(collapsed: Bool) {
        guard let button = chevron.button else { return }
        let symbol = MenuBarManager.chevronSymbol(collapsed: collapsed)
        let image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: collapsed ? "Reveal hidden menu bar icons" : "Hide menu bar icons")
        image?.isTemplate = true
        button.image = image
    }

    func setDividerVisible(_ visible: Bool) {
        // Only the glyph changes; the separator keeps its length, so it stays a
        // functional (if blank) drag boundary when hidden.
        separator.button?.image = visible ? Self.dividerImage() : nil
    }

    /// Pins one of the hider's OWN status items to its bar position (offset from
    /// the right edge) via the private-but-stable `NSStatusItem Preferred
    /// Position` default macOS reads for an autosaved item.
    ///
    /// Written on EVERY install, not just first run. These three items (chevron,
    /// stretch separator, always-hidden) are Pear's own boundary controls, and
    /// the whole safety of the length-hide trick depends on their order
    /// (separator left of chevron left of Pear's main icon). A disable→re-enable
    /// used to leave a stale position persisted from the prior session (measured
    /// while the separator was inflated, or shuffled by removeStatusItem), which
    /// let the recreated separator land right of the main icon and swallow Pear's
    /// own icon. Re-pinning each install re-establishes the known-good order that
    /// first-enable produces, and repairs installs already broken this way. The
    /// trade-off — a user's ⌘-drag of the chevron/separator itself snaps back —
    /// is worth never hiding the app's own icon; OTHER apps' icons are untouched.
    private static func seedPosition(_ autosaveName: String, _ offsetFromRight: CGFloat) {
        let key = "NSStatusItem Preferred Position \(autosaveName)"
        UserDefaults.standard.set(offsetFromRight, forKey: key)
    }

    var isChevronRightOfSeparator: Bool {
        // Compare the status-item backing-window origins (Hidden Bar's
        // `getOrigin`). If geometry isn't readable yet, refuse to treat the
        // arrangement as valid — the manager stays expanded until layout settles.
        guard let chevronX = chevron.button?.window?.frame.origin.x,
              let separatorX = separator.button?.window?.frame.origin.x else { return false }
        return chevronX >= separatorX
    }

    func setAlwaysHiddenEnabled(_ enabled: Bool) {
        if enabled {
            guard alwaysHidden == nil else { return }
            // Further left than the stretch separator, still seeded off the right
            // edge so it doesn't spawn behind the notch on a crowded bar.
            Self.seedPosition("\(autosavePrefix).alwaysHidden", 160)
            let item = NSStatusBar.system.statusItem(withLength: alwaysHiddenLength)
            item.autosaveName = "\(autosavePrefix).alwaysHidden"
            item.isVisible = true
            if let button = item.button {
                button.image = Self.dividerImage()
                button.appearsDisabled = true
                button.imageScaling = .scaleProportionallyDown
            }
            alwaysHidden = item
        } else if let item = alwaysHidden {
            NSStatusBar.system.removeStatusItem(item)
            alwaysHidden = nil
        }
    }

    func removeAll() {
        for item in [chevron, separator, alwaysHidden].compactMap({ $0 }) {
            NSStatusBar.system.removeStatusItem(item)
        }
        alwaysHidden = nil
    }

    // Defensive teardown: if this wrapper is ever released without an explicit
    // removeAll(), drop the status items so none linger in the menu bar. These
    // wrappers live only on the main actor, so the final release runs there.
    deinit {
        MainActor.assumeIsolated {
            removeAll()
        }
    }

    /// A thin vertical line the user can see and ⌘-drag icons across, template
    /// so macOS tints it for light/dark/active states. (Hidden Bar's
    /// `imgIconLine`, drawn programmatically like `MenuBarIcon`.)
    private static func dividerImage() -> NSImage {
        let size = NSSize(width: 6, height: 16)
        let image = NSImage(size: size, flipped: false) { rect in
            let line = NSBezierPath(rect: NSRect(x: rect.midX - 0.5, y: 2, width: 1, height: rect.height - 4))
            NSColor.black.setFill()
            line.fill()
            return true
        }
        image.isTemplate = true
        return image
    }
}

/// Bridges the chevron button's Objective-C target/action to Swift closures
/// without forcing the `@Observable` manager to be an `NSObject`. Reads the
/// current event's ⌥ modifier to split left-click (toggle) from ⌥-click (reveal
/// all), the same split Hidden Bar makes in `btnExpandCollapsePressed`.
@MainActor
private final class ChevronTrampoline: NSObject {
    var onToggle: (() -> Void)?
    var onOptionToggle: (() -> Void)?

    @objc func fire() {
        let optionDown = NSApp.currentEvent?.modifierFlags.contains(.option) ?? false
        if optionDown { onOptionToggle?() } else { onToggle?() }
    }
}
