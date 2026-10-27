# Pear Companion — Agent Guide

Shared source of truth for any AI agent (Claude Code, Codex, …) working on the
**Pear.app companion** in `companion/`. This is a separate product from the
`pear` CLI (the root `AGENTS.md` covers the CLI). `CLAUDE.md` at the repo root
is a symlink to the root guide; read both.

Keep this file current: when you add/remove a tool or feature, change a key
decision, or hit a release gotcha, update the relevant section here in the same
change. It is the first thing a fresh session reads to understand the app.

## What it is

Pear.app is a private, native macOS **menu-bar utility** (SwiftUI + AppKit, one
Swift Package, `PearCompanion` target plus the macOS 26 `PearControl` Control
Center extension, min **macOS 14**, Swift 6 strict
concurrency). Think CleanShot/Loop/Bartender-class power-user toolkit for one
couple, distributed friends-and-family. It is **on-device and privacy-first**:
no third-party runtime deps except Sparkle (auto-update) and an optional,
opt-in ML model download. E2E-encrypted CloudKit couple-messaging exists but is
currently hidden behind `FeatureFlags.coupleNote`.

North star (owner): **"just works, robust, not prone to breakage."** Prefer
native Apple primitives over custom imitations. See root memory / `[[owner-quality-bar]]`.

## Build / run / test

```bash
cd companion
swift build            # compile
swift test             # full suite, must stay green
./build.sh [version]   # assemble build/Pear.app (unsigned dev bundle); `open build/Pear.app`
```

A bare `.build/release/PearCompanion` binary crashes on launch (needs the `.app`
bundle for UNUserNotificationCenter + resources) — always run via `build.sh` +
`open`. CI (`companion.yml`) runs build+test+assemble on every `companion/**`
push/PR.

