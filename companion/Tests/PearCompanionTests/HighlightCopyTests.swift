import AppKit
import XCTest

@testable import PearCompanion

/// Records what a highlight would have put on the clipboard. Nothing here
/// touches `NSPasteboard.general`: the real pasteboard is the developer's, and
/// the decision logic is the part worth testing.
@MainActor
private final class FakePasteboard: SelectionPasteboard {
    var currentText: String?
    private(set) var writes: [String] = []

    init(currentText: String? = nil) {
        self.currentText = currentText
    }

    func write(_ text: String) {
        writes.append(text)
        currentText = text
    }
}

/// Counts how many times the engine actually asked Accessibility for the
/// selection — the cost a plain click must not pay.
@MainActor
private final class CountingReader {
    var selection: FocusedSelection?
    private(set) var reads = 0

    init(_ selection: FocusedSelection?) {
        self.selection = selection
    }

    func read() -> FocusedSelection? {
        reads += 1
        return selection
    }
}

private let otherPID: pid_t = 4242
private let ownPID: pid_t = 99

@MainActor
final class HighlightCopyTests: XCTestCase {

    private func engine(
        _ reader: CountingReader, _ pasteboard: FakePasteboard
    ) -> HighlightCopyEngine {
        HighlightCopyEngine(
            readSelection: { reader.read() }, pasteboard: pasteboard, ownPID: ownPID)
    }

    /// A drag: down here, up 50 points away.
    private func drag(_ engine: HighlightCopyEngine) {
        engine.mouseDown(at: CGPoint(x: 10, y: 10))
        engine.mouseUp(at: CGPoint(x: 60, y: 10), clickCount: 1)
    }

    // MARK: - Secure fields

    func testSecureFieldIsNeverCopiedEvenWhenItHandsOverText() {
        // The live reader never reads a password field's selection, but the
        // policy must refuse it independently: one lenient reader must not be
        // able to leak a password onto the pasteboard.
        let secure = FocusedSelection(text: "hunter2", isSecure: true, pid: otherPID)
        XCTAssertNil(
            HighlightCopyEngine.textToCopy(secure, ownPID: ownPID, current: nil))

        let reader = CountingReader(secure)
        let pasteboard = FakePasteboard(currentText: "keep me")
        drag(engine(reader, pasteboard))
        XCTAssertEqual(reader.reads, 1)
        XCTAssertEqual(pasteboard.writes, [])
        XCTAssertEqual(pasteboard.currentText, "keep me")
    }

    func testSecureIsDetectedByRoleAndBySubrole() {
        // Carbon-era / web secure fields report it as the role…
        XCTAssertTrue(AXSelectionReader.isSecure(role: "AXSecureTextField", subrole: nil))
        // …AppKit's NSSecureTextField as the subrole of a plain text field.
        XCTAssertTrue(
            AXSelectionReader.isSecure(role: "AXTextField", subrole: "AXSecureTextField"))
        XCTAssertFalse(AXSelectionReader.isSecure(role: "AXTextField", subrole: nil))
        XCTAssertFalse(
            AXSelectionReader.isSecure(role: "AXTextArea", subrole: "AXStandardWindow"))
        // The constant both checks compare against is the string macOS uses.
        XCTAssertEqual(kAXSecureTextFieldSubrole, "AXSecureTextField")
    }

    // MARK: - Nothing selected

    func testEmptyAndWhitespaceSelectionsLeaveTheClipboardAlone() {
        for selected in ["", "   ", "\n\t  \n"] {
            let reader = CountingReader(
                FocusedSelection(text: selected, isSecure: false, pid: otherPID))
            let pasteboard = FakePasteboard(currentText: "keep me")
            drag(engine(reader, pasteboard))
            XCTAssertEqual(pasteboard.writes, [], "wrote for \(selected.debugDescription)")
            XCTAssertEqual(pasteboard.currentText, "keep me")
        }
    }

    func testAnUnreadableSelectionWritesNothing() {
        // Accessibility not granted, nothing focused, or an app that will not
        // answer: no selection, no write.
        let reader = CountingReader(nil)
        let pasteboard = FakePasteboard(currentText: "keep me")
        drag(engine(reader, pasteboard))
        XCTAssertEqual(pasteboard.writes, [])
    }

    // MARK: - Redundant writes

    func testRepeatingWhatIsAlreadyOnThePasteboardWritesNothing() {
        let reader = CountingReader(
            FocusedSelection(text: "already here", isSecure: false, pid: otherPID))
        let pasteboard = FakePasteboard(currentText: "already here")
        drag(engine(reader, pasteboard))
        XCTAssertEqual(pasteboard.writes, [])
    }

    // MARK: - Pear's own windows

    func testSelectingInsidePearIsSkippedByPID() {
        let reader = CountingReader(
            FocusedSelection(text: "our own text", isSecure: false, pid: ownPID))
        let pasteboard = FakePasteboard()
        drag(engine(reader, pasteboard))
        XCTAssertEqual(pasteboard.writes, [])
    }

    // MARK: - Click vs. selection gesture

    func testPlainSingleClickReadsNoSelectionAtAll() {
        let reader = CountingReader(
            FocusedSelection(text: "not selected by this", isSecure: false, pid: otherPID))
        let pasteboard = FakePasteboard()
        let engine = engine(reader, pasteboard)
        engine.mouseDown(at: CGPoint(x: 10, y: 10))
        // A shaky hand moves a point or two; that is still a click.
        engine.mouseUp(at: CGPoint(x: 11, y: 11), clickCount: 1)
        XCTAssertEqual(reader.reads, 0)
        XCTAssertEqual(pasteboard.writes, [])
    }

