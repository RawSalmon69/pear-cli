# PearCompanion — Next Session (Round 10) Orchestrator Prompt

Paste this to start the next clean session.

---

You are the Fable orchestrator for PearCompanion round 10. Orchestrate: keep architecture, integration, safety review, and verification in your own Fable main loop; spawn **opus** subagents in isolated git worktrees for parallel or self-contained work. Adversarially verify every agent result — read the diff line-by-line, run `swift build` (zero warnings, NON-incremental — `rm -rf .build` twice, incremental masks warnings) + `swift test`, and for shippable work do `./build.sh` → launch the assembled .app → status-item + footprint check (≤80 MB idle / ~0% CPU) before merging. Commit per feature, push main when verified. Release automatically once fully verified per the standing rule — do NOT wait for per-release confirmation (channels: GitHub release + appcast).

Invoke the **ponytail** skill and keep it active — laziest solution that works, fewest files, shortest diff. "Lazy" = adopt upstream code that already works, not hand-roll a minimal version.

Read FIRST: memory at `/Users/raws/.claude/projects/-Users-raws-Documents-Github-pear-cli/memory/` (every gotcha — especially the macOS-26 NSHostingView toast crash and the lldb technique), then the app under `companion/Sources/PearCompanion/`. Current tip: **companion-v2.6.4** (CFBundleVersion 20, next build is 21). 296 tests, ~15 MB bundle, ~68 MB idle.

## Standing rules (owner, unchanged)
- **A. Copy what works** — vendor upstream UI/logic verbatim where better (GPL/Apache/MIT fine for F&F; provenance headers + license texts in `Resources/Licenses/`).
- **B. Everything toggleable + richly customizable, applied LIVE** — a Settings toggle + options section is part of definition-of-done for every feature.
- **Release when verified** — see `[[release-when-verified]]` memory.

## Hard gotchas — do NOT rediscover
- **macOS 26: NEVER host a SwiftUI `NSHostingView` as a small floating NSPanel's contentView with glass/material content** — it enters an unbreakable AppKit constraint-invalidation runaway (`updateWindowContentSizeExtremaIfNecessary → invalidateTransform → re-mark`) and crashes. Use **plain AppKit** (NSVisualEffectView + NSTextField, explicit frames) for tiny toast/HUD panels. This burned 4 release attempts; the fix is in `ColorToast.swift`.
- **Diagnostic for redacted crashes**: `xcrun lldb -s cmds` with `break set -E objc` + a breakpoint command printing `po (id)$arg1` / `po [(id)$arg1 reason]` / `bt` / `continue` — freezes at the throw and prints the real reason BEFORE AppKit converts it to a crash. `.ips` reasons are `<private>`; `-NSApplicationCrashOnExceptions NO` does NOT suppress it. Isolated repros may not reproduce the positive — the real app context is required.
- **`Bundle.pearResources`** for every resource load, NEVER `Bundle.module` (crash-looped 2.2.0).
- **Dead-agent flake**: agents that spawn with 0 tool uses (instant exit) are dead — spawn FRESH, never resume (a resume writes into the main tree). This session one slot died 3× in a row; keep respawning or do the task inline if small.
- **Every worktree agent's first action**: `git rebase main` + verify HEAD. `git status` before any `git add -A` while agents are in flight.
- **NO private APIs** (the DockDoor line held all session): no `_AX*` brute force, no CoreDock*, no SkyLight. If a feature needs one, flag it and let the owner decide; don't sneak it in.
- Swift 6 strict: @Observable stored props are computed → `@ObservationIgnored` for deinit-touched; AXUIElement/CGEvent/NSStatusItem not Sendable; no `@unchecked Sendable` without written justification.
- Menu-bar / any status item: seed a right-edge "NSStatusItem Preferred Position" on first run or it spawns under the notch on a crowded bar; keep the self-hide guard.
- Release: bump BOTH CFBundleShortVersionString and CFBundleVersion; appcast `sparkle:version` = build integer; shipped-zip gauntlet (spctl + stapler + **direct-exec launch**) is mandatory; notes via `gh release edit` (never create).
- Size gate: 20 MB (companion-release.yml). Keep the bundle lean.

## Round 10 work list

### 1. DockDoor hover reliability (investigate first — root-cause, owner priority)
Owner: "dock preview still only works on hover for SOME apps, and sometimes I have to click the app first (which activates it) and THEN the preview shows up." This is the key bug. Hypothesis: a non-frontmost app's AX window list can come back empty until the app is activated, so the first hover finds nothing; clicking activates it → AX populates → next hover works. Investigate `DockWindows.enumerate` / `DockAX`: does AX need the app frontmost? Is there a public way to enumerate a background app's windows reliably (CGWindowList across the app's pids as a pre-warm, retry-after-delay, or a lightweight AX poke that doesn't steal focus)? The 2.6.0/2.6.3 work already widened subroles + fullscreen + floating windows; this is the ACTIVATION-STATE gap. Public APIs only; document any hard limit honestly. This is a diagnosis-heavy slice — the orchestrator should reproduce/reason carefully, maybe with a scouted DockDoor upstream comparison (re-clone github.com/ejbills/DockDoor).

