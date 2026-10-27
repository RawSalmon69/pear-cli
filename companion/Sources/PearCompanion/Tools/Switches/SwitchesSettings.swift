import Foundation

/// The quick toggles the Switches grid offers. Owner-locked list — no more, no
/// fewer. Each case carries its display metadata and whether it shows in the
/// grid on a fresh install. (Screen Test was in the original list and was
/// removed at the owner's order after it hard-locked a machine: its fullscreen
/// key-window overlays never received keys/clicks from a non-activated
/// accessory app, leaving no way to dismiss them.)
///
/// `kind` splits stateful toggles (a live on/off the popover reads on open)
/// from momentary actions (fire once, no persistent state).
enum SystemSwitch: String, CaseIterable, Identifiable {
    case keepAwake
    case lidClosed
    case screenSaver
    case lockScreen
    case displayOff
    case hideDesktop
    case showHidden

    var id: String { rawValue }

    enum Kind: Equatable {
        /// Reads a live on/off state; the tile shows a switch control.
        case toggle
        /// Fires once; the tile shows a button.
        case momentary
    }

    var kind: Kind {
        switch self {
        case .keepAwake, .lidClosed, .hideDesktop, .showHidden: .toggle
        case .screenSaver, .lockScreen, .displayOff: .momentary
        }
    }

    var title: String {
        switch self {
        case .keepAwake: "Keep Awake"
        case .lidClosed: "Lid Closed"
        case .screenSaver: "Screen Saver"
        case .lockScreen: "Lock Screen"
        case .displayOff: "Display Off"
        case .hideDesktop: "Hide Desktop"
        case .showHidden: "Show Hidden"
        }
    }

    /// SF Symbol for the tile. All ship in the macOS 14 symbol set.
    var icon: String {
        switch self {
        case .keepAwake: "cup.and.saucer.fill"
        case .lidClosed: "laptopcomputer"
        case .screenSaver: "sparkles"
        case .lockScreen: "lock.fill"
        case .displayOff: "moon.fill"
        case .hideDesktop: "square.grid.2x2.fill"
        case .showHidden: "eye.fill"
        }
    }

    /// Short verb shown on a momentary switch's button. Unused for toggles.
    var actionLabel: String {
        switch self {
        case .screenSaver: "Start"
        case .lockScreen: "Lock"
        case .displayOff: "Turn Off"
        default: ""
        }
    }

    /// Whether the tile appears in the grid on a fresh install. The switches
    /// that write persistent, system-mutating state (Hide Desktop and Show
    /// Hidden via a `defaults` domain, Lid Closed via `pmset`) default hidden;
    /// the transient ones default shown. Owner standing rule (Rule B).
    var defaultVisible: Bool {
        switch self {
        case .lidClosed, .hideDesktop, .showHidden: false
        default: true
        }
    }
}

/// Live per-switch visibility, persisted under a `switches.show.*` key and read
/// at use time so the grid re-renders with no relaunch. Presence in the store
/// means the user chose; absence falls back to `defaultVisible`.
enum SwitchesSettings {
    static func showKey(_ toggle: SystemSwitch) -> String { "switches.show.\(toggle.rawValue)" }

    static func isVisible(_ toggle: SystemSwitch, _ store: UserDefaults = .standard) -> Bool {
        store.object(forKey: showKey(toggle)) == nil
            ? toggle.defaultVisible
            : store.bool(forKey: showKey(toggle))
    }

    static func setVisible(_ toggle: SystemSwitch, _ visible: Bool, _ store: UserDefaults = .standard) {
        store.set(visible, forKey: showKey(toggle))
    }

    /// The switches shown in the grid, in `allCases` (owner-locked) order.
    static func visibleSwitches(_ store: UserDefaults = .standard) -> [SystemSwitch] {
        SystemSwitch.allCases.filter { isVisible($0, store) }
    }
}

/// The custom Lid Closed timer: whole quarter-hours from 15 minutes to 24 hours.
/// Pure, so the popover's stepper and the stored value agree on one range.
enum LidTimer {
    static let step = 15
    static let range = 15...(24 * 60)

    /// Rounds to the nearest quarter-hour (7 past a step down, 8 up), then
    /// clamps into `range`, so any stored or passed value comes back usable.
    static func clamped(minutes: Int) -> Int {
        let bounded = min(max(minutes, 0), range.upperBound + step)
        let rounded = (bounded + step / 2) / step * step
        return min(max(rounded, range.lowerBound), range.upperBound)
    }

    /// "45 min", "1 h", "1 h 30 min", "24 h".
    static func label(minutes: Int) -> String {
        let hours = minutes / 60, rest = minutes % 60
        switch (hours, rest) {
        case (0, _): return "\(rest) min"
        case (_, 0): return "\(hours) h"
        default: return "\(hours) h \(rest) min"
        }
    }
}
