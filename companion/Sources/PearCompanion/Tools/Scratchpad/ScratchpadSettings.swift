import Foundation

/// Live per-tool settings for the Scratchpad. Both values persist under a
/// `scratchpad.*` UserDefaults key and are read at use time, so the header
/// popover's toggles apply with no relaunch. Mirrors `DockDoorSettings`'
/// read-at-use-time accessor shape.
enum ScratchpadSettings {
    enum Key {
        static let swipeEnabled = "scratchpad.swipeEnabled"
        static let linkDetection = "scratchpad.linkDetection"
        static let rememberPosition = "scratchpad.rememberPosition"
    }

    // Both features are on by default — parity with Antinote out of the box.
    static let defaultSwipeEnabled = true
    static let defaultLinkDetection = true
    /// Off = always spawn bottom-right; on = reopen where it was last closed.
    static let defaultRememberPosition = false

    // MARK: Read accessors (read at use time)

    /// Whether a horizontal two-finger swipe over the panel switches (or, past
    /// the last note, creates) notes.
    static func swipeEnabled(_ store: UserDefaults = .standard) -> Bool {
        store.object(forKey: Key.swipeEnabled) == nil
            ? defaultSwipeEnabled
            : store.bool(forKey: Key.swipeEnabled)
    }

    /// Whether URLs in a note are auto-detected and rendered as clickable links.
    static func linkDetection(_ store: UserDefaults = .standard) -> Bool {
        store.object(forKey: Key.linkDetection) == nil
            ? defaultLinkDetection
            : store.bool(forKey: Key.linkDetection)
    }

    /// Whether the panel reopens at its last-closed position (else bottom-right).
    static func rememberPosition(_ store: UserDefaults = .standard) -> Bool {
        store.object(forKey: Key.rememberPosition) == nil
            ? defaultRememberPosition
            : store.bool(forKey: Key.rememberPosition)
    }
}
