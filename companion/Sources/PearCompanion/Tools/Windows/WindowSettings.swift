import Carbon.HIToolbox
import Foundation

/// Live per-tool settings for window management: which action sits on each
/// radial-ring slot, and which keyboard chord fires which action.
///
/// Both persist under a `windows.*` UserDefaults key and are read at use time,
/// so a rebind applies with no relaunch. `store` is injectable so persistence
/// round-trips can be tested without touching the real domain — same shape as
/// `ScratchpadSettings`, same chord encoding as `Prefs.hotkeyOverride`.
enum WindowSettings {
    enum Key {
        static let ringSlots = "windows.ringSlots"
        static func chord(_ id: String) -> String { "windows.chord.\(id)" }
    }

    /// A keyboard chord wired straight to an action — no ring, no pointer.
    /// `id` keys the persisted override, so it has to stay stable even if the
    /// chord or the label changes.
    struct ChordBinding: Identifiable, Equatable, Sendable {
        let id: String
        let action: WindowAction
        let chord: HotKeyChord
    }

    // MARK: - Defaults

    /// Each compass slot gets the zone that points the same way, so the ring
    /// needs no learning: flick right, the window goes right. The hub gets
    /// maximise because the middle is where the pointer already is when you just
    /// want the window as big as it goes.
    static let ringDefaults: [RingSlot: WindowAction] = [
        .top: .snap(WindowZoneMath.topHalf),
        .topTrailing: .snap(WindowZoneMath.topRightQuarter),
        .trailing: .snap(WindowZoneMath.rightHalf),
        .bottomTrailing: .snap(WindowZoneMath.bottomRightQuarter),
        .bottom: .snap(WindowZoneMath.bottomHalf),
        .bottomLeading: .snap(WindowZoneMath.bottomLeftQuarter),
        .leading: .snap(WindowZoneMath.leftHalf),
        .topLeading: .snap(WindowZoneMath.topLeftQuarter),
        .hub: .snap(WindowZoneMath.maximize),
    ]

    /// Control-Option plus the arrows, Return, C and Delete: the de-facto macOS
    /// snapping chords (Rectangle, Spectacle and Magnet all ship them), so
    /// muscle memory transfers in. Every one of them uses `controlKey|optionKey`,
    /// which is what keeps them clear of the app's own ⌃⇧-letter family —
    /// ⌃⇧S/F/W/T/C/P/K/N/Q/V are all already spoken for.
    static let chordDefaults: [ChordBinding] = [
        ChordBinding(
            id: "left-half", action: .snap(WindowZoneMath.leftHalf),
            chord: HotKeyChord(keyCode: kVK_LeftArrow, modifiers: snapModifiers, label: "⌃⌥←")),
        ChordBinding(
            id: "right-half", action: .snap(WindowZoneMath.rightHalf),
            chord: HotKeyChord(keyCode: kVK_RightArrow, modifiers: snapModifiers, label: "⌃⌥→")),
        ChordBinding(
            id: "top-half", action: .snap(WindowZoneMath.topHalf),
            chord: HotKeyChord(keyCode: kVK_UpArrow, modifiers: snapModifiers, label: "⌃⌥↑")),
        ChordBinding(
            id: "bottom-half", action: .snap(WindowZoneMath.bottomHalf),
            chord: HotKeyChord(keyCode: kVK_DownArrow, modifiers: snapModifiers, label: "⌃⌥↓")),
        ChordBinding(
            id: "maximize", action: .snap(WindowZoneMath.maximize),
            chord: HotKeyChord(keyCode: kVK_Return, modifiers: snapModifiers, label: "⌃⌥↩")),
        ChordBinding(
            id: "center", action: .center,
            chord: HotKeyChord(keyCode: kVK_ANSI_C, modifiers: snapModifiers, label: "⌃⌥C")),
        ChordBinding(
            id: "restore", action: .restore,
            chord: HotKeyChord(keyCode: kVK_Delete, modifiers: snapModifiers, label: "⌃⌥⌫")),
    ]

    static let snapModifiers = controlKey | optionKey

    // MARK: - Ring slots

