import Foundation
import Observation

/// State and behavior for the menu-bar hider. Holds no `NSStatusItem` itself —
/// it drives a `MenuBarSurface`, so every decision here is testable without a
/// live status bar.
///
/// Multi-item model ported from Hidden Bar (MIT,
/// https://github.com/dwarvesf/hidden) `StatusBarController`: an always-visible
/// chevron toggle, a stretch separator to its left (the length trick), and an
/// optional always-hidden separator further left. The length-hide trick and the
/// generation-tagged auto-rehide were adapted from SaneBar (MIT,
/// https://github.com/sane-apps/SaneBar): a stale rehide timer can never fire
/// after a newer show/hide.
@MainActor
@Observable
final class MenuBarManager {
    // MARK: - Mechanism constants (pure — the length trick)

    /// Narrow slot that reveals a zone and leaves items to its left alone.
    static let expandedLength: CGFloat = 24
    /// Oversized slot that pushes every item to the separator's left off-screen.
    static let collapsedLength: CGFloat = 10_000

    /// Stretch-separator width for the collapsed (hidden) vs expanded state.
    static func separatorLength(collapsed: Bool) -> CGFloat {
        collapsed ? collapsedLength : expandedLength
    }

    /// Always-hidden-separator width: revealed shrinks it (zone shows), hidden
    /// grows it (zone stays off-screen even while the bar is expanded).
    static func alwaysHiddenSeparatorLength(revealed: Bool) -> CGFloat {
        revealed ? expandedLength : collapsedLength
    }

    /// Collapsed points left toward the hidden items ("reveal"); expanded
    /// points right toward the boundary ("collapse back").
    static func chevronSymbol(collapsed: Bool) -> String {
        collapsed ? "chevron.compact.left" : "chevron.compact.right"
    }

    /// Auto-rehide only makes sense while expanded and with a positive delay
    /// (0 == "Never"). Pure so the scheduling decision is unit-tested directly.
    static func shouldScheduleRehide(collapsed: Bool, autoRehideSeconds: Int) -> Bool {
        !collapsed && autoRehideSeconds > 0
    }

    /// Picker choices, seconds; 0 == Never.
    static let autoRehideOptions: [Int] = [0, 5, 10, 30]

    // MARK: - Observable state

    /// True == the hideable zone is collapsed off-screen. Defaults collapsed so
    /// the tool actually declutters on first run.
    private(set) var isCollapsed: Bool
    /// Seconds before an expanded bar auto-rehides; 0 == Never.
    private(set) var autoRehideSeconds: Int
    /// Whether the third "always hidden" separator/zone exists (Rule-B toggle).
    private(set) var alwaysHiddenEnabled: Bool
    /// Whether ⌥-click reveals everything, including the always-hidden zone.
    private(set) var optionRevealEnabled: Bool

    // MARK: - Internals (not observed)

    /// Transient: whether the always-hidden zone is peeked open right now. Not
    /// persisted — "always hidden" means hidden on every launch; ⌥ peeks, any
    /// collapse re-hides.
    @ObservationIgnored private var alwaysHiddenRevealed = false

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let keyPrefix: String
    @ObservationIgnored private var surface: MenuBarSurface?
    @ObservationIgnored private var rehideTask: Task<Void, Never>?
    /// Bumped on every schedule/cancel so a timer armed by an older state can
    /// never rehide after a newer show/hide (SaneBar's generation guard).
    @ObservationIgnored private var rehideGeneration: UInt64 = 0

    private var collapsedKey: String { "\(keyPrefix).isCollapsed" }
    private var autoRehideKey: String { "\(keyPrefix).autoRehideSeconds" }
    private var alwaysHiddenKey: String { "\(keyPrefix).alwaysHiddenEnabled" }
    private var optionRevealKey: String { "\(keyPrefix).optionRevealEnabled" }

    /// `defaults`/`keyPrefix` are injectable so tests never touch the real
    /// UserDefaults suite.
    init(defaults: UserDefaults = .standard, keyPrefix: String = "menuBar") {
        self.defaults = defaults
        self.keyPrefix = keyPrefix
        autoRehideSeconds = defaults.object(forKey: "\(keyPrefix).autoRehideSeconds") as? Int ?? 10
        isCollapsed = defaults.object(forKey: "\(keyPrefix).isCollapsed") as? Bool ?? true
        alwaysHiddenEnabled = defaults.object(forKey: "\(keyPrefix).alwaysHiddenEnabled") as? Bool ?? false
        optionRevealEnabled = defaults.object(forKey: "\(keyPrefix).optionRevealEnabled") as? Bool ?? true
    }

    // MARK: - Launch

    /// Production launch hook (called from `MenuBarTool.start()`, which only runs
    /// for enabled tools). Creates the status items visible, then defers a
    /// guarded collapse so the position guard reads real geometry.
    func installSurface(autosavePrefix: String = "com.pear.companion.menubar") {
        wire(StatusBarSurface(autosavePrefix: autosavePrefix))
        // Start fully visible: hide nothing before the status-item windows lay
        // out, or the position guard would read nil frames and skip the collapse.
        isCollapsed = false
        applyState()
        scheduleLaunchCollapse()
    }

