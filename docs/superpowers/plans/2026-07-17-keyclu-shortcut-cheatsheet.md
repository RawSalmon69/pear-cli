# KeyClu Shortcut Cheat-Sheet Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A companion tool `keyclu` that, on the global chord ⌃⇧K, overlays the frontmost app's keyboard shortcuts grouped by menu.

**Architecture:** A pure parsing core (`AXNode` tree → `[MenuGroup]`, plus modifier/key glyph formatting) that is fully unit-tested with hand-built trees; a thin live Accessibility provider that builds `AXNode`s from the frontmost app's menu bar; a SwiftUI overlay in a fixed-size non-activating panel; and a `Tool` conformer wiring it to the ⌃⇧K chord with an AX-permission gate.

**Tech Stack:** Swift, AppKit, SwiftUI, ApplicationServices (Accessibility), Carbon.HIToolbox (`kVK_*` codes), XCTest.

## Global Constraints

- Deployment target: **macOS 14** (`Package.swift` `platforms: [.macOS(.v14)]`). No API newer than macOS 14 without an `#available` guard.
- **No new dependencies.** Reuse `DockAX` (typed AX reads + `capTimeout`), `Theme`, and `glassCard`.
- All files live under `companion/Sources/PearCompanion/Tools/KeyClu/`; the test file under `companion/Tests/PearCompanionTests/`.
- **Overlay must be fixed-size:** measure `NSHostingView.fittingSize` once, then build a fixed-size panel and `.fixedSize()` the root view. Never let the hosting view drive window content-size extrema (the macOS-26 `ColorToast` runaway).
- Read-only: never write to, activate, or otherwise disturb the target app.
- **Commits: no AI attribution trailers** (project CLAUDE.md). Conventional Commit subjects.
- All commands run from `companion/` unless stated. Test command: `swift test --filter KeyCluShortcutTests`.

---

### Task 1: Types + glyph formatting (pure)

**Files:**
- Create: `companion/Sources/PearCompanion/Tools/KeyClu/MenuShortcutReader.swift`
- Test: `companion/Tests/PearCompanionTests/KeyCluShortcutTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `struct Shortcut: Equatable { let title: String; let glyph: String }`
  - `struct MenuGroup: Equatable { let title: String; let shortcuts: [Shortcut] }`
  - `struct AXNode` with memberwise defaults: `title: String = ""`, `cmdChar: String? = nil`, `cmdVirtualKey: Int? = nil`, `cmdModifiers: Int = 0`, `cmdGlyph: Int? = nil`, `isSeparator: Bool = false`, `isEnabled: Bool = true`, `children: [AXNode] = []`
  - `enum ShortcutFormatting` with `static func modifierGlyphs(_ mask: Int) -> String`, `static func keyGlyph(char: String?, virtualKey: Int?) -> String?`, `static func glyph(char: String?, virtualKey: Int?, modifiers: Int) -> String?`

- [ ] **Step 1: Write the failing tests**

Create `companion/Tests/PearCompanionTests/KeyCluShortcutTests.swift`:

```swift
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter KeyCluShortcutTests`
Expected: FAIL — compile error, `cannot find 'ShortcutFormatting' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `companion/Sources/PearCompanion/Tools/KeyClu/MenuShortcutReader.swift`:

```swift
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter KeyCluShortcutTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
cd companion
git add Sources/PearCompanion/Tools/KeyClu/MenuShortcutReader.swift Tests/PearCompanionTests/KeyCluShortcutTests.swift
git commit -m "feat(keyclu): shortcut types and glyph formatting"
```

---

### Task 2: Menu-tree walk (pure)

**Files:**
- Modify: `companion/Sources/PearCompanion/Tools/KeyClu/MenuShortcutReader.swift`
- Modify: `companion/Tests/PearCompanionTests/KeyCluShortcutTests.swift`

**Interfaces:**
- Consumes: `AXNode`, `Shortcut`, `MenuGroup`, `ShortcutFormatting` (Task 1).
- Produces:
  - `struct MenuShortcutReader` with `init(provider: (any MenuAXProviding)? = nil)` and `func groups(from menuBar: AXNode) -> [MenuGroup]` (pure, non-isolated). (`MenuAXProviding` and the pid-based method arrive in Task 3; the `provider` stored property is declared now as `(any MenuAXProviding)?` — see note in Step 3.)

