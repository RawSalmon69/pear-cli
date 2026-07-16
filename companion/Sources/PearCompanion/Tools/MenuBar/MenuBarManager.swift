import Foundation
import Observation

/// State and behavior for the menu-bar hider. Holds no `NSStatusItem` itself —
/// it drives a `MenuBarSeparating`, so every decision here is testable without
/// a live status bar.
///
/// Mechanism adapted from SaneBar (MIT, https://github.com/sane-apps/SaneBar).
/// SaneBar's `HidingService` toggles the separator's length between a small
/// visual width and 10 000 pt to hide/show everything to its left, and arms an
/// auto-rehide via a generation-tagged task so a stale timer can never fire
/// after a newer show/hide. Both are mirrored below.
@MainActor
@Observable
final class MenuBarManager {
    // MARK: - Mechanism constants (pure — the SaneBar length trick)

    /// Narrow slot that reveals the chevron and leaves items to its left alone.
    static let expandedLength: CGFloat = 24
    /// Oversized slot that pushes every item to the separator's left off-screen.
    static let collapsedLength: CGFloat = 10_000

    static func separatorLength(collapsed: Bool) -> CGFloat {
        collapsed ? collapsedLength : expandedLength
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

    /// True == hidden icons collapsed off-screen. Defaults collapsed so the
    /// tool actually declutters on first run.
    private(set) var isCollapsed: Bool
    /// Seconds before an expanded bar auto-rehides; 0 == Never.
    private(set) var autoRehideSeconds: Int

    // MARK: - Internals (not observed)

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let keyPrefix: String
    @ObservationIgnored private var separator: MenuBarSeparating?
    @ObservationIgnored private var rehideTask: Task<Void, Never>?
    /// Bumped on every schedule/cancel so a timer armed by an older state can
    /// never rehide after a newer show/hide (SaneBar's generation guard).
    @ObservationIgnored private var rehideGeneration: UInt64 = 0

    private var collapsedKey: String { "\(keyPrefix).isCollapsed" }
    private var autoRehideKey: String { "\(keyPrefix).autoRehideSeconds" }

    /// `defaults`/`keyPrefix` are injectable so tests never touch the real
    /// UserDefaults suite.
    init(defaults: UserDefaults = .standard, keyPrefix: String = "menuBar") {
        self.defaults = defaults
        self.keyPrefix = keyPrefix
        autoRehideSeconds = defaults.object(forKey: "\(keyPrefix).autoRehideSeconds") as? Int ?? 10
        isCollapsed = defaults.object(forKey: "\(keyPrefix).isCollapsed") as? Bool ?? true
    }

    // MARK: - Launch

    /// Production launch hook (called from `MenuBarTool.start()`, which only
    /// runs for enabled tools). Creates the single system status item and runs
    /// the launch sequence.
    func installSeparator(autosaveName: String = "com.pear.companion.menubar.separator") {
        launch(with: StatusBarSeparator(autosaveName: autosaveName))
    }

    /// Teardown for a live disable (mirrors `installSeparator`): reveal the
    /// hidden icons first so they come back on-screen, then drop the status
    /// item entirely and release the separator. A later `installSeparator()`
    /// creates a fresh one and re-runs the collapse-on-launch sequence.
    func uninstallSeparator() {
        expand()
        cancelRehide()
        separator?.removeFromStatusBar()
        separator = nil
    }

    /// Attach the separator and enforce the collapsed-on-launch default.
    ///
    /// SaneBar collapses on launch rather than restoring a persisted expanded
    /// state: leaving icons revealed on every launch would defeat the tool, so
    /// a quit-while-expanded session comes back collapsed. Factored out from
    /// `installSeparator` so tests can drive the full launch path with a fake
    /// separator and never construct an `NSStatusItem`.
    func launch(with separator: MenuBarSeparating) {
        attach(separator)
        collapse()
    }

    /// Wire a separator (real or test fake) and apply the current state to it.
    func attach(_ separator: MenuBarSeparating) {
        self.separator = separator
        separator.onClick = { [weak self] in self?.toggle() }
        applyState()
    }

    // MARK: - Visibility

    /// Single source of truth for both the in-bar separator click and the
    /// popover's button, so the two surfaces stay in sync instead of fighting.
    func toggle() { isCollapsed ? expand() : collapse() }

    func expand() {
        isCollapsed = false
        applyState()
        persistCollapsed()
        scheduleRehideIfNeeded()
    }

    func collapse() {
        isCollapsed = true
        applyState()
        persistCollapsed()
        cancelRehide()
    }

    func setAutoRehide(_ seconds: Int) {
        autoRehideSeconds = seconds
        defaults.set(seconds, forKey: autoRehideKey)
        // Re-arm against the new interval without changing what's visible; a
        // 0 ("Never") choice leaves nothing scheduled.
        cancelRehide()
        scheduleRehideIfNeeded()
    }

    private func applyState() {
        separator?.length = Self.separatorLength(collapsed: isCollapsed)
        separator?.setChevron(collapsed: isCollapsed)
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
