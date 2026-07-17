import Foundation

/// The eight quick toggles the Switches grid offers. Owner-locked list — no
/// more, no fewer. Each case carries its display metadata and whether it shows
/// in the grid on a fresh install.
///
/// `kind` splits stateful toggles (a live on/off the popover reads on open)
/// from momentary actions (fire once, no persistent state).
enum SystemSwitch: String, CaseIterable, Identifiable {
    case keepAwake
    case mute
    case screenSaver
    case lockScreen
    case screenTest
    case hideDesktop
    case showHidden
    case bigCursor

    var id: String { rawValue }

    enum Kind: Equatable {
        /// Reads a live on/off state; the tile shows a switch control.
        case toggle
        /// Fires once; the tile shows a button.
        case momentary
    }

    var kind: Kind {
        switch self {
        case .keepAwake, .mute, .hideDesktop, .showHidden, .bigCursor: .toggle
        case .screenSaver, .lockScreen, .screenTest: .momentary
        }
    }

    var title: String {
        switch self {
        case .keepAwake: "Keep Awake"
        case .mute: "Mute"
        case .screenSaver: "Screen Saver"
        case .lockScreen: "Lock Screen"
        case .screenTest: "Screen Test"
        case .hideDesktop: "Hide Desktop"
        case .showHidden: "Show Hidden"
        case .bigCursor: "Big Cursor"
        }
    }

    /// SF Symbol for the tile. All ship in the macOS 14 symbol set.
    var icon: String {
        switch self {
        case .keepAwake: "cup.and.saucer.fill"
        case .mute: "speaker.slash.fill"
        case .screenSaver: "sparkles"
        case .lockScreen: "lock.fill"
        case .screenTest: "display"
        case .hideDesktop: "square.grid.2x2.fill"
        case .showHidden: "eye.fill"
        case .bigCursor: "cursorarrow"
        }
    }

    /// Short verb shown on a momentary switch's button. Unused for toggles.
    var actionLabel: String {
        switch self {
        case .screenSaver: "Start"
        case .lockScreen: "Lock"
        case .screenTest: "Test"
        default: ""
        }
    }

    /// Whether the tile appears in the grid on a fresh install. The three
    /// switches that write a persistent, system-mutating `defaults` domain
    /// (Hide Desktop, Show Hidden, Big Cursor) default hidden; the transient
    /// ones default shown. Owner standing rule (Rule B).
    var defaultVisible: Bool {
        switch self {
        case .hideDesktop, .showHidden, .bigCursor: false
        default: true
        }
    }
}

/// Live per-switch visibility, persisted under a `switches.show.*` key and read
/// at use time so the grid re-renders with no relaunch. Mirrors the
/// `DockDoorSettings` accessor shape (presence = user chose; absence = default).
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