**App Intents metadata: `build.sh` builds it.** SwiftPM never runs Xcode's
ExtractAppIntentsMetadata step, so a stock `swift build` leaves no
`Metadata.appintents` and Shortcuts never sees an action. `build.sh` does it in two
steps, no Xcode project: the release build passes `-emit-const-values` plus
`-const-gather-protocols-file Resources/AppIntentsProtocols.json` (a committed plain
JSON array of the names in the toolchain's
`usr/share/swift/SwiftConstantValues/AppIntents.json`; `--build-system native`
rejects that file's versioned form as "malformed"), then, before codesign,
`xcrun appintentsmetadataprocessor` writes
`Contents/Resources/Metadata.appintents/{extract.actionsdata,version.json}`. The
const-values file is found, not hardcoded: inside the bin path under the native
backend (`.build/<triple>/release/PearCompanion.build/`) or under
`.build/out/Intermediates.noindex/…/Release/` with SwiftBuild (Xcode 27's default);
none found fails the build. `--xcode-version` comes from `xcodebuild -version` at
build time, so CI's Xcode and a local one each describe themselves. Both workflows
only call `build.sh`. To check a build, the `actions` key of `extract.actionsdata`
(plain JSON) must list all eight intents, and the appex's must list
`SetKeepAwakeIntent`. Product paths come from `swift build --show-bin-path`, which
covers SwiftBuild's `.build/out/Products/Release` (a path search that missed it
once shipped a local app with no Sparkle and no resource bundle). Spike evidence
(2026-10-18): a Developer ID-signed Pear copy under
a throwaway bundle ID got LaunchServices `base flags: link-enabled` (real Pear had
none); a tiny SwiftPM app built the same way appeared in Shortcuts' action index
after one launch (`~/Library/Shortcuts/ToolKit` `Tools` row
`….TinySpikeIntent|appIntent`). Before any launch, linkd logs `Rejecting … is not
trusted` for an unnotarized bundle (spctl: "Unnotarized Developer ID"), so a fresh
dev build must be opened once; a notarized release is untested. The metadata is
plain resources sealed by the existing codesign, as in any Xcode-built app. Owner
check: the actions show in the Shortcuts app.

## Architecture

- **`Tool` protocol + `ToolRegistry`** (`Tools/Tool.swift`): every feature is a
  Tool — `id/title/icon/category/summary`, an optional rebindable `hotkey`, an
  `entry` (tile action or popover), and `start()`/`stop()` for always-on engines.
  Optional: `aliases` (extra search words), `status` (live row text),
  `acceptsHotkey` (false when a chord would fire into nothing: Switches, Windows,
  Highlight Copy), `showsTile` (false only for the `panel` pseudo-tool). Disabled
  tools are never registered (their hotkeys/engines never load). Some tools default OFF (see invariants). `Tools/BuiltinTools.swift` holds the launch
  tools (Screenshot, OCR, Clipboard, Disk, Panel); the rest live in their own
  `Tools/<Name>/` dirs.
- **`AppEnvironment`** (`Support/AppEnvironment.swift`): inert DI container of
  `@Observable` services, handed to views via `.environment()`. `live()` builds
  the real graph. Views read the one service they need.
- **`PanelController`** (`Views/PanelWindow.swift`): owns the menu-bar status
  item + the companion panel (a non-activating `NSPanel`, replaced the old
  `MenuBarExtra`). Closes on focus loss by default (`Prefs.panelClosesOnFocusLoss`),
  draggable, recreate-per-open so idle cost ~0. Left click toggles the panel;
  right/control-click pops a native menu (Settings… ⌘,, Check for Updates…, Quit
  Pear) by setting `statusItem.menu` only for that click — never leave it set.
- **Settings is a window** (`Views/SettingsWindowController.swift` +
  `Views/SettingsView.swift`), not a popover: one standard titled window, reused,
  frame autosaved (`PearSettingsWindow`), a `NavigationSplitView` sidebar of
  `SettingsPage`s — General (panel, **pins picker**, startup, sounds, screenshots,
  preview stack, HD background removal), Appearance (accent + the runner;
  "Menu Bar" is only the hider tool's page), **Shortcuts** (below), then **one
  page per offered tool** in offer order, enabled or not (`SettingsPage.tool(id)`,
  stored as `tool.<id>`; `SettingsPage.visible(toolIDs:)` builds the sidebar and
  `resolved(_:toolIDs:)` turns an unknown or removed tool's page into General),
  Licence (paid builds only), About (version, Check for Updates…, every bundled
  licence/notice shown inline). **A tool page is the single home of that tool's
  options**: its on/off switch (`ToolRegistry.setEnabled`, live: off unloads it),
  then its options view — `MenuBarOptionsView` (auto-hide, zones),
  `SwitchesVisibilityView` (which switches show), `ScratchpadSettingsView`,
  `ColorFormatPicker`, `CleanModeSettingsView` — chosen by tool id in
  `SettingsView.toolOptions`. Between the two sits the **status block**
  (`SettingsView.toolStatus`): Permission (from `PanelProblem.permission(neededBy:)`,
  the panel's one tool→permission mapping, read through `Permissions.status(of:)`,
  never a prompt; Screen Recording reads "granted" when preflight says so,
  "missing" only once a capture failed for it, otherwise "checked at the first
  capture", because preflight can stay false after a grant until relaunch),
  Shortcut (`ToolRegistry.shortcutStatus(for:)`: "registered" means a live
  Carbon token, `HotKeyManager.isRegistered`, not just a chord; a tool that takes
  no shortcut says so, Windows points at the Shortcuts page), and Last error,
  shown only when there is one.
  No option lives in a popover or an in-window gear: the Menu Bar, Switches and
  Color Picker popovers keep their working controls plus a `ToolSettingsLink`
  ("Settings…" → `SettingsPage.open(.tool(id))`, at the right of their
  `PopoverHeader`), and the Scratchpad header gear
  opens its page. A new tool option goes on the tool page, never back in a popover.
  The Menu Bar page edits the tool's live manager even while off
  (`ToolRegistry.offeredTool`), so it starts with what was chosen. The **pins
  picker** is four slot menus over the enabled tools with a tile; `PanelModel`
  decides each slot and what a pick stores (`pins(placing:inSlot:)`, in
  `PanelModel.swift`: the row as shown with the pick swapped in, plus the
  stored pins of tools that are off), saved with `Prefs.setPinnedTools`. "Live"
  means the next panel open: the panel closes when Settings opens and reads pins
  on every open.
  Everything opens it through `SettingsPage.open(_:)` → `pearOpenSettings` →
  `PanelController.openSettings()`, which closes the panel first (it floats at
  status-bar level, over the window): the panel's gear, ⌘, while the panel is key
  (`PearPanel.performKeyEquivalent`, ahead of the search field), the status-item
  menu, the app menu (`CommandGroup(replacing: .appSettings)` in `PearApp`, or the
  empty `Settings` scene would open), and "Open Settings" under "No tools match"
  (lands on the first tool page, or General with none). The last page is
  `Prefs.settingsPage` (`settingsLastPage`),
  read through `@AppStorage`, so `open(.licence)` switches a window already up.
  While it is open Pear is `.regular` (Dock icon, ⌘-Tab, menu bar), back to
  `.accessory` on `windowWillClose` unless another titled window (Disk, detail,
  Markup, Remove Background) is still visible or minimised, and whichever closes
  last drops Pear back: all five call `StandardWindow.didClose`
  (`Views/StandardWindow.swift`, tested) from `windowWillClose`. Only Settings
  ever switches to `.regular`. Settings itself is not miniaturizable, since a
  minimised Settings never fires `windowWillClose`; the other four keep minimise
  and count as open while minimised. Activation runs one turn after the policy
  change so the first open gets focus. The panel stays non-activating and the
  capture-hides-panel observer is untouched. Each open from closed rebuilds the
  root view (`.id(UUID())`), so every open starts fresh.
- **Shortcuts page** (`SettingsView.shortcutsPage`, `Views/HotkeyRecorder.swift`):
  every key combination in Pear — a `HotkeyRecorderRow` per tool with
  `acceptsHotkey`, then one per
  Windows snap chord by action name — each recordable, removable and resettable,
  plus "Reset All Shortcuts…" (`ToolRegistry.resetAllShortcuts`, both sets). The
  recorder: click, press keys with a modifier; Esc cancels; a bare Delete removes
  (⌃⌥⌫ etc. record normally). Rows address a `ShortcutOwner` (`.tool(id)` /
  `.windows(bindingID)`). **`ToolRegistry.conflictingTool(for:excluding:)` is the
  one answer to "who owns this chord?"** for both sets, symmetric: every enabled
  tool's effective chord, then the live `registry.windowsChords` (read from
  `WindowSettings`, never the defaults), warning "Used by Screenshot" or "Used by
  Windows: Left Half". A disabled tool, or Windows off, blocks nothing (it
  registers nothing); a Windows binding being recorded still sees the other
  Windows bindings. A Windows chord change goes through the registry, which
  stops and starts a running `WindowsTool` so `WindowTrigger` re-registers the
  chords live. `WindowSettings.removeChord` uses the same "none" sentinel as
  `Prefs.removeHotkey`. Under XCTest the registry registers no Carbon hotkeys
  (`CleanModeRuntime.isRunningTests`), like `WindowTrigger`. Tests:
  `ShortcutRegistryTests` (Windows chords in an injected suite).
- **Last-error hook** (`ToolRegistry.reportError(_:for:)` / `lastError(for:)`):
  a tool reports one line on failure; it is held in memory only, replaced by the
  next report, cleared when the tool is turned off or on (`setEnabled`), and a
  later success does not clear it. Observed, so the tool page redraws live.
  Callers outside the registry use `ToolRegistry.live?` (nil in tests). Reports
  today: every capture through `ScreenCapture.run` (screencapture failed to
  start; Screen Recording denied; Esc reports nothing), `ScreenshotService.fileCapture`
  (screenshot folder failed so the store took it; nothing filed, temp copy only),
  a card's or the detail window's Save (`ScreenshotService.saveToFolder`; each
  shows its checkmark only on success, and a source that has gone takes the
  `missing` path), an edit that could not be written over the shot
  (`ScreenshotService.saveEdit` / `CaptureStore.land`, after Markup or Remove
  Background, tested: the edit is kept as a new capture in the store, carded,
  copied and added to Recent; only if the store fails too is the untouched
  original re-shown — an edit is never silently lost),
  `WindowsTool.apply` (no Accessibility), `AXWindowMover.commit` (no movable
  front window) and `apply` (the app refused the frame after both passes).
  Tests: `ToolStatusTests`, `WindowsSnapPermissionTests`.
- **Panel structure** (`Views/PanelView.swift`, `Views/PanelModel.swift`): the
  cat + a search field (focused on open) on top, the cat's line under it, the
  one-time "Pick your four" card, four big pinned tiles (icon, name, shortcut as
  plain text under it), the "Recent" captures strip, then one compact "All
  tools" list of every other enabled tool (icon, name, optional live
  `Tool.status` such as Switches "2 on", shortcut label or "no shortcut"), then
  a hairline and the bottom bar. **Density is owner-approved (2026-10)**: 16 pt
  panel inset (wider than `edgePadding`), 20 pt between sections, 12 pt
  `callout` for the search field, row titles and the card title, 28 pt minimum
  rows; the off-scale values live once in `PanelDensity` at the top of
  `PanelView.swift`. Don't grow the panel's type back without an ask. **Pin fill rule:** the user's pins in order
  that are enabled, then enabled unpinned tools in offer order, up to four;
  fewer enabled tools give fewer tiles, never placeholders. Defaults are
  Screenshot, Grab Text, Clipboard, Shelf (`Prefs.defaultPinnedTools`). Right-click
  a tile or row for Pin / Unpin: Unpin pins the next tool into the freed slot (so
  it never refills with the tool just unpinned); Pin with four enabled pins
  already showing replaces the fourth; disabled pins stay stored and come back
  when the tool does. Unpin is offered only for a real pin in the row; a tile
  that only fills a slot, or a stored pin pushed past the fourth tile, offers
  Pin. The selection follows the toggled tool. While searching the tiles and
  card hide and results span every tool. Arrows walk tiles left to right, then
  the list, so Return on open runs the first pin. Pins and the card live in
  `Prefs` (`pinnedTools` / `setPinnedTools`, which the General pins picker also
  calls; any pin change retires the card for good, as does closing it).
  **Recent captures:** `PanelModel.recents` is the newest three of
  `Prefs.recentCaptures`, which drops missing files once per open (the
  existence check is injected), hidden when empty and while searching, and
  hidden when no capture mode is enabled (the view passes none). Thumbnails come from `Thumbnail`
  (240 px, decoded off-main per open) and stay out of the arrow-key order (each is
  a plain `Button` under the drag overlay, so it is a Tab stop and a VoiceOver
  press; the overlay still takes every click). The
  shelf's `ShelfDragOverlay` carries click and drag, since SwiftUI `.onDrag`
  does not start in a non-activating panel. While the pointer is anywhere over
  the strip, a hit-transparent tracking view behind it (`WindowMoveBlocker`)
  turns the panel's `isMovableByWindowBackground` off, so a press on a tile can
  never start a window move (the shelf found `mouseDownCanMoveWindow = false`
  alone unreliable); the rest of the panel still drags by its background. A
  click closes the panel, then
  `ScreenshotTool.openCapture` → `ScreenshotService.open`: the detail window of
  the card already backed by that file, or of a fresh card presented for it, so
  the detail window keeps one construction path and the card's actions.
  **`PanelModel` is the only decision point** — a pure value type, tested in
  `PanelModelTests`: tiles, rows (case-insensitive substring on title, summary and
  `Tool.aliases`), clamped selection, ↑/↓/↩ and two-stage Esc (clear the search,
  then close), the cat's line and mood. The view renders it and forwards keys.
  Keys arrive through the AppKit search field's `doCommandBy` delegate and are
  swallowed there, so Esc never also hits `PearPanel.cancelOperation`. Popover
  tools open from their tile or row through the same `TilePopoverState`; Return
  and a click share one `activate` path. Extend the model rather than adding
  decisions to the view.
- **Panel problems** are `PanelProblem` cases declared in priority order, highest
  first, so `problems.min()` is the line the cat says; any problem makes it
  worried, none leaves the line empty and the cat idle. Order: Screen Recording
  missing, Accessibility missing for an **enabled** tool that needs it (Shortcuts
  / KeyClu, Windows, Highlight Copy), disk over 90% used. A permission problem
  puts a **Fix** button beside the line (`PanelModel.fix`), which closes the
  panel and calls `Permissions.fix`: the system request (lists Pear in the pane;
  the system's own prompt shows only the first time), then the pane. Tiles and
  rows of the tools a problem affects (`PanelProblem.affectedTools`) show "needs
  permission" in place of their shortcut. Screen Recording affects Screenshot,
  Full-screen Shot, Window Shot, Grab Text and QR; Color Picker uses the system
  sampler and needs no grant. `PanelModel` takes plain values only
  (`screenRecordingMissing`, `accessibilityTrusted`, the enabled ids), read once
  per open in `PanelView`, so a problem clears on the next open once granted.
  The excited (unseen note) mood is behind `FeatureFlags.coupleNote`. The disk
  read is one synchronous volume query in `PanelController.show()`; nothing waits on open.
- **Permissions** (`Support/Permissions.swift`) is the one thin adapter for the
  permission system calls — `AXIsProcessTrusted` / `AXIsProcessTrustedWithOptions`,
  `CGPreflightScreenCaptureAccess` / `CGRequestScreenCaptureAccess`, and the two
  panes (`x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture`
  / `?Privacy_Accessibility`; the macOS 26 Privacy & Security extension still
  declares that legacy id and both anchors). `grep -rn "AXIsProcessTrusted\|CGPreflightScreenCaptureAccess\|CGRequestScreenCaptureAccess" Sources`
  must hit only that file. Untested (system calls only); never call the request
  or prompt functions from a test. Nothing asks at launch: KeyClu, the Windows
  and Highlight Copy popovers' Grant button, and a Windows snap prompt only when
  the user acts. **Captures are attempted first, never gated on preflight**:
  `ScreenCapture.run` reports only a capture that wrote no file, and
  `ScreenCapture.deniedByPermission` (pure, tested) makes that a problem only
  when preflight also says no, so Esc with the grant is a silent cancel. Known
  edges: Esc while the grant is missing also reads as the problem (true anyway);
  a denied capture that writes a wallpaper-only file reads as success; preflight
  may stay false until Pear relaunches after a grant, so the line stays until
  then. The record is in memory only. **A Windows snap without Accessibility**
  (`WindowsTool.apply`, both the chords and the ring) moves nothing and shows the
  `CopyToast` "Windows needs Accessibility" at the pointer, then the system
  prompt (`WindowsSnapPermissionTests`, trust and refusal injected).
- **Services** (`Services/`): Screenshot, OCR (Vision), BackgroundRemoval
  (Vision + optional HD model), HDBackgroundModel (BEN2 download/manage),
  Clipboard history, CloudKit messaging (flagged off), Stats (disk-used fraction only),
  HotKeyManager (`.shared`, Carbon hotkeys → tokens), Updater (Sparkle),
  CommandRunner/ScreenCapture seams.
- **`Prefs`** (`Support/Prefs.swift`): all UserDefaults keys in one place.
  `Support/ResourceBundle.swift` → **always `Bundle.pearResources`, never
  `Bundle.module`** (see gotchas).

## Tools & features

Capture: **Screenshot** (⌃⇧S, region → clipboard+file+floating preview stack,
markup, background-remove), **Full-screen Shot** (⌃⇧F, whole main display
instantly) and **Window Shot** (⌃⇧W, click a window) — all three are
`ScreenshotTool` modes sharing one preview/markup/send flow. Clicking a preview
card opens the **detail window** (`ScreenshotDetailWindow.swift`): the shot in a
magnifying `NSScrollView` (pinch / ⌘-scroll / double-click / ⌘+ ⌘− ⌘0 / zoom
capsule, with a centering clip view and fit as the zoom-out floor, re-floored
on every resize even when the user owns the zoom — native
AppKit, not custom gesture math), an eyedropper that samples exact image pixels
(`PixelSampler`), the same actions, and a sidebar of
`ScreenshotInsights` — full OCR text in its own scroll box, QR payloads, color
palette, file facts — scanned once off-main *after* the card is on screen, so
nothing delays capture → preview and the window always opens mid-scan; at most
two scans run at once (`ScanQueue`, tested), the rest wait in arrival order, and
a card that goes cancels its scan (queued: never starts; running: stops at the
next pass). The card's and window's Copy text appear only once the scan has
text and copy that text, never recognising the shot a second time. Cards are
**backed by a file, never by bytes** (see `CaptureStore` below). **Pin** (card and
detail window, `PinWindow.swift`) floats the shot in a borderless, always-on-top
AppKit panel: dragged by its body, resized from its edges with the aspect locked
(`contentAspectRatio`), closed by Esc / ⌘W while key; many at once. It reads the
file once at pin time and holds that image, so it outlives its card and a later
sweep, and nothing is restored at relaunch. Pins hide for a capture and come back
after, like the preview stack, so a full-screen shot never contains one;
`PinLayout` (initial fit + cascade) is the tested piece. Hovering shows a top-left
✕ (`NSButton` above the image view, so it never starts a drag; hidden on pins too
small for it, `PinLayout.closeButtonFrame`; always shown under VoiceOver, and
re-decided on every resize and VoiceOver toggle), and right-click offers Close and Reveal in Finder. **OCR / Grab Text**
(⌃⇧T, Vision), **Background
removal** (Apple Vision default; opt-in HD BEN2 Core ML — see below), **QR**
(⌃⇧Q, scan screen region / generate from clipboard, auto QR badge + Copy-text
button on screenshot preview cards).
Windows: **Windows** (⌃⌥ + arrows/↩/C/⌫ snaps the front window; hold **Fn** for a
radial ring under the pointer). Four independent pieces joined by `WindowsTool`
and nothing else: `WindowTrigger` (input), `RingOverlayWindow` (ring + hit test),
`WindowZoneMath` (pure geometry), `AXWindowMover` (AX writes + preview overlay).
Title-bar **trackpad gestures** (a `CGEventTap` + `WindowGesture*` +
`WindowUnderPointer`) were written for 2.17.0, shipped default OFF, and **deleted
in 2.22.0**: driven on real hardware they were unusable, and the owner uses Swish
for that job. An event tap that sees every scroll on the machine is the largest
risk surface in the app, so do not rebuild them without an explicit ask.
Utilities: **Color Picker** (NSColorSampler + WCAG), **Shelf** (⌃⇧V drop-hold-drag;
Space or the eye button toggles the system `QLPreviewPanel`, with `ShelfPanel` as
its responder-chain controller and data source; image rows get **Convert** → PNG,
JPEG or Resize to 50%, done by ImageIO in `ShelfConverter` (tested), each result
added as a new item while the original is only read),
**Scratchpad** (⌃⇧N notes, header-drag + text canvas, spawn-position toggle),
**Clipboard history** (pins + search), **KeyClu** (⌃⇧K shortcut cheat-sheet, read-only AX),
**Highlight to Copy** (default OFF; selecting text with the mouse puts it on the
clipboard, X11 primary-selection style — the selection is read through AX, never
by synthesising ⌘C, and the watcher is a read-only global monitor rather than an
event tap so it cannot break clicking. Secure text fields are never read. The
write carries `org.nspasteboard.AutoGeneratedType`, so it pastes normally but
never reaches the clipboard history that every stray highlight would bury. Each
write raises the shared `CopyToast` at the pointer for ~1.5 s with an elided
snippet: an X11-style silent copy is indistinguishable from the feature having
done nothing, which is exactly how it read in use). `CopyToast.show(message:)` is
the same pure-AppKit HUD with no "Copied" caption, for one-line notices.
System: **Disk** (sunburst/treemap + safe Trash delete), **Menu Bar
hider** (Hidden Bar-style, default OFF), **Switches**
(8 toggles; **Display Off** is a momentary `pmset displaysleepnow`, an action
rather than a setting so it needs no root, shown by default like Screen Saver and
Lock Screen since it writes no persistent state; **Show File Extensions** writes
`NSGlobalDomain AppleShowAllExtensions` and relaunches Finder exactly as Show
Hidden does, reads the live value on every open, and defaults hidden (Rule B) — three removals at the owner's order: Screen Test after it hard-locked
a machine, **Mute** in 2.25.0 (`kAudioDevicePropertyMute` is advisory on many
outputs and the volume-zeroing replacement was not worth keeping), and **Big
Cursor** in 2.26.1 (a TCC-gated write that could silently not apply — the same
defect shape as Mute). Do not reintroduce any of them. **Lid Closed**
is the only switch that needs root: it flips the system-wide `pmset disablesleep`,
which IOKit assertions and `caffeinate` cannot reach, so a closed lid keeps
running. Every flip tries `sudo -n` first and falls back to one
`osascript … with administrator privileges` call, so the switch works with no
grant at all. An **optional one-time grant** installs a NOPASSWD sudoers rule
scoped to those two exact command lines, which is what buys silent flips, the
5h/12h auto-sleep timers (plus a Custom… quarter-hour stepper, 15 min–24 h,
remembered in `Prefs.lidCustomMinutes`), and the restore-on-quit — install it by validating a
dot-prefixed staged file with `visudo -cf` **before** renaming it into place, never
the other way round: a malformed file in `/etc/sudoers.d` makes sudo refuse to
parse its config at all. The switch defaults hidden (Rule B), the panel states the
risk, and `refresh()` reads the live value on every open. **Pear never enables
the lock by itself**: `setLidClosed` is the only writer of `disablesleep 1` and is
reached only from a tap or a session button, and `lidClosedIsOurs` records whether
this app was the one that set it, so a lock somebody else set is displayed but left
alone at quit. Four tests hold that line. Prior art:
[awake](https://github.com/pistachionet/awake) (MIT), mechanism only), **Clean Mode**
(screen blanker, default OFF), **RunCat** menu-bar runner.
Shortcuts (macOS 14+) and Spotlight (26+): eight App Intents in
`Intents/PearIntents.swift` plus a `PearShortcuts` App Shortcuts provider — Capture
Region, Capture Full Screen, Capture Window, Grab Text, Pick Color, Toggle Keep
Awake (returns the new state), Add File to Shelf (copies the file in, opens the
shelf) and New Scratchpad Note (optional text). Each resolves its tool through
`ToolRegistry.runnableTool(id)`, the registration gate, so a tool that is off or
paywall-locked throws `ToolUnavailable` ("<Tool> is turned off in Pear Settings",
`IntentResolutionTests`), then calls the entry point its hotkey uses. The system
constructs intents itself, so the app delegate sets `ToolRegistry.live` at launch;
an action arriving before that fails with "Pear is still starting". No intent sets
`openAppWhenRun`: Pear is an accessory app with no window to bring forward and
every one of these tools already runs from the background, as a hotkey does.
**Control Center control** (macOS 26+ only; 14–15 never load it): a Keep Awake
`ControlWidgetToggle` in its own WidgetKit extension, target `PearControl`,
embedded by `build.sh` as `Contents/PlugIns/PearControl.appex` (bundle ID
`com.rawsalmon69.pear.companion.control`). The sandboxed extension owns no state
and cannot hold a power assertion, so it talks to Pear over a **Darwin-notification
channel** (`PearControlChannel` target, `KeepAwakeChannel`, tested in
`KeepAwakeChannelTests`): a tap posts `…keepawake.request.on/off`, and Pear publishes
Keep Awake as the notify state of `…keepawake.state`. No app-group container, so
non-sandboxed Pear never risks the macOS 15+ container prompt. `SwitchesTool.start()`
(26+, not under tests) opens Pear's end; a request goes through the same
`setKeepAwake` a grid tap does, and every change from any surface (grid, the
Toggle Keep Awake action, the control, teardown) is published and followed by
`ControlCenter.reloadControls(ofKind:)`, so the control and the Switches grid stay
in step both ways. notifyd drops a name's state with its last token, so **Pear not
running, or the Switches tool turned off** (`stop()` publishes off and closes the
channel) reads as off, and a tap then has nobody to hear it and snaps back: the
control can never turn Keep Awake on without Pear holding the assertion. The
control does not launch Pear. Hiding Keep Awake from the grid does not remove the
control; adding or removing it is done in Control Center itself. Its intent sets `isDiscoverable =
false`, since Pear's Toggle Keep Awake already covers Shortcuts. Proven on this
machine: a sandboxed probe read the published state and its request reached an
unsandboxed host. Known ceiling: after a crash Control Center may show the last
state until it next asks; `currentValue()` is then already off.

## Key decisions & invariants

- **Pear.app is a commercial product, so its source must stay
  proprietary-compatible.** Vendor only MIT / Apache-2.0 / BSD code — never GPL,
  AGPL or CC-BY-NC, no matter how good the feature is. Loop-derived window
  snapping and DockDoor-derived Dock Preview were removed in `9cff06e`; the two
  small helpers those features shared with Clean Mode and KeyClu were then
  reimplemented from their call sites, clean-room. Every notice left in
  `Resources/Licenses/` is permissive. **Never strip an attribution while
  tidying** — over-crediting is free, removing credit is the only move that adds
  risk. Apache-2.0 §4(b) additionally obliges us to state, prominently, that we
  changed the files we redistribute: `Resources/Runners/NOTICE.txt` is that
  statement and it ships in the bundle. **If you modify vendored Apache-2.0 code
  or assets, add it there in the same change.**
- **Before flipping `FeatureFlags.paywall`**, run `companion/scripts/launch-preflight.sh`
  (fails loudly on each unmet precondition) and
  `companion/scripts/issue-lifetime-licences.sh <emails-file>` (one `.pearlicense`
  per existing install). The second is not optional politeness: the bundle ID has
  never changed, so everyone who was *given* Pear auto-updates into the paid build
  and, without a licence, just watches their trial run out.
- **The app has no cleanup feature and invokes no third-party binary.** Paddle
  declined the merchant application in 2026-08 on a "Technical Support/Device
  Cleaner" categorisation, so the Cleanup tool, the include-system-caches setting
  and the whole `pear` CLI resolution/version gate were removed. Everything the
  app shells out to now is Apple's own (`screencapture`, `defaults`, `killall`,
  `open`), through the `CommandRunner`/`ScreenCapture` seams. **Do not reintroduce
  a cleanup, optimisation or "fix your Mac" feature** — it is the thing that got
  the product declined. The GPL CLI still exists, separately and free, and the app
  no longer knows about it.
- **Licensing is offline, asymmetric, and fails in a chosen direction.** $19 (rising
  to $29), perpetual for all 3.x, sold direct through Paddle. 14-day trial, no
  account or card. The app verifies an **Ed25519-signed licence** against a public
  key baked into `LicenceKey.publicKeyBase64` — there is **no activation server**,
  so it works offline forever and survives Paddle disappearing. Rules that must not
  be softened:
  - **Never HMAC or any shared secret.** A symmetric key verified in-app ships the
    signing secret in the binary, and one extraction is a keygen for everybody.
  - **The stored artefact is the signed licence string**, re-verified every launch.
    There is deliberately no `licensed = true` boolean anywhere to flip.
  - **The revocation list fails open in every failure mode** — network error, 404,
    bad JSON, bad signature, dead domain, unparseable date, stale serial. A
    refunded user keeping the app is an acceptable loss; a paying user locked out
    by a DNS blip is not. It is sticky and monotonic in the other direction: once
    revoked, never un-revoked, and an older `serial` can never roll it back.
  - Licence and revocation signatures are **domain-separated** (`pear-licence-v1`
    / `pear-revocation-v1`) via `SigningDomain`, so neither can be replayed as the
    other. One assembly point; do not add a second.
  - **The private key never enters this repo.** `companion/scripts/license-keygen.sh`
    generates it under `~/.pear-licensing/` and refuses any path inside a git repo
    or worktree. macOS's `/usr/bin/openssl` is LibreSSL and **cannot do Ed25519** —
    the scripts probe for a capable one and tell you to `brew install openssl@3`.
  - The committed public key is a **placeholder** whose private half was never
    written to disk. While it stands, licences fail closed and the revocation list
    fails open. It is a real curve point rather than zeros on purpose: an all-zero
    Ed25519 public key is a small-order point that *accepts forged signatures*.
- **The app is FREE right now, and stays that way until the owner says otherwise.**
  `FeatureFlags.paywall` is off, so nothing locks, the trial clock never starts,
  no revocation request is made, and **no licensing surface is visible** — the
  Settings Licence page is filtered out by `SettingsPage.visible`, and
  `SettingsPage.resolved` turns a stored or requested `licence` into General. The
  licensing code is complete and tested, deliberately dormant. Do not flip the
  flag, do not surface the pane, and do not ship a build that does either without
  an explicit instruction. Two tests in `EntitlementRolloutTests` fail if a free
  build starts offering licensing UI.
- **`FeatureFlags.paywall` gates the lock, and the rollout order is load-bearing.**
  While it is off, the licensing code is fully present and testable but nothing
  locks **and the trial clock never starts** — reading the trial is what begins
  it, so a pre-launch build that consulted it would burn everyone's 14 days and
  lock them out the moment the flag flipped. Flip it only after, in this order:
  the owner's real key is pasted into `LicenceKey`, `site/revoked.json` exists,
  the privacy policy lists the third network connection, and every existing
  friends-and-family install has been issued a licence. The bundle ID has never
  changed, so those installs auto-update through the same appcast.
- **The paywall is one gate, in `ToolRegistry`.** `isLocked` + `Tool.survivesExpiry`
  decide registration, so a locked tool never claims a hotkey and never has
  `start()` called — the same mechanism that already makes a user-disabled tool
  inert. **Do not add `if licensed` checks to individual tools.** `ScratchpadTool`
  and `ShelfTool` set `survivesExpiry = true` because `site/terms.html` §2 promises
  in writing that notes and shelf items stay accessible and exportable after the
  trial ends; that is a commitment, not a preference. Saved screenshots need no
  exemption — they are plain files in a folder.
- **Bundle ID `com.rawsalmon69.pear.companion`, SPM module `PearCompanion`, the
  resource-bundle name, and entitlements/provisionprofile filenames MUST NOT
  change** — changing the bundle ID breaks Sparkle auto-update, the CloudKit
  couple, and provisioning. The app is user-facing "Pear" (exec/.app/zip renamed);
  the module stays `PearCompanion`.
- **Anything that mutates system state or covers the screen on launch is opt-in
  (default OFF)** — the menu-bar hider shipped default-ON once and hid the app's
  own icon. Never live-smoke screen-covering features (Clean Mode, overlays) on
  the owner's machine.
- **Native primitives over custom.** Vision for OCR/segmentation, NSColorSampler,
  ScreenCaptureKit for thumbnails, `screencapture -i` for region capture. Don't
  replace a bulletproof system path with custom code for a nice-to-have.
- **Visual values come from `Theme`** (`Support/Theme.swift`): `Theme.Radius`
  (6/10/16), `Theme.Typography` (10/11/12/13/15/20, rounded, nothing below 10 pt; 12 is
  `callout`, Apple's macOS callout size),
  `Theme.Space` (4/8/12/16/24) and `Theme.edgePadding` (14, every popover/panel
  edge). `glassCard` and `clipToCard` both default to `Theme.Radius.large` (16),
  so a borderless panel that takes both defaults cannot drift into a ghost
  border. Sibling glass cards go in a `GlassGroup` (`GlassEffectContainer` on
  macOS 26+, pass-through on 14–15); never glass inside glass. **The migration
  is complete and the old names are gone** (`sectionGap`, `itemGap`,
  `cardPadding`, `heroPadding`, and the fonts `caption`/`body`/`emphasis`/
  `title`/`hero`); `Theme.rounded` is private, so fonts come from
  `Theme.Typography` (or `Typography.Size` with `.system(size:design:)` /
  `Theme.roundedNSFont` where the face must stay monospaced, plain or AppKit).
  **The grep rule:** from `companion/`,
  `grep -rnE "cornerRadius: *[0-9]|cornerRadius *= *[0-9]|\.system\(size: *[0-9]|systemFont\(ofSize: *[0-9]|NSFont\([^)]*size: *[0-9]|Theme\.rounded\([0-9]|\.padding\([^)]*[1-9]|spacing: *[1-9]|Path\(roundedRect:[^)]*cornerRadius: *[0-9]" Sources | grep -v Support/Theme.swift`
  must hit only **commented exceptions**: a comment on the line itself or in
  the two lines above, saying why (Markup's image-pixel text and its draft box,
  treemap tile corners, the card toolbar's 2 pt gaps, the 1–2 pt hugs of a
  label on its value, illustration glyphs). Zero (`spacing: 0`, `.padding(0)`)
  is not a scale value and needs no comment. Window, thumbnail and popover
  `.frame` sizes, shadow radii, chart and ring geometry, and window-placement
  margins are layout, not tokens.
  **Every tool popover opens with `PopoverHeader`** (`Support/Theme.swift`:
  the name at 15 pt semibold, then any popover controls, then the
  `ToolSettingsLink` when the tool has options). A tile or card that sits on
  glass (Switches tiles, the Menu Bar how-to, Color Picker's format and
  contrast cards, the panel's note and setup cards) takes `.flatSurface()`
  (`Views/Materials.swift`, the `.quaternary.opacity(0.5)` fill), never
  another `glassCard`, since the popover or panel chrome is already the glass.
  The AppKit HUDs (copy toast, window ring, snap preview) are migrated too:
  they take `Theme.Typography.Size` (the same 10/11/12/13/15/20 as `CGFloat`) via
  `Theme.roundedNSFont`, since AppKit has no SwiftUI `Font`; the ring's radii
  and its circular clip are hit-test geometry, not radius tokens.
  **Four standard windows** besides Settings: the screenshot detail, Markup,
  Remove Background and Disk are plain titled windows (titled, closable,
  miniaturizable, resizable, standard title bar and background, normal level),
  shown with `makeKeyAndOrderFront` + `NSApp.activate`. The detail window opens
  centred on its card's screen, so focusing it does not move the preview stack.
  Markup opens sized for and centred on the screen under the pointer (where its
  button was clicked), else the key window's, else `NSScreen.main`; never the
  key window first, since the card or detail window has already closed and the
  key window may be Settings or Disk on another display. Never via `center()`,
  which picks whichever screen the zero origin lands on.
  Preview cards stay non-activating borderless panels; their action bar (and the
  Disk treemap tooltip) sits on glass, so it takes a flat
  `windowBackgroundColor` fill, not more glass. Window Shot's icon is
  `macwindow.and.cursorarrow` (SF Symbols 5, macOS 14), distinct from Windows'
  `macwindow.on.rectangle`.
- **Accessibility: every control has a spoken name, and motion obeys Reduce
  Motion.** Every tile, row, recent thumbnail, glyph button and card action gets
  an `accessibilityLabel` — an icon-only button's `.help` string is not one.
  `GlyphButton` and `PreviewAction` label themselves from their `help:`, so new
  call sites get it free; a picker or toggle with a hidden label still passes a
  real title (`Picker("Auto-hide after", …).labelsHidden()`, never `""`). The
  preview card keeps its hover-only actions up while VoiceOver is on
  (`VoiceOverState`, live from KVO on `NSWorkspace.isVoiceOverEnabled`; the
  SwiftUI environment value is unproven in a non-activating panel), since
  VoiceOver cannot hover; for the same reason VoiceOver pauses the cards'
  auto-dismiss, re-armed when it turns off (`PreviewStackLayout.autoDismisses`,
  tested). **Every spring is passed through
  `Theme.motion(_:reduce:)`** with `@Environment(\.accessibilityReduceMotion)`
  (a short ease under Reduce Motion); a view that slides in switches its
  transition to `.opacity` there too (`NotesSection`). The one exception is the
  mascot bounce, which does not run at all under Reduce Motion:
  `grep -rn "\.spring(" Sources | grep -v "Theme.motion(.spring"` hits only
  `MascotView`. Under Reduce Motion its blink loop (a `.task` keyed on the
  setting alone, so a mood change keeps the 3.5 s cadence) is never started. AppKit surfaces read `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`
  (the preview stack's `animate` already does). **Focus blockers**
  (`.focusable(false)`, `.focusEffectDisabled()`) are allowed in the panel only on
  `ToolRow` and `PinnedTile`, which the search field's ↑ ↓ ↩ already reach;
  everything else there (Fix, Open Settings, the Pick-your-four close, the recent
  thumbnails, the bottom bar's glyph buttons) is a Tab stop under Keyboard
  navigation. Blockers outside the panel (preview-card actions, detail window,
  Settings rows, tool popovers) predate this rule and are not keyboard-audited.
- **HD background removal** is opt-in: default is Apple Vision (instant, no
  download). Turning on "High-quality mode" downloads a **BEN2 Base** Core ML
  fp16 model (~205MB) from the project's GitHub release (`ben2-bg-model-v1`,
  three flat assets rebuilt into an `.mlpackage`), cached in Application Support,
  removable, with a Vision fallback. License is **MIT** (BEN2 Base, Prama LLC —
  commercial use OK) — see `Resources/Licenses/BEN2-NOTICE.txt`. Replaced the
  old RMBG-2.0 model (CC-BY-NC, which blocked monetization) on 2026-07-23. Model
  I/O: input `[1,3,1024,1024]` ImageNet-normalized NCHW (the app normalizes);
  output is a **0..1 sigmoid matte** (already sigmoided — do NOT sigmoid again).
  The matte is bilinear-upsampled and multiplies **every** channel of the
  premultiplied buffer (alpha alone un-premultiplies into a bright halo), and
  both engines decode through `BackgroundRemovalService.decode` (EXIF
  orientation baked in) and keep the source's DPI; the HD output also keeps
  the source colour space (`HDMatteCompositeTests`, `BackgroundRemovalIOTests`).
- **Captures are files, not bytes.** A capture is filed the moment it is taken:
  into the user's screenshot folder when auto-save is on, otherwise into
  `~/Library/Application Support/PearCompanion/Captures` (`CaptureStore`,
  7-day retention swept at launch, and again by a run's first capture and then
  a capture at most once a day, keeping the files behind live cards and the Recent
  strip — `CaptureStore.sweepDue`). `ScreenshotService.deliver`, the one point
  every capture mode passes through, records the filed URL in
  `Prefs.recentCaptures` (plain paths, newest first, deduped, last 10) for the
  panel's strip, which drops missing files on read and holds only small
  thumbnails, never the image. Preview cards and the detail window hold
  that URL plus a thumbnail and re-read the file per action — holding the PNG
  for a card's lifetime cost 30–200 MB resident for a stack of 6K shots. Never
  put the bytes back on the card, and never point a card at `NSTemporaryDirectory`:
  macOS reaps it on its own schedule, which is exactly why the bytes were held.
  A failed read dismisses the card (with `.discard`) rather than leaving buttons
  that do nothing. A Markup edit keeps the capture's points-per-pixel
  (`NSImage.keepingScale`, crop included), so a Retina shot stays 144 dpi and
  does not paste at twice its size in Pages, Keynote or Mail. Markup's undo and
  redo (⌘Z / ⌘⇧Z) walk one snapshot history, crop included (`MarkupHistory`,
  tested); ⌘Z with a text draft open discards it, and ⌘⇧Z puts it back as text.
  Esc, ⌘W, Cancel and the close button all go through `windowShouldClose`, which
  asks "Discard your markup?" in a sheet when anything is undoable or a draft
  has text (`markupNeedsDiscardConfirmation`, tested); Keep Editing holds Esc and
  Discard holds no key, so no keystroke throws work away. One constant
  (`MarkupWindowController.minContentWidth`, 700 pt, the toolbar's width) is
  both the opening-width floor and `minSize`, since `minSize` never grows a
  window already created.
- **Floating-window positioning**: the screenshot preview opens on **the screen
  the shot was taken on** and thereafter **follows the focused window's display**
  (`ScreenshotPreviewController.anchor`, pure and tested — one decision for both:
  the first of captured, focused, current display still plugged in, else the
  menu-bar display). The anchor is a **display id** (`CGDirectDisplayID` from
  `NSScreenNumber`), never a `visibleFrame`, which moves with the Dock and menu
  bar; the live frame is read at layout time. App activation is the trigger,
  read 150 ms later because `NSScreen.main` tracks the new key window and AppKit
  has not always installed it when the notification lands; switching windows
  *within* one app across displays does not move the stack.
  `didChangeScreenParametersNotification` (unplug, resolution, arrangement, new
  primary) re-resolves the anchor by id and re-lays out the stack. A card with
  no screen (a re-present after markup or background removal, a Recent-strip
  open) joins a non-empty stack where it is; into an **empty** stack it opens on
  the focused screen (`NSScreen.main`), never the emptied stack's stale display.
  The detail window opens on the stack's display, not the card's
  `panel.screen`, which reads the off-screen slide-in start frame. Eviction on
  follow / screen change spares a card whose detail window is open
  (`PreviewStackLayout.evictionVictims`), so moving never closes what the user
  is reading, and re-runs (next main-actor turn) when that window closes, so a
  spared card never lingers off-screen; a new capture still evicts outright.
  Scratchpad still opens on the primary display. Menu-bar hider
  seeds its separator positions only when unset so the user's layout survives
  updates.

## Release

Tag-driven: push a **`companion-v*`** tag → `companion-release.yml` builds, signs,
notarizes, publishes a GitHub release, and pushes a Sparkle **appcast** commit to
`main`. Steps every release:

1. Bump **BOTH** `Resources/Info.plist` `CFBundleShortVersionString` (marketing)
   AND `CFBundleVersion` (build integer) — Sparkle compares the integer; forgetting
   it means no update is offered.
2. Commit, `git push origin main`, tag `companion-vX.Y.Z`, push the tag.
3. Wait for CI (`gh run watch`), verify conclusion is `success` and the appcast
   entry has `sparkle:version` == the new build integer.
4. `git pull --rebase origin main` afterward — CI pushed the appcast commit.

Channels: companion GitHub release + appcast only. The CLI (nightly/Homebrew) is
untouched by companion changes. Restate channel scope and confirm with the
maintainer before tagging.

**Control Center control extension: `build.sh` does all of it**, no Xcode project.
`PearControl` is a second `executableTarget` in this package (platforms stay
`.v14`) with `swiftSettings: .unsafeFlags(["-application-extension"])` and
`linkerSettings: .unsafeFlags(["-Xlinker", "-application_extension"])`; its
`@main WidgetBundle` supplies `main`, so no `-e _NSExtensionMain`. The test target
links only `PearCompanion` and `PearControlChannel`, never the extension. `build.sh`
runs the same App Intents metadata step for the `PearControl` module as for the
app (`intents_metadata`, one const-values file per module, a missing one fails the
build), so the appex carries its own `Metadata.appintents` with
`SetKeepAwakeIntent`. It assembles `Contents/PlugIns/PearControl.appex/Contents/{MacOS,Resources,Info.plist}`
from `Resources/PearControl-Info.plist` (`CFBundlePackageType XPC!`,
`NSExtension.NSExtensionPointIdentifier = com.apple.widgetkit-extension`,
`LSMinimumSystemVersion 26.0`; both version fields copied from the app's, so a
release still bumps only `Resources/Info.plist`), and signs the appex before the
app with the shared `sign()` (`--options runtime --timestamp`) plus
`Resources/PearControl.entitlements` (`com.apple.security.app-sandbox` only).
The release workflow needed no change: it only calls `build.sh` to sign, and it
notarizes the zipped app, which covers the nested appex. Spike evidence
(2026-10-18), signed with the real Developer ID and no keychain prompt:
`codesign --verify --deep --strict -vvv` reported "valid on disk / satisfies its
Designated Requirement"; `spctl -a -vv` reported "rejected, source=Unnotarized
Developer ID", expected before notarization. After `lsregister -f` (a
full Pear build also needed `pluginkit -a <appex>`), `pluginkit -mAvvv -i <appex id>` listed
it with `SDK = com.apple.widgetkit-extension` and `Parent Bundle` = the host, and
in the spike chronod logged `Added extensions: [<WidgetExtension - identifier: <host id>::<appex id> … isApple: false>]`,
the same record a shipping third-party widget gets. Both checks used throwaway
bundle IDs, unregistered afterwards. Provisioning (reasoned, not notarized): the
appex needs no profile. App-sandbox and team-prefixed app groups are unrestricted
on macOS under Developer ID; only `group.`-style IDs need profile authorisation,
and the control uses no group at all. `PearCompanion.provisionprofile` stays
app-only. **Owner checks:** (a) the control shows in Control Center's gallery and
toggles in step with the Switches grid (chronod fetches descriptors lazily, so
this needs the GUI). (b) A real 14/15 install ignores the appex. (c) The notary
verdict on the first tagged build. Side finding: Xcode 27's default SwiftPM
backend stamps `LC_BUILD_VERSION sdk 14.0` (the deployment target), while CI's
Xcode 26 and `--build-system native` stamp the real SDK. Check
`xcrun vtool -show-build` when SDK-gated behaviour differs between a local build
and CI; a local Xcode 27 build of the appex carries `sdk 14.0`, the release one
does not.

## Gotchas (each cost real time)

- **Sparkle version**: bump both plist version fields; appcast `sparkle:version`
  = the CFBundleVersion integer, not the marketing string.
- **`Bundle.pearResources`, never `Bundle.module`** — the generated `.module`
  accessor differs by toolchain and crash-loops the notarized app at launch while
  every local build works.
- **Tiny floating panels: pure AppKit, not SwiftUI.** Hosting a SwiftUI
  `NSHostingView` with glass/material as a small `NSPanel` contentView on macOS 26
  can enter an unbreakable constraint-invalidation loop → crash. Toasts/HUDs =
  `NSVisualEffectView` + explicit frames.
- **Never `setFrame`/resize a window from inside `layout()`** — defer one runloop
  turn (re-entrant constraint pass crashes).
- **Every new `NSStatusItem` needs an `autosaveName` + a right-edge position
  seed**, or the menu-bar hider's length trick eats it.
- **Core ML numbers for BEN2, measured — do not re-guess them.** Loading the
  compiled model plus one inference costs **+15-20 MB** of phys_footprint, NOT
  the ~160 MB a `vmmap` MALLOC_SMALL line implies: Core ML memory-maps the fp16
  weights, so they are clean, evictable, file-backed pages. `compileModel` costs
  0.24s and writes a fresh **196 MB copy into the temp directory on every call**,
  so the compile is cached in Application Support and its output MOVED there;
  reloading from that cache is 0.08s. Consequence: the model is loaded per cutout
  and never retained, and nothing about it is compiled or loaded at launch.
- **HD bg model (BEN2) must load with `computeUnits = .cpuOnly`.** Verified by
  PyTorch-vs-CoreML parity: `.all`/ANE is wrong (maxΔ 0.89, 26s compile),
  `.cpuAndGPU` **miscomputes** it (NaN mask), `.cpuOnly` matches the reference
  (fp16-level, ~1s load, ~1.6s inference). Same pattern the old RMBG model had —
  don't "optimize" it back to `.all`/ANE. Conversion recipe (torch.export +
  run_decompositions + a bitwise_not→logical_not op override) is in root memory.
- **Verify the shipped zip by directly launching it** (not just spctl/stapler) —
  toolchain/launch bugs pass every other check.
- **Footprint metric**: `top -l1 -pid N -stats mem` (Activity Monitor number),
  NOT `ps` RSS (counts shared framework pages; ~2-3× inflated on macOS 26).
- **A reused AppKit window never re-fires SwiftUI's `.onAppear`/`.task`/`.onDisappear`.**
  With `isReleasedWhenClosed = false`, `close()` + a later `makeKeyAndOrderFront`
  leaves the hosting view in the hierarchy the whole time, so a view-owned engine
  started in `.onAppear` stays stopped after a reopen and one cancelled in
  `.onDisappear` is *never* cancelled on close. Any window with a running engine
  owns that engine on the **controller** and drives it from `show()` /
  `windowWillClose` (see `DiskWindowController`).
  Measured, not assumed — a probe printed one `onAppear` across close/reopen and
  no `onDisappear` at all.
- **Never store a closure on a `@State`-owned object if the closure writes that
  view's `@State`.** The closure captures the view struct, the view's `State` box
  owns the object: an unbreakable cycle that leaked a whole screenshot (decoded
  `NSImage` + PNG `Data`) per detail-window open. `State.wrappedValue`'s
  `nonmutating set` is what lets it compile. Expose an observed value and use
  `.onChange` instead (`ZoomController.lastPick`/`pickCount`).
- **A non-activating `NSPanel` never loses focus, so it never auto-closes.**
  `screencapture` does not steal key status from one, so `panelClosesOnFocusLoss`
  never fired and the companion panel sat over — and inside — every capture
  started from a tile. Every capture now posts `pearHideForCapture` from
  `ScreenCapture` (one seam, so hotkeys and any future caller behave the same);
  the panel closes for good and the preview stack comes back on
  `pearRestoreAfterCapture`. Register those observers with **`queue: nil`**: with
  `queue: .main` the block is enqueued and can run after `screencapture` has
  already started, which is the bug. Full-screen capture additionally waits
  160 ms for the window server to actually drop the panels; the interactive modes
  get that for free while the user is still dragging. **One capture at a time,
  app-wide**: `ScreenCapture.gate` (`CaptureGate`, tested) silently refuses a
  capture while another is in flight, so restore is only ever posted by the one
  that hid; each screenshot mode, OCR and QR owns its own service, so a
  per-service flag let ⌃⇧S then ⌃⇧W run two and the first finisher brought the
  cards and pins back over the second.
- **`@Observable` does not compare before notifying.** Writing the same value
  still invalidates every view that read it. Anything written per input event —
  a zoom readout, a scroll offset, a live counter — must dedupe (`guard new !=
  old else { return }`), or a pinch re-renders the whole window dozens of times
  per second on the same main thread the gesture is delivered on.
- **`magnify(with:)` is not the only zoom path.** ⌘-scroll and two-finger
  magnify-by-scroll are handled inside AppKit's `scrollWheel` and never reach it,
  so a flag set from `magnify` misses them entirely. Derive "the user owns the
  zoom" from the magnification itself (compare against the fit you applied), not
  from having intercepted the right event. Shipped broken in 2.14.0: a scroll
  zoom was discarded by the next layout pass and read as a dropped gesture. The
  zoom readout follows the same rule: it reports from `reflectScrolledClipView`,
  which AppKit calls on every clip-bounds change whatever drove it, not from the
  intercepted paths (it went stale on ⌘-scroll until it did).
- **An overridden `layout()` runs constantly.** It fires on every layout pass, so
  anything expensive or geometry-changing inside it must be gated on the geometry
  having actually changed. A fit that re-ran unconditionally cost six fits per
  six passes and fed a re-render loop through the observable above.
- **`swift build` incrementally does NOT show you the warnings.** A rebuilt module
  reuses cached diagnostics, so a file that warns can look clean for the rest of
  the session — and a subagent reporting "zero warnings" may simply never have
  done a cold build. `rm -rf .build` before believing a warning-free claim. Two
  real warnings in `AXWindowMover` (raw pointers to an unconstrained generic)
  survived an agent's whole task this way.
- **AX position is top-left-origin, `NSScreen` is bottom-left-origin**, and the
  flip must pivot on the **primary** display's height, never on the height of the
  display the window is on. Pivoting locally looks perfect on a one-display Mac
  and lands windows onto the wrong screen on any other. `WindowSpace.flip` is the
  one conversion; it is its own inverse, which is why there is no `toAX`/`toAppKit`
  pair to drift apart.
- **Snap frames must round the four edges, not origin-and-size.** Rounding a width
  independently gives left-half + right-half = screen + 1px, which shows as a
  hairline of desktop between two snapped windows. `WindowZoneMath.snapped` rounds
  `minX/maxX/minY/maxY` so complementary zones land on the same integer at any
  width. The thirds constants must stay `1.0/3.0` and `2.0/3.0` literally — spelling
  the second `1 - third` is a different double and the pair stops meeting.
- **One app's window will not take one `setFrame`.** Many apps clamp a resize
  against their current position, others clamp a move against their current size,
  so `AXWindowMover` sets position → size → position, reads back, and retries once
  in the opposite order. Two passes only: a second miss means the app genuinely
  refuses (Terminal quantises to character cells), and pushing further is fighting it.
- **A process-wide static set by a test leaks into every later test.**
  `CleanModeController.isAnyActive` is consulted by the window trigger, and three
  CleanMode tests used to end still-active, so 13 unrelated tests failed on suite
  order alone. Any test that flips a global must undo it in a `defer`.
- **The legacy Keychain ignores `kSecUseAuthenticationUIFail`.** A keychain item is
  ACL'd to the code identity that created it, so on a *dev* build every rebuild is
  a new identity and the read hits a "wants to use your confidential information"
  prompt — which that flag does not suppress (measured: the dialog appeared
  anyway). Signed builds share one Developer ID identity and never see it. Any
  Keychain read must therefore treat failure as *no evidence*, never as a negative
  answer, and have a second store behind it (`TrialState`). Do not reach for
  `kSecUseDataProtectionKeychain` to dodge this: it needs a `keychain-access-groups`
  entitlement the app does not carry, and getting it wrong fails silently in
  production only.
- Interactive panel/overlay smoke is the **owner's** job — this box's screencapture/
  CGWindowList are permission-gated and AX-driving fights his live session.
