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

    /// macOS reports arrow / function keys in a menu's cmd char as private-use
    /// `NS*FunctionKey` scalars (U+F700…). Without mapping they render as
    /// missing-glyph boxes, so translate the common ones here.
    private static let functionKeyGlyphs: [UInt32: String] = [
        0xF700: "↑", 0xF701: "↓", 0xF702: "←", 0xF703: "→",       // arrows
        0xF704: "F1", 0xF705: "F2", 0xF706: "F3", 0xF707: "F4",
        0xF708: "F5", 0xF709: "F6", 0xF70A: "F7", 0xF70B: "F8",
        0xF70C: "F9", 0xF70D: "F10", 0xF70E: "F11", 0xF70F: "F12",
        0xF728: "⌦",   // forward delete
        0xF729: "↖",   // home
        0xF72B: "↘",   // end
        0xF72C: "⇞",   // page up
        0xF72D: "⇟",   // page down
    ]

    /// The key portion: map macOS function-key chars (arrows, F-keys, nav) to
    /// glyphs; otherwise a printable command char (uppercased); otherwise the
    /// virtual-key table; nil if none yields a displayable key. Anything in the
    /// U+F700+ private-use range that isn't a known function key — and emoji
    /// (🎤 / 🌐 for Start Dictation / Emoji & Symbols) — is skipped rather than
    /// shown as a missing-glyph box.
    static func keyGlyph(char: String?, virtualKey: Int?) -> String? {
        if let char, let scalar = char.unicodeScalars.first,
           !char.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let glyph = functionKeyGlyphs[scalar.value] {
                return glyph
            }
            if scalar.value < 0xF700 {
                return char.uppercased()
            }
            // U+F700+ (function-key private-use range) or emoji: not a typed
            // character — fall through so it never renders as a box.
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

/// Walks a menu-bar `AXNode` tree into display groups. The walk is pure over
/// `AXNode`; a live `MenuAXProviding` (Task 3) supplies the tree in production.
struct MenuShortcutReader {
    /// nil in tests, which call `groups(from:)` directly with a hand-built tree.
    var provider: (any MenuAXProviding)?

    init(provider: (any MenuAXProviding)? = nil) {
        self.provider = provider
    }

    /// Top menus → groups, skipping the system Apple menu and any menu with no
    /// shortcuts. Submenu shortcuts fold into their top-level group.
    func groups(from menuBar: AXNode) -> [MenuGroup] {
        menuBar.children.compactMap { top in
            guard top.title != "Apple" else { return nil }
            let shortcuts = collect(top.children)
            return shortcuts.isEmpty ? nil : MenuGroup(title: top.title, shortcuts: shortcuts)
        }
    }

    /// Depth-first collection of displayable shortcuts, recursing into submenus.
    private func collect(_ nodes: [AXNode]) -> [Shortcut] {
        var out: [Shortcut] = []
        for node in nodes {
            if node.isSeparator || node.title.isEmpty { continue }
            if node.isEnabled,
               let glyph = ShortcutFormatting.glyph(
                   char: node.cmdChar, virtualKey: node.cmdVirtualKey, modifiers: node.cmdModifiers)
            {
                out.append(Shortcut(title: node.title, glyph: glyph))
            }
            if !node.children.isEmpty {
                out += collect(node.children)
            }
        }
        return out
    }

    /// Production entry: read the app's menu bar via the injected provider, then
    /// run the pure walk. Empty when there is no provider or no menu bar.
    @MainActor
    func groups(forPID pid: pid_t) -> [MenuGroup] {
        guard let menuBar = provider?.menuBar(forPID: pid) else { return [] }
        return groups(from: menuBar)
    }
}

/// Supplies a menu-bar `AXNode` tree for a running app. Main-actor because AX
/// reads run on the main actor; the live implementation is Task 3.
@MainActor
protocol MenuAXProviding {
    func menuBar(forPID pid: pid_t) -> AXNode?
}
