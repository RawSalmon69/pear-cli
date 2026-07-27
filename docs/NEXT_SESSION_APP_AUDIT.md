# Next session: full audit of Pear.app (companion)

**This is an audit, not a feature session. Ship no new features.** The one
exception is fixing what the audit confirms is broken.

Read `companion/AGENTS.md` first (and the root `AGENTS.md` for repo-wide rules).

## Why

Seven releases went out in one sitting on 2026-07-26/27 — builds 43 → 49
(2.10.0, 2.11.0, 2.11.1, 2.12.0, 2.13.0, 2.14.0, 2.14.1): two new capture
modes, a whole detail window, an insights pipeline, zoom, an eyedropper. Every
one was built, tested (415 green) and shipped **without a single interactive
smoke on real hardware**. Fast is not the same as sound. Nobody has asked
whether the result is well-structured or whether it is slop.

Prior art for how this goes well: the 2026-07-17 whole-app audit (round 11)
ran three parallel read-only auditors, produced ~30 verified findings, and
every confirmed one was fixed the same day — including a privacy bug where
concealed pasteboard items (password managers) were being recorded in
plaintext. Use that shape again.

## Method

1. **Owner smoke first.** Before any code reading, ask the owner to run the
   unverified surface and report what feels wrong: ⌃⇧S, ⌃⇧F, ⌃⇧W, click a
   preview card, zoom (pinch / ⌘+ / ⌘0 / double-click), the eyedropper, the
   palette copy feedback, the extracted-text box. His five minutes outrank any
   amount of static reading. Do not live-smoke screen-covering features on his
   machine yourself — that rule exists because it happened.
2. **Parallel read-only auditors.** Fan out subagents, one lane each, all
   read-only, each returning findings with file:line and a concrete failure
   scenario. Lanes below.
3. **Verify before fixing.** A subagent finding is a starting point, not a
   verdict — this repo has burned time on confident-but-wrong "dead code" and
   "this leaks" reports. Reproduce or disprove each one yourself. Say plainly
   which findings you could not confirm.
4. **Fix confirmed findings**, smallest diff that holds, tests for each.
5. **Report** what was found, fixed, and deliberately left alone.

## Lanes

**A. The new screenshot surface (heaviest weight — it is the least reviewed)**
`Services/ScreenshotInsights.swift`, `Services/ScreenshotService.swift`,
`Views/ScreenshotPreviewWindow.swift`, `Views/ScreenshotDetailWindow.swift`,
`Tools/BuiltinTools.swift`.

Specific suspects already visible, all introduced this session:

- **Memory.** `DetailContext` retains the full PNG `Data` for *every* card in
  the stack, and the stack cap is a user preference. Several full-screen 6K
  shots could sit in RAM at once. Measure it (`top -l1 -pid N -stats mem`,
  never `ps` RSS) and decide whether cards should hold the file URL and
  re-read on demand.
- **Cost per capture.** `ScreenshotInsights.scan()` runs Vision OCR + barcode
  detection + a palette pass on *every* screenshot, including ones the user
  never opens. Measure on a 6K full-screen shot: wall time, CPU, energy. If
  it's material, consider scanning lazily on first detail-open with the card
  badge as the only eager pass — but keep the "window opens mid-scan"
  guarantee either way.
- **Main-thread decode.** `openDetail` does `NSImage(data:)` on the full
  capture on the main actor. Check for a visible hitch on a large shot.
- **Retain cycles / lifetime.** `PreviewEntry` → `DetailContext` → action
  closures → services; `ScreenshotDetailWindowController.onClosed` → entry;
  `ZoomController.scrollView` (weak) versus `ZoomableImageScrollView.controller`
  (weak) with SwiftUI `@State` owning the controller. Prove windows and panels
  actually deallocate.
- **Shape.** `ScreenshotDetailWindow.swift` is 744 lines holding three
  separable things (layout math, the AppKit zoom stack, the SwiftUI view);
  `ScreenshotPreviewWindow.swift` is 584 with a 15-parameter `show()` whose
  parameter list is then duplicated field-for-field in `DetailContext` — two
  places to edit for one new action. Judge whether that is worth splitting
  *now* or is fine; do not split reflexively.
- **Regressions from the first-mouse change.** `PreviewHostingView` now
  accepts first mouse. Confirm swipe-to-dismiss, the hover toolbar, and the
  close button all still behave, and that a click landing on a button never
  also opens the detail window.
- **Zoom edge cases.** Tiny images, very wide panoramas, a re-fit while the
  user has zoomed, `layout()` → deferred `fitToWindow` running more than once,
  and the `minMagnification` floor interacting with a window resize.

**B. Concurrency and lifecycle, app-wide**
Swift 6 strict concurrency is on: look for `@MainActor` hops that are actually
unsafe, detached tasks touching UI state, timers/monitors/observers without a
teardown in `Tool.stop()`, `NSEvent` monitors that outlive their window, and
anything that keeps working after its tool is disabled. The app's own gotcha
list (`companion/AGENTS.md`) names the shapes that have already bitten:
`setFrame` inside `layout()`, SwiftUI hosting views in tiny panels, status
items without an autosave name.

**C. Everything else that isn't new**
Clipboard, shelf, scratchpad, dock preview, windows/radial, menu-bar hider,
monitor, disk, cleaner, KeyClu, switches, clean mode, runner, updater. Look
for the same classes of problem, plus privacy (what gets written to
UserDefaults or disk in plaintext), and dead code — but apply the repo's
three-check rule before declaring anything dead: grep every directory
including entry scripts, check for string-built call sites, re-grep after
removal.

**D. Correctness of the safety-critical bits**
Anything that deletes, moves to Trash, runs `pear` with arguments, or shells
out. `CleanerRunner`'s `--system` path, disk deletion guards, shelf eviction,
scratchpad atomic writes.

## Also worth a pass

- **Docs currency.** `docs/superpowers/specs/2026-07-26-screenshot-detail-view-design.md`
  predates zoom, the eyedropper, and the details expansion. Either refresh it
  or mark it superseded. Check `companion/AGENTS.md` still describes reality.
- **Footprint and idle cost.** Correct metric only: `top -l1 -pid N -stats mem`
  for memory (Activity Monitor's number), a cputime delta over ~30s with
  `-runnerEnabled 0` for idle CPU. Compare against the ~20MB idle / 0.0% the
  app measured at round 11.
- **Bundle size** against the 25MB CI gate.
- **Test quality, not just count.** 415 green tests mean little if some pass
  vacuously. Spot-check for assertions that can't fail (this repo has shipped
  that bug twice), and for behavior with no coverage at all.

## Verify

```bash
cd companion
swift build
swift test          # 415 green today; any drop is a regression
./build.sh && open build/Pear.app   # only with the owner's agreement
```

## Non-goals

No new features. No bundle-ID, module, or resource-bundle renames. Don't
resurrect the parked loupe selector or the removed ⌥-tab switcher. Don't
refactor for taste alone — every change traces to a finding. Release only if
the audit produces fixes worth shipping, and follow the normal
`companion-v*` tag flow (bump **both** plist version fields).
