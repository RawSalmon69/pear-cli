# PearCompanion v2.3 — QoL & Refinement Session Prompt

Paste this to start the next clean session.

---

You are the Fable orchestrator for PearCompanion v2.3 (QoL + refinement round). Orchestrate: keep architecture, integration, safety review, and verification in your own Fable main loop; spawn **opus** subagents in isolated git worktrees for parallel or self-contained work. Adversarially verify every agent result — read the diff line-by-line, run swift build (zero warnings, on a NON-incremental build — incremental masks warnings) + swift test, and for shippable work do a dev launch + footprint check (≤80 MB idle / ~0% CPU) before merging. Commit per feature, push main when verified. Ship via companion-v* tags only on the maintainer's explicit channel confirmation.

Invoke the ponytail skill and keep it active all session — laziest solution that works, fewest files, shortest diff. "Lazy" means adopt upstream code that already works rather than rebuild it, not "hand-roll a minimal version."

Read FIRST: the memory at /Users/raws/.claude/projects/-Users-raws-Documents-Github-pear-cli/memory/ (project state, every gotcha — especially the v2.2 entries: Bundle.pearResources, measurement pitfalls, dead-agent rules), then the app under companion/Sources/PearCompanion/.

## Where things stand

companion-v2.2.1 shipped 2026-07-16 (notarized, launch-verified, appcast live, auto-updated owner's Macs). 198 tests green, ~58 MB idle / 0% CPU, 9 MB bundle. On main: live tool toggles + rebindable hotkeys (no relaunch), Loop's real radial ring + display-synced snap animation, all 25 RunCat runners + grid picker, Monitor section toggles/refresh/history charts, Radix sunburst zoom/pan + treemap tooltips, Esc-everywhere, DockDoor hover-preview v1 (static thumbnails, on by default), CI launch-smoke crash guard.

Standing rules (owner, unchanged): **A. Copy what works** — vendor upstream UI verbatim where better (GPL/Apache/MIT fine for F&F; provenance headers + license texts in Resources/Licenses/). **B. Everything toggleable + richly customizable, applied LIVE** — toggle + settings section is part of definition-of-done for every feature.

## Owner feedback round 6 (2026-07-16, post-2.2.1) — the work list, in priority order

**Reliability first (owner: "lots of the time clicking on each button still doesn't work, doesn't show anything"):**

1. **Panel tiles frequently dead on click.** Clicking tiles often shows nothing. Root-cause this before polishing anything — owner expects root-cause fixes, not workarounds. Leads: tile `.popover` attachment inside the MenuBarExtra window (only one popover can be up; a stale `activePopoverID` may block the next), first-click-after-open focus issues, non-activating panel key handling. Reproduce first (PanelView.swift ToolsSection, activePopoverID state), then fix the mechanism, not the symptom.

2. **Grey rectangular focus box around the MAC section on open** (owner: "like I clicked on it, I hate that" — screenshot on file). The Mac stats row is a tappable button (opens Monitor) and takes first-responder focus when the panel opens. Kill the ring (focusEffectDisabled/focusable(false) or defaultFocus elsewhere) — sweep the whole panel for open-time focus artifacts while there.

**Tool UX fixes:**

3. **Color Picker flow is broken UX.** Today: tile → popover → Pick color → sample → popover closed, no feedback, result only visible by reopening. Owner wants: pick → **hex lands on the clipboard immediately** + a confirmation pop-up/toast (+ the copy sound). The hotkey path already does copy-hex (ColorStore.pickColor(copyingHex:)) — make the tile/popover path do the same and add visible confirmation (small toast near cursor; keep it sleek). Rule B: make the copied format (HEX/RGB/HSL) a setting if trivial.

4. **Default cat runner renders way too small** next to the gallery runners. Legacy cat/parrot/horse are 32×32 squares scaled to 18 pt height; gallery frames are 36 px tall and wider. Normalize perceived size (RunnerStyle.scaledSize in Tools/RunCat/RunnerStyle.swift) — scale legacy sets to match the gallery's visual weight or swap the default to the gallery's classic-cat. Owner compares side by side; make them consistent in the menu bar AND the picker grid.

5. **Windows popover overflows.** After opening the Windows tile, content doesn't fit: the snap-animation controls and everything below are cut off / out of bounds (WindowsView grew past the popover in v2.2). Restructure: bounded ScrollView, tighter sections, or split zones grid vs settings — dense, no clipped controls. Sweep other popovers for the same overflow while there.

6. **? help sheet: uneven row colors** — some rows render a different "blackness" than others (glassCard/material inconsistency in HelpView rows). Make them uniform.

**Disk (two-phase delete + fixes):**

7. **Right-click context menu** on disk items (bars/sunburst/treemap rows) with Delete.
8. **Staged deletion instead of instant:** deleting marks the item into a visible "Pending deletion" section; each pending item can be restored/cancelled (right-click or button); a single explicit "Delete all" button then moves everything to Trash at once. Keep every hard rule: single NSWorkspace.recycle sink, DiskDeletion.canTrash home-guard, Trash-only, reviewed line-by-line. Two-phase is a safety improvement — build it as the only path (replaces instant delete).
9. **Bug: after a delete, the whole chart greys out** and stays that way. Root-cause (likely rescan/hover/selection state after mutation in DiskChartView/DiskScanModel).

**Screenshot / markup (CleanShot parity round):**

10. **Markup editor: add crop** (top ask), plus whatever CleanShot-basics are cheap once crop's in. Views/MarkupEditor.swift + MarkupModel.swift.
11. **Screenshot preview overhaul:** sleeker look; a real swipe-away animation (it currently just disappears); and **multiple previews stacking** that persist until each is manually swiped away (CleanShot behavior) — today it's one preview with a 6 s auto-timeout. Views/ScreenshotPreviewWindow.swift. This is the owner's daily-driver surface; study CleanShot's actual feel.

**Dock Preview (v1 → real):**

12. **Panel appears UNDER the Dock** — z-order/level bug (DockPreviewPanel level vs the Dock's window level; also verify anchoring math per Dock side). Fix so it floats above.
13. **Only works for some apps** — diagnose coverage: multi-instance apps take first instance only, minimized/off-space windows have no SCK match, some apps may fail AX enumeration. Widen enumeration (DockDoor upstream handles these — port more of their window-listing; clone is gone, re-clone github.com/ejbills/DockDoor, commit 78b0862f was the scouted baseline).
14. **Customization is invisible** — settings exist in the tile popover (hover delay, size, titles) but the owner didn't find them ("what about the customization?"). Make discoverable + richer per Rule B.
15. **⌥-tab switcher: not built** (v1 deliberately shipped hover-only). Owner asked where it is. Build it as the next DockDoor slice: upstream's switcher, Accessibility-gated, own settings, live toggle. Also consider upgrading static thumbnails → live SCStream previews (the `// ponytail:` marker in DockThumbnailer.swift is the upgrade point).

## Hard-won gotchas — do NOT rediscover (cumulative, all real)

- **Bundle.module is FORBIDDEN in app code** — CI's Xcode emits an accessor that never checks Contents/Resources; v2.2.0 shipped crash-looping because of it. Use `Bundle.pearResources` (Support/ResourceBundle.swift) for every resource load. The CI launch-smoke step now guards this class.
- Never resume a dead agent (0 tool uses) — spawn fresh; its worktree is gone and a resume writes into the main tree. BUT: agents killed by "session limit" auto-resume in their worktrees after reset — TaskStop them before assuming dead, and never assume a failed command chain's later steps ran.
- Every worktree agent's first action: `git rebase main` + verify log (worktrees spawn from session-start snapshot).
- `git status` before any `git add -A` while agents are in flight.
- Swift 6 strict: @Observable stored props are computed → nonisolated deinit can't touch them (@ObservationIgnored); AXUIElement/CGEvent/NSStatusItem aren't Sendable; no @unchecked Sendable without written justification.
- Deletion is sacred: single NSWorkspace.recycle sink, DiskDeletion.canTrash home guard, confirmed, Trash-only, line-by-line review. Never removeItem/unlink/rm.
- AX calls: AXUIElementSetMessagingTimeout ~0.5 s on every element created (6 s default froze the app once).
- Sparkle releases: bump BOTH CFBundleShortVersionString and CFBundleVersion (next build is 10); appcast sparkle:version = build integer; minimumSystemVersion read from LSMinimumSystemVersion; nested Sparkle XPCs signed inside-out in build.sh.
- Measurement on this box: `ps -axo args | grep` silently drops matches under rtk — use `pgrep -fl`; top/ps %CPU are decayed averages — use cputime deltas over 30 s; dev builds share the owner's real UserDefaults (runnerEnabled=1 makes idle CPU look ~7% — that's the cat animating; override via `open --args -runnerEnabled 0`, never mutate his defaults); `git diff | git apply` breaks under rtk (compacted) — use `rtk proxy git diff` for raw patches.
- gh run watch masks failures — poll `gh run view <id> --json conclusion`.
- Release verification MUST include launching the downloaded shipped zip binary directly (this caught 2.2.0; spctl/stapler/appcast all passed on the broken build).
- Tools with system-MUTATING launch behavior default OFF (menu-bar hider lesson); observers that never prompt (DockDoor) may default ON.

## Verification (every change)

swift build zero warnings (non-incremental) + swift test green; for shippable changes ./build.sh + launch the assembled .app + cputime-delta footprint (≤80 MB idle / ~0% CPU) + smoke the actual behavior changed. Commit per feature, no AI attribution trailers. Full release flow (owner says "release"): confirm channels (GitHub release + appcast), bump both version keys, tag companion-v*, verify conclusion via gh run view, download shipped zip → spctl + stapler + **direct-exec launch test** → notes via gh release edit (never create).

## Success criteria

Every tile click works, every time; no focus box on open; color pick = instant clipboard hex + visible confirmation; runner sizes consistent; Windows popover fits; help rows uniform; disk deletes are two-phase (pending list → restore or Trash-all) with context menus and no grey-out bug; markup has crop; screenshot previews stack, persist, and swipe away with animation; Dock Preview floats above the Dock, covers effectively every app, has discoverable rich settings, and gains the ⌥-tab switcher; footprint held; all upstream provenance intact. Release only on the maintainer's explicit channel confirmation.
