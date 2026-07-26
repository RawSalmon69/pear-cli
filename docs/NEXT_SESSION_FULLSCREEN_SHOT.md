# Next session — full-screen instant screenshot hotkey (companion)

## Goal

Add a hotkey that captures the **whole screen instantly** (no region drag),
alongside the existing region capture. Same downstream flow: shutter sound,
auto-save, clipboard, floating preview card (markup / background-remove / QR /
send). Region capture (⌃⇧S) stays exactly as-is; this is **additive**.

This lives in `companion/` (Pear.app). Read `companion/AGENTS.md` first.

## Why it fits (product filter)

Belongs to the existing **Screenshot** tool's scope (capture → preview). Low
risk, testable without auth, native primitive (`screencapture`), one-screen
explainable. No new surface beyond a second capture mode + a rebindable hotkey.

## The code (all grounded — these exist today)

Capture path is three layers; add a full-screen sibling at each, reusing the
region pipeline:

1. **`Services/ScreenCapture.swift`** — the seam. Currently:
   ```swift
   static func region(to url: URL, muted: Bool = true) async -> Bool { … }
   // runs: /usr/sbin/screencapture  ["-i","-x", path] (muted) or ["-i", path]
   ```
   Add a sibling:
   ```swift
   static func fullScreen(to url: URL, muted: Bool = true) async -> Bool { … }
   // same Process, args: muted ? ["-x", path] : [path]   (no "-i" = full screen)
   ```
   `screencapture -x <path>` grabs the **main display** silently; drop `-x` for
   the shutter sound (matches `region`'s muted convention). Multi-display
   nuance: bare `screencapture` captures the main display only; capturing every
   display means one file per path. Ship **main display** first (simplest, what
   users mean by "the screen"); note multi-display as a follow-up if asked.

2. **`Services/ScreenshotService.swift`** — `func capture()` calls
   `ScreenCapture.region(...)` then persist → clipboard → preview. Refactor so
   the post-capture half (persist/`copyToPasteboard`/`present`/temp cleanup) is
   shared, and add `func captureFullScreen()` that calls
   `ScreenCapture.fullScreen(...)` then runs the **same** shared tail. Do NOT
   duplicate the persist/preview logic — extract it.

3. **`Tools/BuiltinTools.swift`** — `ScreenshotTool` (id `"screenshot"`, hotkey
   `⌃⇧S`, `entry = .action { … capture() }`). Add a second tool, e.g.
   `ScreenshotFullTool` (id `"screenshot-full"`, title "Full-screen shot",
   category `.capture`, `entry = .action { … captureFullScreen() }`), sharing
   one `ScreenshotService` (reuse `resolveService()` — consider hoisting it so
   both tools share the same instance + `onMarkupRequest` wiring). Register it
   in the launch tools list wherever `ScreenshotTool` is added (ToolRegistry /
   AppEnvironment.live()).

4. **Hotkey** — declare `let hotkey = HotKeyChord(keyCode:modifiers:label:)`.
   Default suggestion **⌃⇧F** (`kVK_ANSI_F, controlKey | shiftKey, "⌃⇧F"`).
   Verify no collision with existing chords: ⌃⇧S/T/C/P/Q/V/N/K and Fn (Windows).
   It's rebindable through the registry like every other tool hotkey.

## Constraints / gotchas

- Keep `screencapture` as the capture primitive — do NOT reimplement with
  ScreenCaptureKit/CGWindowList for this (robustness bar; region already relies
  on it). See `[[robustness-over-features]]`.
- Screenshot preview opens on the **primary** display (existing behavior) — no
  change.
- Interactive/overlay smoke is the **owner's** job (this box's screen capture is
  permission-gated). Verify build + tests here; owner presses the hotkey.

## Verify

```bash
cd companion
swift build
swift test        # ~394 tests must stay green; add one for the new capture path if practical
```

## Release (only if owner confirms channel scope)

Feature → bump **both** `Resources/Info.plist` `CFBundleShortVersionString`
(→ 2.10.0) and `CFBundleVersion` (→ next integer). Read
`.claude/skills/release-flow/SKILL.md`. Tag `companion-v2.10.0`, push → CI
builds/signs/notarizes/publishes + pushes the appcast; then
`git pull --rebase origin main`. Channels: companion GitHub release + appcast
only (CLI untouched). Restate channel scope and confirm before tagging.