### 2. DockDoor preview: keep-after-focus-lost toggle
Owner wants a Rule-B setting: whether the hover preview panel stays up after focus is lost, or dismisses. Add to DockDoorSettings + DockDoorSettingsView, live-applied.

### 3. Scratchpad: swipe-to-new-note + hyperlink support (Antinote parity)
- **Swipe to create a new note** like Antinote (github.com/uwaisalim/antinote or the known Antinote app — scout the gesture UX). Scratchpad is currently a single autosaving note; add multi-note with a swipe gesture to create/switch. Keep autosave per note.
- **Link/hyperlink support**: detect URLs and make them clickable (open in browser), and/or allow inserting a hyperlink. NSTextView data-detection or an attributed-string link pass — keep it simple, plain AppKit/SwiftUI text.
Files: `Tools/Scratchpad/`.

### 4. "Switches" tool — OWNER-LOCKED subset of OneSwitch (jaywcjlove/OneSwitch, open source)
Build a new **Switches** tool (its own tile, a grid; each switch individually on/off in Settings per Rule B; system-mutating ones default OFF). Scout the repo for the exact current implementation of each, but build ONLY these eight owner-approved **clean, public-API** switches — nothing private (no CoreBrightness Night Shift/True Tone, no private BT AirPods), nothing destructive (no Empty Trash):
1. **Keep Awake** — IOKit power assertion (prevent display/system sleep).
2. **Hide Desktop Icons** — `defaults write com.apple.finder CreateDesktop` + relaunch Finder (or a covering window; pick the cleaner).
3. **Show Hidden Files** — `defaults write com.apple.finder AppleShowAllFiles` + relaunch Finder.
4. **Screen Saver** — start it immediately.
5. **Lock Screen** — instant lock.
6. **Mute** — system volume mute toggle.
7. **Big Cursor** — accessibility pointer size.
8. **Screen Test** — full-screen solid-color cycle for dead-pixel checks (self-contained).
Any switch that shells to `defaults`/Finder relaunch or `osascript` needs a `PEAR_TEST`-style guard or mock so `swift test` never mutates the real system (repo rule). No private APIs.

### 5. "Clean Mode" — black screen + keyboard lock (OWNER-LOCKED; SAFETY-CRITICAL)
Owner wants a wipe-the-Mac mode (like OneSwitch's clean mode): black out all displays and lock the keyboard so wiping the screen/keys triggers nothing. **Design that CANNOT lock the user out (mandatory):**
- Full-screen black borderless window on EVERY display (high window level, `canJoinAllSpaces`). Pure AppKit, self-contained.
- **Keyboard** swallowed via a session-scoped CGEventTap (the existing `Tools/Windows/KeySwallowTap.swift` pattern — public API, created on enter / invalidated on exit, keyDown+keyUp). **MOUSE STAYS LIVE** — do NOT swallow mouse events.
- Exit is bulletproof and mouse-driven: a visible **"Done" button** on the black overlay (clickable because the mouse isn't locked), PLUS an auto-timeout (e.g. 60 s) and a graceful fallback if the tap can't be created (then don't lock the keyboard at all, just black the screen with the Done button). Never leave the user with no way out.
- Orchestrator: review this one LINE-BY-LINE and actually smoke it (the failure mode is locking yourself out — verify Done + timeout + tap-teardown before merge). Rule-B toggle; default off (system-mutating). Ships with the Switches tool or as its own tile — your call.

### 6. Icon search tool — svgl + IconBuddy (OWNER-APPROVED; network dependency accepted)
Owner: "useful enough." A tool to search/browse icons → copy SVG / drag out. Owner has ACCEPTED the network dependency (a departure from the offline/no-live-deps posture — noted and approved for this tool). Use **svgl's public API (svgl.app/api)** first — open, no auth, no telemetry; cache results; treat IconBuddy (iconbuddy.com) similarly only if it has a clean public API, else skip it. Behind an explicit tool toggle (Rule B). Keep it dependency-light: URLSession + the app's existing Thumbnail/drag-out plumbing, no new SPM packages. No credentials, no analytics, fail gracefully offline (show "needs internet" rather than hang).

### 7. Screen recording — STILL OWNER-PENDING (do not build until greenlit)
Owner hasn't decided yet. Recommendation stands: worth it, fits Capture parity, SCK groundwork exists (SCStream video + AVAssetWriter + start/stop control + region/window/full pick + preview handoff), but it's a medium-large **dedicated slice** — do NOT bundle with the above. If the owner greenlights in-session, run it as its own agent; otherwise leave parked.

## Verification (every change)
`rm -rf .build; rm -rf .build; swift build` zero warnings + `swift test` green; shippable → `./build.sh` + launch + footprint + smoke the changed behavior. Commit per feature, no AI attribution. Release: confirm nothing (auto per standing rule), bump both version keys, tag `companion-v*`, poll `gh run view --json conclusion`, shipped-zip gauntlet, notes via `gh release edit`.

## Still-pending owner smoke (carried over)
⌥-tab switcher (opt-in, never verified live), fullscreen Dock hover, the notch guidance tip, and the new Dock placement setting.
