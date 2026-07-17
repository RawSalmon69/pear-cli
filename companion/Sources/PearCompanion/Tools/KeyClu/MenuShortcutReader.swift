import Carbon.HIToolbox
import Foundation

/// One displayable shortcut: the menu item's title and its rendered glyph
/// string (e.g. "⇧⌘K").
struct Shortcut: Equatable {
    let title: String
    let glyph: String
}

/// A top-level menu (File, Edit, …) and the shortcuts found under it,
/// including those nested in its submenus.
struct MenuGroup: Equatable {
    let title: String
    let shortcuts: [Shortcut]
}

/// A plain value snapshot of one Accessibility menu element. The live provider
/// builds these from `AXUIElement`s; tests build them by hand. Keeping the walk
/// pure over `AXNode` means the parser needs no AX permission to test.
struct AXNode {
    var title: String = ""
    var cmdChar: String? = nil
    var cmdVirtualKey: Int? = nil
    var cmdModifiers: Int = 0
    var cmdGlyph: Int? = nil
    var isSeparator: Bool = false
    var isEnabled: Bool = true
    var children: [AXNode] = []
}

/// Renders AX menu-item key data into the glyph strings macOS shows in menus.
enum ShortcutFormatting {
    /// `AXMenuItemCmdModifiers` is the Carbon menu-modifier bitfield:
    /// bit0=Shift(1), bit1=Option(2), bit2=Control(4), bit3=NO Command(8).
    /// Command is present unless bit3 is set. Rendered order: ⌃⌥⇧⌘.
    static func modifierGlyphs(_ mask: Int) -> String {
        var out = ""
        if mask & 4 != 0 { out += "⌃" }
        if mask & 2 != 0 { out += "⌥" }
        if mask & 1 != 0 { out += "⇧" }
        if mask & 8 == 0 { out += "⌘" }
        return out
    }

    /// Common non-character keys, keyed by `kVK_*` virtual code.
    private static let virtualKeyGlyphs: [Int: String] = [
        kVK_Return: "↩", kVK_ANSI_KeypadEnter: "⌤", kVK_Tab: "⇥",
        kVK_Space: "␣", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_Escape: "⎋", kVK_LeftArrow: "←", kVK_RightArrow: "→",
        kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_Home: "↖", kVK_End: "↘",
        kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4",
        kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8",
        kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]

    /// The key portion: prefer a printable command char (uppercased); fall back
    /// to the virtual-key table; nil if neither yields a displayable key.
    static func keyGlyph(char: String?, virtualKey: Int?) -> String? {
        if let char, !char.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return char.uppercased()
        }
        if let virtualKey, let glyph = virtualKeyGlyphs[virtualKey] {
            return glyph
        }
        return nil
    }

    /// Full glyph string (modifiers + key), or nil when the item has no
    /// displayable shortcut.
    static func glyph(char: String?, virtualKey: Int?, modifiers: Int) -> String? {
        guard let key = keyGlyph(char: char, virtualKey: virtualKey) else { return nil }
        return modifierGlyphs(modifiers) + key
    }
}
