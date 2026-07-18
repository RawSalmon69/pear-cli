# KeyClu-style shortcut cheat-sheet — design

Date: 2026-07-17
Status: approved (design), pending implementation plan
Scope: companion menu-bar app (`companion/`), new Pear tool `keyclu`

## Summary

A new Pear tool that, on the global chord **⌃⇧K**, overlays the **frontmost
app's keyboard shortcuts**, grouped by menu (File, Edit, …). Esc / re-press /
app-switch dismisses. Read-only — never touches the other app. Modeled on
[KeyClu](https://github.com/Anze/KeyCluCask) but **reimplemented**: KeyClu's
source is closed (`Anze/KeyClu` is private/gone; only the Homebrew cask + wiki
are public), so nothing is borrowed and no license/attribution applies.

This is the KeyClu feature parked in memory (`keyclu-next-feature`), shipped as
a companion tool, not a CLI command.

## Product fit

Matches AGENTS.md Product Direction for the companion: bounded, read-only,
explainable, previewable. It inspects and displays; it changes nothing. AX
access is the only system touch, and it is read-only.

## Decisions (locked)

- **Trigger:** plain chord `⌃⇧K` via the `Tool` protocol + `Prefs` override —
  same grammar as every other tool. *Not* KeyClu's double-⌘-hold (that needs a
  bespoke `flagsChanged` monitor and breaks the shared hotkey/Esc grammar).
- **v1 scope:** read-only overlay only. **Excluded** (YAGNI): hide/pin
  shortcuts, custom-shortcut extensions for menu-less apps, `.keyclu`
  import/export, zebra mode. Add when asked.
- **Overlay rendering:** SwiftUI in a **fixed-size** non-activating `NSPanel`,
  sized once from `fittingSize` — the proven `WindowsWindowController` /
  `RadialRingWindow` pattern. *Not* pure AppKit. See "Overlay crash-safety".

## Discovery mechanism (KeyClu's approach, reimplemented)

Frontmost app → its menu bar via Accessibility:

1. `NSWorkspace.shared.frontmostApplication` → `pid`, localized name, icon.
2. `AXUIElementCreateApplication(pid)` → `kAXMenuBarAttribute`.
3. Menu-bar children are the top menus (Apple, File, Edit, …). Each top menu
   item has one `AXMenu` child holding the menu items.
4. Per menu item read: `kAXTitleAttribute`, `kAXMenuItemCmdCharAttribute`,
   `kAXMenuItemCmdVirtualKeyAttribute`, `kAXMenuItemCmdModifiersAttribute`,
   `kAXMenuItemCmdGlyphAttribute`, `kAXEnabledAttribute`.
5. Keep only items that have a shortcut (a cmd char, virtual key, or glyph).
   Skip separators, disabled items, and items with no shortcut. Recurse into
   submenus (an item with an `AXMenu` child).
6. Reuse `DockAX` typed reads + `DockAX.capTimeout` so a beachballing target
   app can never freeze our main thread.

### Modifier mask decoding (real logic → unit tested)

`AXMenuItemCmdModifiers` is the Carbon menu-modifier bitfield:

| bit | value | meaning |
|-----|-------|---------|
| 0 | 1 | Shift ⇧ |
| 1 | 2 | Option ⌥ |
| 2 | 4 | Control ⌃ |
| 3 | 8 | **No** Command (⌘ absent) |

Command ⌘ is present unless bit 3 (value 8) is set. Glyph order: ⌃⌥⇧⌘ + key.

### Key glyph resolution (real logic → unit tested)

- Prefer `CmdChar` (e.g. `"c"` → uppercased `C`).
- Empty char → map `CmdVirtualKey` (a `kVK_*` code) via a small table:
  Return ↩, Tab ⇥, Escape ⎋, Delete ⌫, ForwardDelete ⌦, Space ␣,
  arrows ← → ↑ ↓, Home ↖, End ↘, PageUp ⇞, PageDown ⇟, F1–F12.
- Table miss → fall back to the raw `CmdGlyph`/char if any; otherwise the item
  has no displayable shortcut and is skipped.

## Architecture — 3 units + 1 line of wiring

New directory `companion/Sources/PearCompanion/Tools/KeyClu/`.

### 1. `MenuShortcutReader.swift` — parsing core (unit-tested)

- Types: `Shortcut { title: String, glyph: String }`,
  `MenuGroup { title: String, shortcuts: [Shortcut] }`.
- `AXNode` — a plain value struct mirroring one menu element:
  `title`, `cmdChar`, `cmdVirtualKey`, `cmdModifiers`, `cmdGlyph`,
  `isSeparator`, `isEnabled`, `children: [AXNode]`.
- `protocol MenuAXProviding { func menuBar(forPID pid: pid_t) -> AXNode? }` —
  the test seam.
- `MenuShortcutReader(provider:)` walks the `AXNode` tree → `[MenuGroup]`,
  applying the skip rules, submenu recursion, mask decoding, and glyph
  resolution above. **All pure over `AXNode`** — no live AX in the walk.
