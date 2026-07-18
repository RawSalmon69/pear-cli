import XCTest
import Carbon.HIToolbox

@testable import PearCompanion

final class KeyCluShortcutTests: XCTestCase {

    // MARK: - Modifier mask decoding

    func testModifierMaskDecoding() {
        XCTAssertEqual(ShortcutFormatting.modifierGlyphs(0), "⌘")       // command implied
        XCTAssertEqual(ShortcutFormatting.modifierGlyphs(1), "⇧⌘")      // shift
        XCTAssertEqual(ShortcutFormatting.modifierGlyphs(2), "⌥⌘")      // option
        XCTAssertEqual(ShortcutFormatting.modifierGlyphs(4), "⌃⌘")      // control
        XCTAssertEqual(ShortcutFormatting.modifierGlyphs(8), "")        // no command
        XCTAssertEqual(ShortcutFormatting.modifierGlyphs(7), "⌃⌥⇧⌘")    // ctrl+opt+shift+cmd
        XCTAssertEqual(ShortcutFormatting.modifierGlyphs(9), "⇧")       // shift, no command
    }

    // MARK: - Key glyph resolution

    func testKeyGlyphFromChar() {
        XCTAssertEqual(ShortcutFormatting.keyGlyph(char: "c", virtualKey: nil), "C")
        XCTAssertEqual(ShortcutFormatting.keyGlyph(char: ",", virtualKey: nil), ",")
    }

    func testKeyGlyphFromVirtualKeyWhenCharBlank() {
        XCTAssertEqual(ShortcutFormatting.keyGlyph(char: nil, virtualKey: kVK_Return), "↩")
        XCTAssertEqual(ShortcutFormatting.keyGlyph(char: " ", virtualKey: kVK_Space), "␣")
        XCTAssertEqual(ShortcutFormatting.keyGlyph(char: "", virtualKey: kVK_LeftArrow), "←")
        XCTAssertEqual(ShortcutFormatting.keyGlyph(char: nil, virtualKey: kVK_F1), "F1")
    }

    func testKeyGlyphNilWhenNoKey() {
        XCTAssertNil(ShortcutFormatting.keyGlyph(char: nil, virtualKey: nil))
        XCTAssertNil(ShortcutFormatting.keyGlyph(char: " ", virtualKey: nil))
        XCTAssertNil(ShortcutFormatting.keyGlyph(char: nil, virtualKey: 9999)) // unmapped
    }

    func testKeyGlyphMapsFunctionKeyChars() {
        // macOS reports arrow/function keys as U+F700-range private-use chars in
        // the menu cmd char (e.g. ⌥⌘↑ for "Select Split Above"). Map them to
        // glyphs instead of rendering a missing-glyph box.
        XCTAssertEqual(ShortcutFormatting.keyGlyph(char: "\u{F700}", virtualKey: nil), "↑")
        XCTAssertEqual(ShortcutFormatting.keyGlyph(char: "\u{F701}", virtualKey: nil), "↓")
        XCTAssertEqual(ShortcutFormatting.keyGlyph(char: "\u{F702}", virtualKey: nil), "←")
        XCTAssertEqual(ShortcutFormatting.keyGlyph(char: "\u{F703}", virtualKey: nil), "→")
        XCTAssertEqual(ShortcutFormatting.keyGlyph(char: "\u{F704}", virtualKey: nil), "F1")
        // An unmapped function-key char is skipped (not shown as a box), falling
        // back to the virtual key when present, else nil.
        XCTAssertNil(ShortcutFormatting.keyGlyph(char: "\u{F710}", virtualKey: nil))
        XCTAssertEqual(ShortcutFormatting.keyGlyph(char: "\u{F710}", virtualKey: kVK_Return), "↩")
    }

    func testKeyGlyphRejectsEmoji() {
        // macOS reports 🎤 / 🌐 for Start Dictation and Emoji & Symbols; those
        // render as out-of-place color emoji and aren't real typed shortcuts.
        XCTAssertNil(ShortcutFormatting.keyGlyph(char: "🎤", virtualKey: nil))
        XCTAssertNil(ShortcutFormatting.keyGlyph(char: "🌐", virtualKey: nil))
        // An emoji char still falls back to a real virtual key if present.
        XCTAssertEqual(ShortcutFormatting.keyGlyph(char: "🌐", virtualKey: kVK_Return), "↩")
    }

    func testFullGlyph() {
        XCTAssertEqual(ShortcutFormatting.glyph(char: "c", virtualKey: nil, modifiers: 0), "⌘C")
        XCTAssertEqual(ShortcutFormatting.glyph(char: nil, virtualKey: kVK_LeftArrow, modifiers: 0), "⌘←")
        XCTAssertEqual(ShortcutFormatting.glyph(char: nil, virtualKey: kVK_Return, modifiers: 1), "⇧⌘↩")
        XCTAssertNil(ShortcutFormatting.glyph(char: nil, virtualKey: nil, modifiers: 0))
    }

    // MARK: - Menu-tree walk

    /// A menu bar with an Apple menu, a File menu (Open ⌘O, a separator, and a
    /// disabled Close), and an Edit menu whose Find item has a Find submenu
    /// (Find Next ⌘G).
    private func sampleMenuBar() -> AXNode {
        AXNode(children: [
            AXNode(title: "Apple", children: [
                AXNode(title: "Force Quit…", cmdVirtualKey: kVK_Escape, cmdModifiers: 2),
            ]),
            AXNode(title: "File", children: [
                AXNode(title: "Open", cmdChar: "o"),
                AXNode(isSeparator: true),
                AXNode(title: "Close", cmdChar: "w", isEnabled: false),
                AXNode(title: "Print Preview"), // no shortcut
            ]),
            AXNode(title: "Edit", children: [
                AXNode(title: "Find", children: [
                    AXNode(title: "Find Next", cmdChar: "g"),
                ]),
            ]),
        ])
    }

    func testGroupsExcludeAppleAndEmptyMenus() {
        let groups = MenuShortcutReader().groups(from: sampleMenuBar())
        XCTAssertEqual(groups.map(\.title), ["File", "Edit"])
        XCTAssertFalse(groups.contains { $0.title == "Apple" })
    }

    func testGroupsSkipSeparatorsDisabledAndNoShortcut() {
        let groups = MenuShortcutReader().groups(from: sampleMenuBar())
        let file = groups.first { $0.title == "File" }
        XCTAssertEqual(file?.shortcuts, [Shortcut(title: "Open", glyph: "⌘O")])
    }

    func testSubmenuShortcutsFoldIntoTopGroup() {
        let groups = MenuShortcutReader().groups(from: sampleMenuBar())
        let edit = groups.first { $0.title == "Edit" }
        XCTAssertEqual(edit?.shortcuts, [Shortcut(title: "Find Next", glyph: "⌘G")])
    }
}
