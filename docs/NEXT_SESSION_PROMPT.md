# PearCompanion v2 — Next Session Prompt

Paste this as the opening message of the next session.

---

You are the **Fable orchestrator** for the PearCompanion project. Work as an
orchestrator: **spawn opus / sonnet-5 subagents** for parallelizable or
mechanical work, and keep architecture, integration, and verification in your
own (Fable) main loop. Use **isolated git worktrees** for agents that edit
overlapping Swift files so they don't collide; integrate their new files
yourself. **Adversarially verify** — never trust an agent's "done" without
`swift build` + `swift test` passing and, for anything shippable, a signed
launch. Commit per feature. Read the memory files under
`/Users/raws/.claude/projects/-Users-raws-Documents-Github-pear-cli/memory/`
first — they hold the full project state and the hard-won gotchas.

## Where things stand (built + shipped)

- Public CLI `pear` (rebranded fork of tw93/Mole), repo `RawSalmon69/pear-cli`,
  latest CLI release V1.46.0, weekly upstream-sync automation live.
- `companion/` = PearCompanion menu-bar app (SwiftUI, SPM, macOS 13+, Liquid
  Glass on 26+). Shipped **v1.1.2** notarized via Sparkle auto-update. Features:
  encrypted CloudKit couple-messaging, screenshot capture + markup + OCR,
  clipboard history, disk analyze (bars), system stats, Clean/Optimize.
- Signing/release fully wired: Developer ID cert, 7 GitHub secrets, provisioning
  profile (valid to 2044), `companion-release.yml` sign→notarize→appcast.
- Setup runbook: `companion/SETUP.md`. Full details + gotchas in memory.

## The pivot (this is the rescope)

Stop treating this as a private gift for one couple. **PearCompanion is now a
general-purpose, all-in-one macOS productivity super-app** aimed at anyone —
the pitch: *stop paying for five separate menu-bar apps; one app does it all.*
Planned for public release, possibly paid. The pear/cat identity stays as
**brand**, not as "for my girlfriend." Rebrand copy accordingly (README, app
strings, SETUP → a general onboarding).

## CRITICAL — licensing, decide before any commercial release

- **The base (`pear` CLI) is GPL-3.0** (confirmed: repo LICENSE is GNU GPL v3).
  GPL is copyleft/viral. A proprietary, sold GUI that **bundles** the GPL binary
  in one `.app` is legally risky.
- Options: (a) release the whole app **GPL-3.0** (you can still sell it, but must
  provide source); (b) **arm's-length separation** — the GUI is a separate
  program that `exec`s the `pear` CLI, with the CLI shipped/installed separately
  under GPL (FSF treats pipe/exec as separate programs, generally OK); (c)
  **native rewrite** of the system functions so no GPL code is involved (big).
- Window-manager code you adapt: **use MIT-licensed Rectangle**
  (github.com/rxhanson/Rectangle) — safe for a proprietary app. **Do NOT copy
  GPL Loop** (github.com/MrKai77/Loop) into a proprietary build — reference only.
- **Action:** surface this to the owner and get a decision. Recommended default:
  arm's-length (b) if going paid; or embrace GPL (a) if going open-source-and-sell.

## burrow-public reality check

`github.com/rmonst3r/burrow-public` is **closed source — compiled binaries
only**, so there is **no code to steal**. It is a *proprietary GUI over Mole* —
i.e. a direct competitor doing exactly our idea. Use it only as a **UX
reference** (rearrangeable widgets, visual disk browser, always-available
window). Note it claims its bundled Mole is "MIT" while our repo LICENSE is
GPL-3.0 — verify Mole's actual licensing before relying on either.

## Work — orchestrate in this order (adjust with owner)