- [ ] **Step 1: Write the failing tests**

Append these methods inside `KeyCluShortcutTests` in `companion/Tests/PearCompanionTests/KeyCluShortcutTests.swift`:

```swift
    // MARK: - Menu-tree walk

    /// A menu bar with an Apple menu, a File menu (Open ⌘O, a separator, and a
    /// disabled Close), and an Edit menu whose Find item has a Find submenu
    /// (Find Next ⌘G).
    private func sampleMenuBar() -> AXNode {
        AXNode(children: [
            AXNode(title: "Apple", children: [
                AXNode(title: "About This Mac"),
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter KeyCluShortcutTests`
Expected: FAIL — `cannot find 'MenuShortcutReader' in scope`.

- [ ] **Step 3: Write minimal implementation**

Append to `companion/Sources/PearCompanion/Tools/KeyClu/MenuShortcutReader.swift`:

```swift
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
}

/// Supplies a menu-bar `AXNode` tree for a running app. Main-actor because AX
/// reads run on the main actor; the live implementation is Task 3.
@MainActor
protocol MenuAXProviding {
    func menuBar(forPID pid: pid_t) -> AXNode?
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter KeyCluShortcutTests`
Expected: PASS (8 tests total).

- [ ] **Step 5: Commit**

```bash
cd companion
git add Sources/PearCompanion/Tools/KeyClu/MenuShortcutReader.swift Tests/PearCompanionTests/KeyCluShortcutTests.swift
git commit -m "feat(keyclu): menu-tree walk into shortcut groups"
```

---

### Task 3: Live Accessibility provider (glue)

**Files:**
- Create: `companion/Sources/PearCompanion/Tools/KeyClu/LiveMenuAXProvider.swift`
- Modify: `companion/Sources/PearCompanion/Tools/KeyClu/MenuShortcutReader.swift`

**Interfaces:**
- Consumes: `AXNode`, `MenuAXProviding`, `MenuShortcutReader` (Tasks 1–2), `DockAX` (`companion/Sources/PearCompanion/Tools/DockDoor/DockAX.swift`).
- Produces:
  - `struct LiveMenuAXProvider: MenuAXProviding` (`@MainActor`)
  - `MenuShortcutReader.groups(forPID:)` — `@MainActor func groups(forPID pid: pid_t) -> [MenuGroup]`

- [ ] **Step 1: Write the implementation**

Create `companion/Sources/PearCompanion/Tools/KeyClu/LiveMenuAXProvider.swift`:

```swift
import ApplicationServices

/// Builds a menu-bar `AXNode` tree from a running app via Accessibility.
/// Flattens each menu-bar item's single `AXMenu` child so `AXNode.children`
/// holds the actual menu items. Every read is timeout-capped so a beachballing
/// target app can't freeze our main thread.
///
/// ponytail: reads the whole menu tree eagerly on each hotkey press. Fine for
/// on-demand use; if a giant menu (Safari History) feels slow, cap depth or
/// item count here.
@MainActor
struct LiveMenuAXProvider: MenuAXProviding {
    func menuBar(forPID pid: pid_t) -> AXNode? {
        let app = AXUIElementCreateApplication(pid)
        DockAX.capTimeout(app)
        guard let bar = DockAX.element(app, kAXMenuBarAttribute) else { return nil }
        return node(from: bar)
    }

    private func node(from element: AXUIElement) -> AXNode {
        DockAX.capTimeout(element)
        let title = DockAX.string(element, kAXTitleAttribute) ?? ""
        let enabled = DockAX.bool(element, kAXEnabledAttribute) ?? true
        let char = DockAX.string(element, kAXMenuItemCmdCharAttribute)
        let virtualKey = DockAX.value(element, kAXMenuItemCmdVirtualKeyAttribute) as? Int
        let modifiers = DockAX.value(element, kAXMenuItemCmdModifiersAttribute) as? Int ?? 0
        let glyph = DockAX.value(element, kAXMenuItemCmdGlyphAttribute) as? Int

        // A menu-bar item / submenu parent holds its items inside one AXMenu
        // child. Flatten that so `children` are the items themselves.
        var children: [AXNode] = []
        for child in DockAX.elements(element, kAXChildrenAttribute) ?? [] {
            if DockAX.string(child, kAXRoleAttribute) == kAXMenuRole {
                children += (DockAX.elements(child, kAXChildrenAttribute) ?? []).map { node(from: $0) }
            } else {
                children.append(node(from: child))
            }
        }

        let isSeparator = title.isEmpty && char == nil && virtualKey == nil && children.isEmpty
        return AXNode(
            title: title, cmdChar: char, cmdVirtualKey: virtualKey,
            cmdModifiers: modifiers, cmdGlyph: glyph,
            isSeparator: isSeparator, isEnabled: enabled, children: children)
    }
}
```

