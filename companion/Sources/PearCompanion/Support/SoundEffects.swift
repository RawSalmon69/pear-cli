import AppKit

/// Subtle audio feedback, CleanShot-style. Uses built-in system sounds so
/// there are no bundled assets. Honors the Prefs.soundsEnabled toggle.
enum SoundEffects {
    // The screenshot shutter is not here: captures run `screencapture`
    // unmuted, so macOS plays its native camera click.
    enum Cue {
        case copy      // something copied to clipboard
        case send      // note/photo sent to partner
        case done      // a longer action finished (clean, OCR)
        case discard   // dismissed / deleted

        var systemName: String {
            switch self {
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