1. **Simplify: hide the couple-note feature.** Feature-flag off the Notes hero /
   composer / poke / seen UI and the CloudKit messaging wiring in
   `AppEnvironment.live()`. Keep the files (don't delete) for a possible future
   "sync" premium tier. **Big win:** with CloudKit + push gone, the app likely no
   longer needs the iCloud/aps entitlements — test whether the signed build
   launches **without** the provisioning profile (it was only required for those
   entitlements). If so, signing/notarization gets much simpler. The Shelf (below)
   becomes local-only.
2. **Disk visualization → grid + circle.** Owner dislikes the plain bars. Add a
   **treemap** (nested rectangles sized by bytes, GrandPerspective-style = the
   "grid") and a **sunburst** (concentric rings, DaisyDisk-style = the "circle"),
   built natively in a SwiftUI `Canvas` from `pear analyze --json` with recursive
   drill-in + breadcrumb. Keep the bar list as a third view mode. This is a strong
   candidate to delegate to an opus agent (self-contained view + a recursive model).
3. **Reintroduce the Shelf — as a standalone floating window, not the menu-bar
   popover.** The popover auto-closes on click-away and can't take drag-drop, which
   is exactly why the old shelf failed. Model it on **Dropover/Yoink**: a
   non-activating `NSPanel` (can become key, accepts drops, drag-out) that
   (a) opens on a **hotkey** (propose ⌃⇧V) and/or (b) **materializes when a file
   drag begins** near a screen edge, then **persists** as a floating shelf you can
   drag items out of later. Local storage. This is the correct fix to the UX
   problem the owner raised.
4. **Window management (the Swish replacement).** Swish is closed/paid. Build a
   native window manager: keyboard shortcuts + drag-to-screen-edge snapping +
   **trackpad two-finger swipe on the title bar** (Swish's signature gesture),
   using the **Accessibility API** (`AXUIElement`) to move/resize the focused
   window. **Adapt from Rectangle (MIT)** for the AX plumbing; the trackpad-gesture
   layer is custom `NSEvent` handling. Zones: halves, quarters, thirds, maximize,
   center. Requires the user to grant Accessibility permission — build a clean
   onboarding for that. Delegate the AX/snap engine to an agent; keep gesture
   tuning in the main loop (hardware feel needs iteration).
5. **Feature roadmap — pick with owner** (each replaces a paid app):
   - Clipboard history (HAVE — Maccy/Paste) · Screenshot+markup+OCR (HAVE —
     CleanShot) · System stats (HAVE — iStat) · Disk clean/analyze (HAVE —
     CleanMyMac).
   - NEW candidates: menu-bar icon manager (Bartender/Ice — but macOS Tahoe now
     has native menu-bar controls, so maybe skip), color picker/eyedropper,
     Pomodoro/timers, quick scratchpad notes, app-uninstaller UI over
     `pear uninstall` (AppCleaner), battery/health alerts, scheduled cleanups,
     a Raycast-lite launcher (big — probably out of scope).
6. **Correctness / audit pass** ("make everything right, good, correct"): spawn
   review agents — a code-review pass on the companion, the repo's existing
   `bash32-portability-reviewer` + `safety-reviewer` on any CLI changes, and a
   security pass. Confirm: `swift build` + `swift test`; a signed, **notarized**
   release; and the **auto-update chain end-to-end**.
7. **Rebrand/reposition copy**: README + app strings from couple-gift → general
   product. Onboarding for Accessibility + (if kept) any permissions.

## Known gotchas (from memory — do not rediscover the hard way)

- **Sparkle versioning (two separate bugs already burned):** the appcast
  `sparkle:version` must be the **CFBundleVersion (build integer: 1,2,3,4…)**,
  NOT the marketing string — Sparkle compares it against the installed app's
  CFBundleVersion. AND bump **both** CFBundleShortVersionString and
  CFBundleVersion every release. `companion-release.yml` now reads CFBundleVersion
  via plutil; keep it that way.
- **Signing:** Developer ID cert is in the login keychain + as GH secrets. If you
  keep CloudKit, the embedded provisioning profile is required or the hardened+
  entitled build won't even launch. If you drop CloudKit (step 1), re-test
  whether the profile/entitlements can be removed.
- **Notarizing Sparkle:** its nested Updater.app / Autoupdate / XPC services must
  be signed **inside-out, each with `--timestamp --options runtime`** before the
  framework + app (already handled in `build.sh` — don't regress it).
- **Agent launcher is flaky:** sometimes spawns dead agents (0 tool uses) or
  stalls at 600s. Resume via `SendMessage`; instruct agents to write files to disk
  incrementally so a stall loses nothing; re-verify their output yourself.
- **Pipe-safe CI checks:** `gh run watch | tail` returns tail's exit code and
  masks workflow failure — always confirm with
  `gh run view <id> --json conclusion`.
- The app is `LSUIElement` (menu-bar only). Hotkeys use the shared
  `HotKeyManager`; register new ones there (⌃⇧P screenshot, ⌃⇧O OCR, ⌃⇧C
  clipboard already taken).

## Success criteria

- Couple-note hidden; app builds/launches; signing simplified if CloudKit dropped.
- Disk view shows a treemap and a sunburst, drillable, from real data.
- Shelf works as a persistent floating window with drag-in/drag-out, no auto-close.
- Window snapping works via keyboard + edge-drag + trackpad title-bar swipe.
- A notarized release ships and an installed older build auto-updates to it.
- Copy reads as a general product, not a personal gift.
- Licensing decision made and the build complies with it.

## Sources

- Rectangle (MIT): https://github.com/rxhanson/Rectangle
- Loop (GPL-3.0, reference only): https://github.com/MrKai77/Loop
- Swish (closed/paid, the gesture UX to emulate): https://highlyopinionated.co/swish/
- burrow-public (closed competitor): https://github.com/rmonst3r/burrow-public