- Formatting helpers (`glyph(forModifiers:)`, `glyph(forVirtualKey:)`) live
  here and are directly unit-testable.

### 2. `KeyCluOverlayPanel.swift` — overlay (glue)

- SwiftUI `KeyCluOverlayView(app:, groups:)`: app icon + name header, then the
  groups in columns (menu title + its shortcuts, title left / glyph right,
  monospaced glyphs), on a `glassCard` material. Empty groups → a single
  "No shortcuts found" line.
- `KeyCluOverlayController`: builds the view, measures `fittingSize` once,
  creates a fixed-size `[.borderless, .nonactivatingPanel]` `.floating` panel
  centered on the active screen, `makeKeyAndOrderFront`. Esc via
  `cancelOperation` (mirrors `WindowsPanel.onCancel`). `toggle()` for re-press.

### 3. `KeyCluTool.swift` — Tool conformer + orchestration (glue)

- `Tool`: `id "keyclu"`, `title "Shortcuts"`, SF Symbol `keyboard`,
  `category .utilities`, `summary`, `hotkey ⌃⇧K`
  (`kVK_ANSI_K`, `controlKey | shiftKey`, label `⌃⇧K`).
- `hotkeyFired()` (and the tile action): if `!AXIsProcessTrusted()` →
  present/deep-link the AX permission card (reuse the `WindowsView` pattern:
  `AXIsProcessTrustedWithOptions` prompt + Settings deep-link); else resolve
  frontmost app, read groups **before** showing the panel, then present.
- Tile entry: `.action` running the same path as `hotkeyFired()`, matching
  Screenshot/OCR (untrusted → the AX permission card; trusted → the overlay).

### 4. Wiring — `AppEnvironment.swift`

One line: `tools.offer(KeyCluTool())`. Enable toggle, hotkey override, conflict
detection, and the help-sheet row all appear automatically.

## Data flow

```
⌃⇧K (Carbon global hotkey; accessory app does not activate)
  → AXIsProcessTrusted? ─no→ permission card (deep-link Settings) ─┐
  │ yes                                                             │
  → NSWorkspace.frontmostApplication (pid, name, icon)             │
  → MenuShortcutReader.read(pid) via live AX provider → [MenuGroup]│
  → KeyCluOverlayController.present(app, groups)                   │
  → Esc / re-press ⌃⇧K / frontmost-app-change → hide  ────────────┘
```

Snapshot is captured **before** the panel shows, so our panel taking key focus
never corrupts the read. Because the app is an accessory (LSUIElement) and the
Carbon hotkey doesn't activate it, `frontmostApplication` is the target app.

## Overlay crash-safety (macOS 26)

`ColorToast` documents an `NSHostingView`-in-panel constraint-update runaway on
macOS 26 — but its root cause is a panel that lets the hosting view **drive
window content-size extrema** (`updateWindowContentSizeExtremaIfNecessary`
re-evaluating the SwiftUI graph mid-pass). `RadialRingWindow` (fixed 180×180)
and `WindowsWindowController` (`fittingSize` measured once, then a fixed panel)
use `NSHostingView` safely because the panel size is fixed. KeyClu follows that
proven pattern: measure `fittingSize` once, fix the panel, `.fixedSize()` the
root view. Full-screen pure-AppKit (`CleanModeOverlay`) is not needed here.

## Error / empty handling

- **No AX permission:** permission card + deep-link (`WindowsView` pattern). No
  overlay until trusted.
- **No shortcuts / read fails:** small overlay with "No shortcuts found".
- **Beachballing target:** `DockAX.capTimeout` bounds every AX read.

## Testing

`Tests/PearCompanionTests/KeyCluShortcutTests.swift`, injecting a fake
`MenuAXProviding` that returns a hand-built `AXNode` tree — no AX permission, no
frontmost app, no window. Cases:

- Grouping: top menus → `MenuGroup`s in order; only menus with ≥1 shortcut kept.
- Skips: separators, disabled items, items with no shortcut.
- Submenu recursion: nested `AXMenu` items surface their shortcuts.
- Mask decoding: 0→⌘, 1→⇧⌘, 2→⌥⌘, 4→⌃⌘, 8→(no ⌘), combos, full ⌃⌥⇧⌘.
- Glyph resolution: cmd char uppercased; virtual-key table hits (↩⇥⎋⌫←→↑↓…);
  table miss skipped.

AX/window glue (`KeyCluOverlayController`, live provider, `KeyCluTool`) stays
thin and is exercised by build + manual smoke, not unit tests.

## Verification

- `cd companion && swift build && swift test`.
- Build a dev app: `companion/build.sh <ver>-dev`.
- Smoke the overlay on real apps (Finder, Safari, Xcode) before any release;
  confirm grouping, glyphs, Esc, app-switch dismiss, and the AX permission flow
  on a machine where Pear is not yet trusted.

## Out of scope (v1)

Hide/pin shortcuts, custom shortcuts for menu-less apps, `.keyclu`
import/export, zebra mode, double-⌘-hold trigger. Revisit per demand.