    /// Teardown for a live disable (mirrors `installSurface`): reveal both zones
    /// so every hidden icon returns, then drop all status items. Removing the
    /// items alone un-hides everything (the inflated slots go away); revealing
    /// first keeps the transition clean and observable.
    func uninstallSurface() {
        isCollapsed = false
        alwaysHiddenRevealed = true
        applyState()
        persistCollapsed()
        cancelRehide()
        surface?.removeAll()
        surface = nil
    }

    /// Test seam: attach a fake and enforce the collapsed-on-launch default
    /// synchronously (the fake reports a valid position, so the guard passes).
    func launch(with surface: MenuBarSurface) {
        attach(surface)
        collapse()
    }

    /// Wire a surface (real or fake) and apply the current persisted state.
    func attach(_ surface: MenuBarSurface) {
        wire(surface)
        applyState()
    }

    private func wire(_ surface: MenuBarSurface) {
        self.surface = surface
        surface.onToggle = { [weak self] in self?.toggle() }
        surface.onOptionToggle = { [weak self] in self?.revealAll() }
        surface.setAlwaysHiddenEnabled(alwaysHiddenEnabled)
    }

    private func scheduleLaunchCollapse() {
        rehideGeneration &+= 1
        Task { @MainActor [weak self] in
            // Let the status-item windows lay out so the position guard reads
            // real geometry instead of nil frames (Hidden Bar defers its launch
            // collapse for the same reason).
            try? await Task.sleep(for: .milliseconds(250))
            self?.collapse()
        }
    }

    // MARK: - Visibility

    /// Single source of truth for the chevron click and the popover button, so
    /// the two surfaces stay in sync instead of fighting.
    func toggle() { isCollapsed ? expand() : collapse() }

    func expand() {
        isCollapsed = false
        applyState()
        persistCollapsed()
        scheduleRehideIfNeeded()
    }

    func collapse() {
        // Never hide the chevron: if the arrangement puts it left of the
        // separator, collapsing would push the only always-visible control
        // off-screen. Refuse and stay expanded (safe degrade). Port of Hidden
        // Bar's `isBtnSeparateValidPosition` guard — the strengthened self-hide
        // protection after 2.1.0 shipped an app that hid its own icon.
        guard surface?.isChevronRightOfSeparator ?? true else { return }
        isCollapsed = true
        // Collapsing hides everything, including any peeked always-hidden zone.
        alwaysHiddenRevealed = false
        applyState()
        persistCollapsed()
        cancelRehide()
    }

    /// ⌥-click: reveal everything, including the always-hidden zone. When the
    /// behavior is switched off, fall back to a plain toggle so the click still
    /// does something sensible.
    func revealAll() {
        guard optionRevealEnabled else { toggle(); return }
        isCollapsed = false
        if alwaysHiddenEnabled { alwaysHiddenRevealed = true }
        applyState()
        persistCollapsed()
        scheduleRehideIfNeeded()
    }

    func setAutoRehide(_ seconds: Int) {
        autoRehideSeconds = seconds
        defaults.set(seconds, forKey: autoRehideKey)
        // Re-arm against the new interval without changing what's visible; a
        // 0 ("Never") choice leaves nothing scheduled.
        cancelRehide()
        scheduleRehideIfNeeded()
    }

    /// Rule-B live toggle: add or drop the always-hidden separator/zone.
    func setAlwaysHiddenEnabled(_ enabled: Bool) {
        alwaysHiddenEnabled = enabled
        defaults.set(enabled, forKey: alwaysHiddenKey)
        if !enabled { alwaysHiddenRevealed = false }
        surface?.setAlwaysHiddenEnabled(enabled)
        applyState()
    }

    /// Rule-B live toggle: whether ⌥-click reveals all.
    func setOptionReveal(_ enabled: Bool) {
        optionRevealEnabled = enabled
        defaults.set(enabled, forKey: optionRevealKey)
    }

    private func applyState() {
        surface?.separatorLength = Self.separatorLength(collapsed: isCollapsed)
        surface?.setChevron(collapsed: isCollapsed)
        if alwaysHiddenEnabled {
            surface?.alwaysHiddenLength = Self.alwaysHiddenSeparatorLength(revealed: alwaysHiddenRevealed)
        }
    }

    private func persistCollapsed() {
        defaults.set(isCollapsed, forKey: collapsedKey)
    }

    // MARK: - Auto-rehide

    private func scheduleRehideIfNeeded() {
        guard Self.shouldScheduleRehide(collapsed: isCollapsed, autoRehideSeconds: autoRehideSeconds) else { return }
        let delay = autoRehideSeconds
        rehideGeneration &+= 1
        let generation = rehideGeneration
        rehideTask?.cancel()
        rehideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            // Only fire if still the current timer and still expanded — a
            // manual collapse or a newer schedule invalidates this one.
            guard generation == self.rehideGeneration, !self.isCollapsed else { return }
            self.collapse()
        }
    }

    private func cancelRehide() {
        rehideGeneration &+= 1
        rehideTask?.cancel()
        rehideTask = nil
    }
}
