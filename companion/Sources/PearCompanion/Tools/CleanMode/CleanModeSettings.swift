import Foundation

/// Live settings for Clean Mode. Each value is persisted under a `cleanmode.*`
/// UserDefaults key and read at use time (in `CleanModeController.enter()`), so
/// a change applies to the next entry with no relaunch. Accessors fall back to
/// the default on an unset or out-of-set stored value, so a stray `defaults
/// write` can never leave Clean Mode with a zero-second timer or an invalid
/// duration.
enum CleanModeSettings {
    enum Key {
        static let timeout = "cleanmode.timeout"
        static let lockKeyboard = "cleanmode.lockKeyboard"
    }

    // Defaults.
    static let defaultTimeout = CleanModeTimeout.oneMinute
    /// Locking the keyboard is on by default; turning it off blanks the screens
    /// only and never taps the keyboard.
    static let defaultLockKeyboard = true

    // MARK: Read accessors (fall back on unset / invalid)

    /// The selected auto-exit timeout. Any value not in the picker's set falls
    /// back to the 60 s default.
    static func timeout(_ store: UserDefaults = .standard) -> CleanModeTimeout {
        guard store.object(forKey: Key.timeout) != nil else { return defaultTimeout }
        return CleanModeTimeout(rawValue: store.integer(forKey: Key.timeout)) ?? defaultTimeout
    }

    /// Auto-exit timeout in seconds — what the controller schedules.
    static func timeoutSeconds(_ store: UserDefaults = .standard) -> Int {
        timeout(store).rawValue
    }

    /// Whether entering Clean Mode also locks the keyboard. Default on; when off
    /// the keyboard is never tapped and only the screens go black.
    static func lockKeyboard(_ store: UserDefaults = .standard) -> Bool {
        store.object(forKey: Key.lockKeyboard) == nil
            ? defaultLockKeyboard
            : store.bool(forKey: Key.lockKeyboard)
    }
}

/// Auto-exit durations offered in the picker. The raw value is the timeout in
/// seconds, which is exactly what the countdown schedules.
enum CleanModeTimeout: Int, CaseIterable, Identifiable {
    case thirtySeconds = 30
    case oneMinute = 60
    case twoMinutes = 120
    case fiveMinutes = 300

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .thirtySeconds: "30 sec"
        case .oneMinute: "1 min"
        case .twoMinutes: "2 min"
        case .fiveMinutes: "5 min"
        }
    }
}
