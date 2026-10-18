import XCTest
import AppKit
@testable import PearCompanion

/// The shared close rule for standard windows, and the Window Shot / Windows
/// icon split.
@MainActor
final class StandardWindowTests: XCTestCase {
    /// Stands in for an on-screen window without ordering one in.
    private final class FakeWindow: NSWindow {
        var shown = true
        override var isVisible: Bool { shown }
    }

    private func window(_ style: NSWindow.StyleMask, visible: Bool = true) -> FakeWindow {
        let window = FakeWindow(contentRect: .zero, styleMask: style, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.shown = visible
        return window
    }

    func testTheClosingWindowAloneIsTheLast() {
        let closing = window([.titled, .closable])
        XCTAssertFalse(StandardWindow.othersOpen(besides: closing, in: [closing]))
    }

    func testAnotherVisibleTitledWindowKeepsPearRegular() {
        let closing = window([.titled, .closable])
        let disk = window([.titled, .closable, .miniaturizable, .resizable])
        XCTAssertTrue(StandardWindow.othersOpen(besides: closing, in: [closing, disk]))
    }

    func testHiddenAndBorderlessWindowsDoNotCount() {
        let closing = window([.titled, .closable])
        let hidden = window([.titled, .closable], visible: false)
        let card = window([.borderless, .nonactivatingPanel])
        XCTAssertFalse(StandardWindow.othersOpen(besides: closing, in: [closing, hidden, card]))
    }

    func testWindowShotIconDiffersFromWindowsAndExists() {
        let shot = ScreenshotTool(mode: .window, messaging: MockMessagingService()).icon
        XCTAssertNotEqual(shot, WindowsTool().icon)
        XCTAssertNotEqual(shot, PanelTool().icon)
        XCTAssertNotNil(NSImage(systemSymbolName: shot, accessibilityDescription: nil))
    }
}
