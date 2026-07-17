// Concept adapted from ScreenTestSwitch in OnlySwitch (MIT),
// https://github.com/jacklandrin/OnlySwitch — see Resources/Licenses/
// OnlySwitch-LICENSE.txt. OnlySwitch hosts a SwiftUI PureColorView inside an
// NSHostingView driven into full-screen mode. That path is banned here: the
// macOS 26 NSHostingView-in-floating-panel constraint crash means overlay
// windows in this repo are plain AppKit with explicit frames. So the color
// surface is a bare opaque NSWindow whose backgroundColor is the current color;
// no SwiftUI hosting inside the fullscreen windows.

import AppKit

/// The dead-pixel test colors, in cycle order.
enum ScreenTestColor: CaseIterable, Equatable {
    case white, black, red, green, blue

    var nsColor: NSColor {
        switch self {
        case .white: .white
        case .black: .black
        case .red: NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        case .green: NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)
        case .blue: NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)
        }
    }
}

/// Pure color-cycle state machine. `advance` walks white → black → red → green
/// → blue; advancing past the last color finishes. `finish` (Esc) exits at any
/// point. No AppKit here — unit-tested directly.
struct ScreenTestCycle: Equatable {
    static let order = ScreenTestColor.allCases

    private(set) var index = 0
    private(set) var isFinished = false

    var current: ScreenTestColor { Self.order[index] }

    mutating func advance() {
        guard !isFinished else { return }
        if index + 1 < Self.order.count {
            index += 1
        } else {
            isFinished = true
        }
    }

    mutating func finish() {
        isFinished = true
    }
}

/// Input the fullscreen windows forward to the controller.
enum ScreenTestInput {
    case advance
    case escape
}

/// Momentary "start a screen test" seam. Real impl opens the overlay; tests
/// inject a mock so `swift test` never spawns fullscreen windows.
@MainActor
protocol ScreenTesting: AnyObject {
    func start()
    func stop()
}

/// Opens one opaque, borderless window per display, all showing the current
/// cycle color. Any key or click advances (via the key window / clicked
/// window); Esc, or a click past the last color, tears every window down.
@MainActor
final class ScreenTestController: ScreenTesting {
    private var windows: [ScreenTestWindow] = []
    private var cycle = ScreenTestCycle()

    func start() {
        guard !SwitchTestGuard.isRunningTests else { return }
        guard windows.isEmpty else { return } // already running
        cycle = ScreenTestCycle()
        for screen in NSScreen.screens {
            let window = ScreenTestWindow(screen: screen) { [weak self] input in
                self?.handle(input)
            }
            windows.append(window)
            window.orderFrontRegardless()
        }
        applyColor()
        windows.first?.makeKey()
    }

    func stop() {
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
    }

    private func handle(_ input: ScreenTestInput) {
        switch input {
        case .escape:
            stop()
        case .advance:
            cycle.advance()
            if cycle.isFinished { stop() } else { applyColor() }
        }
    }

    private func applyColor() {
        let color = cycle.current.nsColor
        for window in windows { window.backgroundColor = color }
    }
}

/// Bare opaque fullscreen window. No content view / hosting — the window's
/// `backgroundColor` is the whole surface. Takes key so it can read keystrokes;
/// forwards every key (Esc → escape, anything else → advance) and click.
private final class ScreenTestWindow: NSWindow {
    private let onInput: (ScreenTestInput) -> Void

    init(screen: NSScreen, onInput: @escaping (ScreenTestInput) -> Void) {
        self.onInput = onInput
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        setFrame(screen.frame, display: true)
        // Just under .screenSaver so the surface covers ordinary windows and
        // the menu bar without fighting a real screen saver.
        level = NSWindow.Level(NSWindow.Level.screenSaver.rawValue - 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isOpaque = true
        hasShadow = false
        isReleasedWhenClosed = false
        ignoresMouseEvents = false
        backgroundColor = .black
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func keyDown(with event: NSEvent) {
        // 53 == kVK_Escape.
        onInput(event.keyCode == 53 ? .escape : .advance)
    }

    override func mouseDown(with event: NSEvent) {
        onInput(.advance)
    }

    override func cancelOperation(_ sender: Any?) {
        onInput(.escape)
    }
}
