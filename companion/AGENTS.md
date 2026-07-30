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
Swift Package, `PearCompanion` target, min **macOS 14**, Swift 6 strict
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
swift test             # full suite (467 tests, must stay green)
./build.sh [version]   # assemble build/Pear.app (unsigned dev bundle); `open build/Pear.app`
```

A bare `.build/release/PearCompanion` binary crashes on launch (needs the `.app`
bundle for UNUserNotificationCenter + resources) — always run via `build.sh` +
`open`. CI (`companion.yml`) runs build+test+assemble on every `companion/**`
push/PR.

## Architecture

- **`Tool` protocol + `ToolRegistry`** (`Tools/Tool.swift`): every feature is a
  Tool — `id/title/icon/category/summary`, an optional rebindable `hotkey`, an
  `entry` (tile action or popover), and `start()`/`stop()` for always-on engines.
  Disabled tools are never registered (their hotkeys/engines never load). Some
  tools default OFF (see invariants). `Tools/BuiltinTools.swift` holds the launch
  tools (Screenshot, OCR, Clipboard, Disk, Panel); the rest live in their own
  `Tools/<Name>/` dirs.
- **`AppEnvironment`** (`Support/AppEnvironment.swift`): inert DI container of
  `@Observable` services, handed to views via `.environment()`. `live()` builds
  the real graph. Views read the one service they need.
- **`PanelController`** (`Views/PanelWindow.swift`): owns the menu-bar status
  item + the companion panel (a non-activating `NSPanel`, replaced the old
  `MenuBarExtra`). Closes on focus loss by default (`Prefs.panelClosesOnFocusLoss`),
  draggable, recreate-per-open so idle cost ~0.
- **Services** (`Services/`): Screenshot, OCR (Vision), BackgroundRemoval
  (Vision + optional HD model), HDBackgroundModel (BEN2 download/manage),
  Clipboard history, CloudKit messaging (flagged off), Stats (`pear status --json`),
  Cleaner (headless `pear clean/optimize` into a panel; opt-in Include-system-caches
  setting passes `clean --system` → native auth dialog), DiskAnalyze, HotKeyManager
  (`.shared`, Carbon hotkeys → tokens), Updater (Sparkle), CommandRunner/ScreenCapture seams.
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
capsule, with a centering clip view and fit as the zoom-out floor — native
AppKit, not custom gesture math), an eyedropper that samples exact image pixels
(`PixelSampler`), the same actions, and a sidebar of
`ScreenshotInsights` — full OCR text in its own scroll box, QR payloads, color
palette, file facts — scanned once off-main *after* the card is on screen, so
nothing delays capture → preview and the window always opens mid-scan. Cards are
**backed by a file, never by bytes** (see `CaptureStore` below). **OCR / Grab Text**
(⌃⇧T, Vision), **Background
removal** (Apple Vision default; opt-in HD BEN2 Core ML — see below), **QR**
(⌃⇧Q, scan screen region / generate from clipboard, auto QR badge + Copy-text
button on screenshot preview cards).
Windows: **Windows** (snap zones + Loop-style radial ring on Fn), **Dock Preview**
(hover a dock icon → window thumbnails, follows the dock edge on any display).
Utilities: **Color Picker** (NSColorSampler + WCAG), **Shelf** (⌃⇧V drop-hold-drag),
**Scratchpad** (⌃⇧N notes, header-drag + text canvas, spawn-position toggle),
**Clipboard history** (pins + search), **KeyClu** (⌃⇧K shortcut cheat-sheet, read-only AX).
System: **Disk** (sunburst/treemap + safe Trash delete), **Monitor** (CPU/mem/net/
battery/SMC), **Menu Bar hider** (Hidden Bar-style, default OFF), **Switches**
(7 toggles — Screen Test was removed after it hard-locked a machine), **Clean Mode**
(screen blanker, default OFF), **RunCat** menu-bar runner.

## Key decisions & invariants

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
- **HD background removal** is opt-in: default is Apple Vision (instant, no
  download). Turning on "High-quality mode" downloads a **BEN2 Base** Core ML
  fp16 model (~205MB) from the project's GitHub release (`ben2-bg-model-v1`,
  three flat assets rebuilt into an `.mlpackage`), cached in Application Support,
  removable, with a Vision fallback. License is **MIT** (BEN2 Base, Prama LLC —
  commercial use OK) — see `Resources/Licenses/BEN2-NOTICE.txt`. Replaced the
  old RMBG-2.0 model (CC-BY-NC, which blocked monetization) on 2026-07-23. Model
  I/O: input `[1,3,1024,1024]` ImageNet-normalized NCHW (the app normalizes);
  output is a **0..1 sigmoid matte** (already sigmoided — do NOT sigmoid again).
- **Captures are files, not bytes.** A capture is filed the moment it is taken:
  into the user's screenshot folder when auto-save is on, otherwise into
  `~/Library/Application Support/PearCompanion/Captures` (`CaptureStore`,
  7-day retention swept at launch). Preview cards and the detail window hold
  that URL plus a thumbnail and re-read the file per action — holding the PNG
  for a card's lifetime cost 30–200 MB resident for a stack of 6K shots. Never
  put the bytes back on the card, and never point a card at `NSTemporaryDirectory`:
  macOS reaps it on its own schedule, which is exactly why the bytes were held.
  A failed read dismisses the card (with `.discard`) rather than leaving buttons
  that do nothing.
- **Floating-window positioning**: dock preview follows the dock edge (picks the
  icon's screen by overlap, never the focused-window screen); screenshot preview
  + scratchpad open on the **primary** display; menu-bar hider seeds its
  separator positions only when unset so the user's layout survives updates.

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
  `windowWillClose` (see `MonitorWindowController`, `DiskWindowController`).
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
  get that for free while the user is still dragging.
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
  zoom was discarded by the next layout pass and read as a dropped gesture.
- **An overridden `layout()` runs constantly.** It fires on every layout pass, so
  anything expensive or geometry-changing inside it must be gated on the geometry
  having actually changed. A fit that re-ran unconditionally cost six fits per
  six passes and fed a re-render loop through the observable above.
- Interactive panel/overlay smoke is the **owner's** job — this box's screencapture/
  CGWindowList are permission-gated and AX-driving fights his live session.