- [ ] **Step 2: Add the pid-based reader method**

Append to `MenuShortcutReader` (inside the struct) in `companion/Sources/PearCompanion/Tools/KeyClu/MenuShortcutReader.swift`:

```swift
    /// Production entry: read the app's menu bar via the injected provider, then
    /// run the pure walk. Empty when there is no provider or no menu bar.
    @MainActor
    func groups(forPID pid: pid_t) -> [MenuGroup] {
        guard let menuBar = provider?.menuBar(forPID: pid) else { return [] }
        return groups(from: menuBar)
    }
```

- [ ] **Step 3: Verify the build and existing tests**

Run: `swift build && swift test --filter KeyCluShortcutTests`
Expected: build succeeds; 8 tests still PASS (walk is unchanged).

- [ ] **Step 4: Commit**

```bash
cd companion
git add Sources/PearCompanion/Tools/KeyClu/LiveMenuAXProvider.swift Sources/PearCompanion/Tools/KeyClu/MenuShortcutReader.swift
git commit -m "feat(keyclu): live Accessibility menu-bar provider"
```

---

### Task 4: Overlay view, panel, and controller (glue)

**Files:**
- Create: `companion/Sources/PearCompanion/Tools/KeyClu/KeyCluOverlayPanel.swift`

**Interfaces:**
- Consumes: `MenuGroup`, `Shortcut` (Task 1), `Theme`, `glassCard` (`companion/Sources/PearCompanion/Views/Materials.swift`).
- Produces:
  - `struct KeyCluOverlayView: View` — `init(appName: String, appIcon: NSImage?, groups: [MenuGroup])`
  - `final class KeyCluOverlayController` (`@MainActor`) — `var isVisible: Bool`, `func present(appName: String, appIcon: NSImage?, groups: [MenuGroup])`, `func hide()`

- [ ] **Step 1: Write the implementation**

Create `companion/Sources/PearCompanion/Tools/KeyClu/KeyCluOverlayPanel.swift`:

