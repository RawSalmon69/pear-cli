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

    func testFullGlyph() {
        XCTAssertEqual(ShortcutFormatting.glyph(char: "c", virtualKey: nil, modifiers: 0), "⌘C")
        XCTAssertEqual(ShortcutFormatting.glyph(char: nil, virtualKey: kVK_LeftArrow, modifiers: 0), "⌘←")
        XCTAssertEqual(ShortcutFormatting.glyph(char: nil, virtualKey: kVK_Return, modifiers: 1), "⇧⌘↩")
        XCTAssertNil(ShortcutFormatting.glyph(char: nil, virtualKey: nil, modifiers: 0))
    }
}
