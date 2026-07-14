import AppKit

/// Subtle audio feedback, CleanShot-style. Uses built-in system sounds so
/// there are no bundled assets. Honors the Prefs.soundsEnabled toggle.
enum SoundEffects {
    enum Cue {
        case capture   // screenshot taken
        case copy      // something copied to clipboard
        case send      // note/photo sent to partner
        case done      // a longer action finished (clean, OCR)
        case discard   // dismissed / deleted

        var systemName: String {
            switch self {
            case .capture: return "Tink"
            case .copy: return "Pop"
            case .send: return "Submarine"
            case .done: return "Glass"
            case .discard: return "Bottle"
            }
        }
    }

    static func play(_ cue: Cue) {
        guard Prefs.soundsEnabled else { return }
        NSSound(named: cue.systemName)?.play()
    }
}