```swift
import AppKit
import SwiftUI

/// The cheat-sheet contents: app header, then each menu group as a titled block
/// of title/glyph rows, laid out across up to three balanced columns. Fixed
/// size (see controller) so the hosting panel never drives its own sizing.
struct KeyCluOverlayView: View {
    let appName: String
    let appIcon: NSImage?
    let groups: [MenuGroup]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.itemGap) {
            HStack(spacing: 8) {
                if let appIcon {
                    Image(nsImage: appIcon).resizable().frame(width: 20, height: 20)
                }
                Text(appName).font(Theme.emphasis)
                Spacer(minLength: 24)
                Text("esc to close").font(Theme.body).foregroundStyle(.tertiary)
            }

            if groups.isEmpty {
                Text("No shortcuts found").font(Theme.body).foregroundStyle(.secondary)
            } else {
                HStack(alignment: .top, spacing: 28) {
                    ForEach(Array(columns().enumerated()), id: \.offset) { _, column in
                        VStack(alignment: .leading, spacing: Theme.itemGap) {
                            ForEach(column, id: \.title) { group in
                                groupBlock(group)
                            }
                        }
                    }
                }
            }
        }
        .padding(Theme.cardPadding)
        .glassCard(cornerRadius: 16)
        .fixedSize()
    }

    private func groupBlock(_ group: MenuGroup) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(group.title).font(Theme.emphasis).foregroundStyle(Theme.accent)
            ForEach(group.shortcuts, id: \.title) { shortcut in
                HStack(spacing: 16) {
                    Text(shortcut.title).font(Theme.body)
                    Spacer(minLength: 12)
                    Text(shortcut.glyph)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Split groups round-robin into up to three columns so the sheet stays wide
    /// rather than tall.
    private func columns() -> [[MenuGroup]] {
        let count = min(3, max(1, groups.count))
        var buckets = Array(repeating: [MenuGroup](), count: count)
        for (index, group) in groups.enumerated() {
            buckets[index % count].append(group)
        }
        return buckets.filter { !$0.isEmpty }
    }
}

/// Borderless non-activating panel that can take key focus so Esc dismisses.
private final class KeyCluPanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

/// Owns the single overlay panel. Fixed-size hosting (measure `fittingSize`
/// once) per the macOS-26 crash rule. Auto-dismisses when the user switches to
/// another app, since the shown shortcuts would be stale.
@MainActor
final class KeyCluOverlayController {
    private var panel: NSPanel?
    private var appSwitchObserver: NSObjectProtocol?

    var isVisible: Bool { panel?.isVisible ?? false }

    func present(appName: String, appIcon: NSImage?, groups: [MenuGroup]) {
        hide()

        let host = NSHostingView(rootView: KeyCluOverlayView(
            appName: appName, appIcon: appIcon, groups: groups))
        let size = host.fittingSize

        let panel = KeyCluPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.onCancel = { [weak self] in self?.hide() }
        panel.contentView = host

        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(
                x: visible.midX - size.width / 2,
                y: visible.midY - size.height / 2))
        }

        panel.makeKeyAndOrderFront(nil)
        self.panel = panel

        appSwitchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
    }

    func hide() {
        if let appSwitchObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(appSwitchObserver)
            self.appSwitchObserver = nil
        }
        panel?.orderOut(nil)
        panel = nil
    }
}
```

- [ ] **Step 2: Verify the build**

Run: `swift build`
Expected: build succeeds.

- [ ] **Step 3: Verify existing tests still pass**

Run: `swift test --filter KeyCluShortcutTests`
Expected: PASS (8 tests).

- [ ] **Step 4: Commit**

```bash
cd companion
git add Sources/PearCompanion/Tools/KeyClu/KeyCluOverlayPanel.swift
git commit -m "feat(keyclu): shortcut overlay view and panel controller"
```

---

### Task 5: Tool conformer + registration (glue + smoke)

**Files:**
- Create: `companion/Sources/PearCompanion/Tools/KeyClu/KeyCluTool.swift`
- Modify: `companion/Sources/PearCompanion/Support/AppEnvironment.swift:48-49` (add the `offer` call before `PanelTool`)

**Interfaces:**
- Consumes: `Tool`, `HotKeyChord`, `ToolEntry`, `ToolCategory` (`Tool.swift`); `MenuShortcutReader`, `LiveMenuAXProvider` (Tasks 2–3); `KeyCluOverlayController` (Task 4).
- Produces: `final class KeyCluTool: Tool` (`@MainActor`).

- [ ] **Step 1: Write the tool**

Create `companion/Sources/PearCompanion/Tools/KeyClu/KeyCluTool.swift`:

