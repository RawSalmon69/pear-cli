import Foundation

/// Live settings for Clean Mode. Persisted under a `cleanmode.*` UserDefaults
/// key and read at use time (in `CleanModeController.enter()`), so a change
/// applies to the next entry with no relaunch. There is no auto-timeout —
/// Clean Mode exits only on Done (owner decision; the never-tapped mouse keeps
/// Done reachable).
enum CleanModeSettings {
    enum Key {
        static let lockKeyboard = "cleanmode.lockKeyboard"
    }

    /// Locking the keyboard is on by default; turning it off blanks the screens
    /// only and never taps the keyboard.
    static let defaultLockKeyboard = true

    /// Whether entering Clean Mode also locks the keyboard. Default on; when off
    /// the keyboard is never tapped and only the screens go black.
    static func lockKeyboard(_ store: UserDefaults = .standard) -> Bool {
        store.object(forKey: Key.lockKeyboard) == nil
            ? defaultLockKeyboard
            : store.bool(forKey: Key.lockKeyboard)
    }
}