    /// What a slot does. A persisted map wins; a slot missing from that map was
    /// cleared by the user; no map at all means the defaults. A token that no
    /// longer resolves — a zone id this build dropped — falls back to that slot's
    /// default rather than leaving a dead wedge on the ring.
    static func action(for slot: RingSlot, _ store: UserDefaults = .standard) -> WindowAction? {
        guard let stored = ringMap(store) else { return ringDefaults[slot] }
        guard let token = stored[slot.rawValue] else { return nil }
        return decode(token) ?? ringDefaults[slot]
    }

    /// Assigns a slot, or clears it with nil. Writes the whole map so that
    /// "cleared" is representable as an absent key.
    static func setAction(_ action: WindowAction?, for slot: RingSlot, _ store: UserDefaults = .standard) {
        var map = ringMap(store) ?? defaultRingMap
        map[slot.rawValue] = action.map(token(for:))
        store.set(map, forKey: Key.ringSlots)
    }

    static func resetRing(_ store: UserDefaults = .standard) {
        store.removeObject(forKey: Key.ringSlots)
    }

    /// Nil when nothing usable is stored: no value, a value that isn't a
    /// dictionary, or one holding anything but strings. All three mean "fall
    /// back to the defaults" — a mangled blob must not disable the ring.
    private static func ringMap(_ store: UserDefaults) -> [String: String]? {
        store.dictionary(forKey: Key.ringSlots) as? [String: String]
    }

    private static var defaultRingMap: [String: String] {
        ringDefaults.reduce(into: [:]) { $0[$1.key.rawValue] = token(for: $1.value) }
    }

    // MARK: - Chords

    /// Effective chords, in default order. A stored override replaces the
    /// default chord; an unparseable one falls back to it. A binding never
    /// vanishes, so a corrupt string costs the user a custom chord, not the
    /// action.
    static func chords(_ store: UserDefaults = .standard) -> [ChordBinding] {
        chordDefaults.map { binding in
            guard let chord = storedChord(binding.id, store) else { return binding }
            return ChordBinding(id: binding.id, action: binding.action, chord: chord)
        }
    }

    /// Rebinds one chord, or restores its default with nil.
    static func setChord(_ chord: HotKeyChord?, for id: String, _ store: UserDefaults = .standard) {
        guard let chord else {
            store.removeObject(forKey: Key.chord(id))
            return
        }
        store.set("\(chord.keyCode),\(chord.modifiers),\(chord.label)", forKey: Key.chord(id))
    }

    static func resetChords(_ store: UserDefaults = .standard) {
        for binding in chordDefaults { store.removeObject(forKey: Key.chord(binding.id)) }
    }

    /// What a keypress should do, or nil when no chord claims it. Matches
    /// keyCode plus modifiers only — labels are cosmetic.
    static func action(keyCode: Int, modifiers: Int, _ store: UserDefaults = .standard) -> WindowAction? {
        chords(store)
            .first { $0.chord.keyCode == keyCode && $0.chord.modifiers == modifiers }?
            .action
    }

    /// Same "keyCode,modifiers,label" encoding `Prefs` uses for tool hotkeys:
    /// labels never contain a comma, so a plain split is enough.
    private static func storedChord(_ id: String, _ store: UserDefaults) -> HotKeyChord? {
        guard let raw = store.string(forKey: Key.chord(id)) else { return nil }
        let parts = raw.split(separator: ",", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, let keyCode = Int(parts[0]), let modifiers = Int(parts[1]) else { return nil }
        return HotKeyChord(keyCode: keyCode, modifiers: modifiers, label: String(parts[2]))
    }

    // MARK: - Action tokens

    /// Persisted form of an action: the zone's id, or a reserved word for the
    /// actions that aren't a zone. No zone id collides with a reserved word, and
    /// `reservedWords` is asserted against the catalogue in tests.
    private static func token(for action: WindowAction) -> String {
        switch action {
        case .snap(let zone): zone.id
        case .center: "center"
        case .restore: "restore"
        case .minimize: "minimize"
        case .fullScreen: "full-screen"
        case .close: "close"
        case .quitApp: "quit-app"
        }
    }

    private static func decode(_ token: String) -> WindowAction? {
        switch token {
        case "center": .center
        case "restore": .restore
        case "minimize": .minimize
        case "full-screen": .fullScreen
        case "close": .close
        case "quit-app": .quitApp
        default: WindowZoneMath.zone(id: token).map(WindowAction.snap)
        }
    }
}