```swift
import ApplicationServices
import Carbon.HIToolbox
import SwiftUI

/// Overlays the frontmost app's keyboard shortcuts. ⌃⇧K. Read-only: it reads
/// the target app's menu bar via Accessibility and shows it; it never touches
/// the app. Re-press or app-switch dismisses.
@MainActor
final class KeyCluTool: Tool {
    let id = "keyclu"
    let title = "Shortcuts"
    let icon = "keyboard"
    let category = ToolCategory.utilities
    let summary = "Peek at the frontmost app's keyboard shortcuts."
    let hotkey: HotKeyChord? = HotKeyChord(
        keyCode: kVK_ANSI_K, modifiers: controlKey | shiftKey, label: "⌃⇧K")

    private let overlay = KeyCluOverlayController()
    private let reader = MenuShortcutReader(provider: LiveMenuAXProvider())

    var entry: ToolEntry {
        .action { [weak self] in self?.show() }
    }

    func hotkeyFired() { show() }

    private func show() {
        if overlay.isVisible {
            overlay.hide()
            return
        }
        guard AXIsProcessTrusted() else {
            // Same prompt the Windows tool uses; the string key avoids the
            // Swift 6 non-Sendable global `kAXTrustedCheckOptionPrompt`.
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            return
        }
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        let groups = reader.groups(forPID: app.processIdentifier)
        overlay.present(
            appName: app.localizedName ?? "App", appIcon: app.icon, groups: groups)
    }
}
```

- [ ] **Step 2: Register the tool**

In `companion/Sources/PearCompanion/Support/AppEnvironment.swift`, add the offer line immediately before `tools.offer(PanelTool())`:

```swift
        tools.offer(KeyCluTool())
        tools.offer(PanelTool())
```

- [ ] **Step 3: Verify the full build and test suite**

Run: `swift build && swift test`
Expected: build succeeds; entire suite PASSES (including the 8 KeyClu tests). Confirm no chord-conflict assertion — ⌃⇧K (control+shift) does not collide with the Windows zone chord for K (control+option).

- [ ] **Step 4: Build a dev app**

Run: `./build.sh 2.7.7-dev`
Expected: `build/Pear.app` assembled (unsigned is fine for local smoke).

- [ ] **Step 5: Smoke on real apps**

Launch `build/Pear.app`. Grant Accessibility if prompted (Settings → Privacy & Security → Accessibility → Pear). Then, with each of Finder, Safari, and TextEdit frontmost:
- Press ⌃⇧K → overlay appears with that app's shortcuts grouped by menu (File, Edit, …); the Apple menu is absent; glyphs render (e.g. ⌘C, ⇧⌘Z, arrows).
- Press Esc → overlay closes. Press ⌃⇧K again then click another app → overlay closes (stale-dismiss).
- With Accessibility revoked, press ⌃⇧K → the system Accessibility prompt appears, no overlay.
- In Settings, confirm the "Shortcuts" tool row appears with a ⌃⇧K chord that can be toggled off and rebound.

- [ ] **Step 6: Commit**

```bash
cd companion
git add Sources/PearCompanion/Tools/KeyClu/KeyCluTool.swift Sources/PearCompanion/Support/AppEnvironment.swift
git commit -m "feat(keyclu): register Shortcuts tool on ⌃⇧K"
```

---

## Self-Review

**Spec coverage:**
- Discovery via AX menu-bar walk → Tasks 2 (walk) + 3 (live provider). ✓
- Modifier-mask + key-glyph formatting → Task 1. ✓
- SwiftUI fixed-size non-activating overlay panel → Task 4. ✓
- Tool conformer, ⌃⇧K chord, AX-trust gate, one-line registration → Task 5. ✓
- Focus safety (snapshot before show) → Task 5 `show()` reads groups before `overlay.present`. ✓
- Permission / empty / beachball handling → Task 5 (trust gate), Task 4 (empty view), Task 3 (`capTimeout`). ✓
- Unit tests over a hand-built tree, no AX permission → Tasks 1–2 use `MenuShortcutReader().groups(from:)` and `ShortcutFormatting`, provider never touched. ✓
- Excluded (hide/pin, custom shortcuts, import/export, zebra, ⌘⌘-hold) → not present. ✓

**Placeholder scan:** No TBD/TODO; every code step shows complete code; commands have expected output. ✓

**Type consistency:** `AXNode`, `Shortcut`, `MenuGroup`, `MenuShortcutReader` (`groups(from:)`, `groups(forPID:)`, `provider`), `MenuAXProviding.menuBar(forPID:)`, `LiveMenuAXProvider`, `KeyCluOverlayView(appName:appIcon:groups:)`, `KeyCluOverlayController` (`isVisible`, `present(appName:appIcon:groups:)`, `hide()`), `KeyCluTool` — names and signatures match across tasks. ✓