    func testMouseUpWithNoMatchingDownIsTreatedAsAClick() {
        // The monitors can be installed mid-drag; without a down point there is
        // no evidence of a drag, so the safe reading is "click".
        let reader = CountingReader(
            FocusedSelection(text: "text", isSecure: false, pid: otherPID))
        let pasteboard = FakePasteboard()
        engine(reader, pasteboard).mouseUp(at: CGPoint(x: 60, y: 10), clickCount: 1)
        XCTAssertEqual(reader.reads, 0)
    }

    func testADragReadsTheSelectionAndCopiesIt() {
        let reader = CountingReader(
            FocusedSelection(text: "dragged over this", isSecure: false, pid: otherPID))
        let pasteboard = FakePasteboard(currentText: "old")
        drag(engine(reader, pasteboard))
        XCTAssertEqual(reader.reads, 1)
        XCTAssertEqual(pasteboard.writes, ["dragged over this"])
    }

    func testADoubleClickReadsTheSelectionAndCopiesIt() {
        let reader = CountingReader(
            FocusedSelection(text: "word", isSecure: false, pid: otherPID))
        let pasteboard = FakePasteboard()
        let engine = engine(reader, pasteboard)
        // First click of the pair is a plain click and costs nothing…
        engine.mouseDown(at: CGPoint(x: 10, y: 10))
        engine.mouseUp(at: CGPoint(x: 10, y: 10), clickCount: 1)
        XCTAssertEqual(reader.reads, 0)
        // …the second selects a word, which is worth a look.
        engine.mouseDown(at: CGPoint(x: 10, y: 10))
        engine.mouseUp(at: CGPoint(x: 10, y: 10), clickCount: 2)
        XCTAssertEqual(reader.reads, 1)
        XCTAssertEqual(pasteboard.writes, ["word"])
    }

    func testATripleClickCopiesTheLine() {
        let reader = CountingReader(
            FocusedSelection(text: "a whole line of it", isSecure: false, pid: otherPID))
        let pasteboard = FakePasteboard()
        let engine = engine(reader, pasteboard)
        engine.mouseDown(at: CGPoint(x: 10, y: 10))
        engine.mouseUp(at: CGPoint(x: 10, y: 10), clickCount: 3)
        XCTAssertEqual(pasteboard.writes, ["a whole line of it"])
    }

    // MARK: - Invisible to the clipboard history

    func testTheWriteIsInvisibleToTheClipboardHistory() {
        let types = HighlightCopy.payload(for: "highlighted").map(\.type.rawValue)
        XCTAssertTrue(types.contains("org.nspasteboard.AutoGeneratedType"))
        XCTAssertFalse(
            ClipboardHistoryService.mayRecord(types: types),
            "a highlight must never enter the clipboard history")
        // Not vacuous: the same text without the marker would be recorded.
        XCTAssertTrue(ClipboardHistoryService.mayRecord(types: [NSPasteboard.PasteboardType.string.rawValue]))
        // The text itself is still on the pasteboard, so ⌘V still works.
        XCTAssertEqual(
            HighlightCopy.payload(for: "highlighted").first?.value, "highlighted")
    }

    // MARK: - Lifecycle

    func testStopRemovesEveryMonitorItInstalled() {
        var installed: [ObjectIdentifier] = []
        var removed: [ObjectIdentifier] = []
        let monitor = GlobalMouseMonitor(
            add: { _, _ in
                let token = NSObject()
                installed.append(ObjectIdentifier(token))
                return token
            },
            remove: { token in removed.append(ObjectIdentifier(token as AnyObject)) })

        let tool = HighlightCopyTool(
            engine: engine(CountingReader(nil), FakePasteboard()), monitor: monitor)
        XCTAssertFalse(tool.isWatching)

        tool.start()
        XCTAssertTrue(tool.isWatching)
        XCTAssertEqual(installed.count, 2, "one monitor for mouse-down, one for mouse-up")
        // Idempotent: the registry can activate twice.
        tool.start()
        XCTAssertEqual(installed.count, 2)

        tool.stop()
        XCTAssertFalse(tool.isWatching)
        XCTAssertEqual(removed, installed)
        // And a second stop is harmless.
        tool.stop()
        XCTAssertEqual(removed, installed)
    }

    // MARK: - The confirmation snippet

    func testAShortSelectionShowsWhole() {
        XCTAssertEqual(HighlightCopy.snippet(for: "hello"), "hello")
    }

    /// A multi-line selection still has to read as one line in a one-line toast.
    func testAMultiLineSelectionCollapsesToOneLine() {
        XCTAssertEqual(HighlightCopy.snippet(for: "  one\n\ttwo   three  "), "one two three")
    }

    /// The toast sizes itself to its text: without this the panel would be as
    /// wide as the paragraph.
    func testALongSelectionIsElided() {
        let snippet = HighlightCopy.snippet(for: String(repeating: "ab", count: 200))
        XCTAssertEqual(snippet.count, HighlightCopy.snippetLimit + 1)
        XCTAssertTrue(snippet.hasSuffix("\u{2026}"))
    }

    func testTheToolIsOffByDefault() {
        // It rewrites the clipboard whenever you drag across text; that ships
        // opt-in, like every other system-touching tool here.
        XCTAssertFalse(HighlightCopyTool().defaultEnabled)
    }
}
