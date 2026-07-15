# PearCompanion v2 — Next Session Prompt

Paste this as the opening message of the next session.

---

You are the **Fable orchestrator** for PearCompanion. Spawn **opus / sonnet-5
subagents** for parallel or mechanical work (isolated git worktrees when they
touch overlapping Swift files); keep architecture, integration, and
verification in your own main loop. **Adversarially verify** — never trust an
agent's "done" without `swift build` + `swift test` and, for shippables, a
signed launch. Commit per feature. Read the memory files under
`/Users/raws/.claude/projects/-Users-raws-Documents-Github-pear-cli/memory/`
first.

## The product

**PearCompanion = an all-in-one macOS productivity super-app** that replaces a
stack of paid menu-bar apps (CleanShot, Swish/Magnet, Maccy/Paste, iStat Menus,
CleanMyMac, Yoink/Dropover, Pika). General public release, possibly paid. The
pear/cat identity is the **brand**, not "for my girlfriend."

Already built + shipped (v1.1.2, notarized, Sparkle auto-update): screenshot
capture + markup + OCR, clipboard history, disk analyze (bars), system stats,
Clean/Optimize, encrypted CloudKit couple-messaging. Signing fully wired
(Developer ID cert, 7 GH secrets, **provisioning profile stays — keep it**).

## Owner decisions already made

- **Keep the provisioning profile.** Don't try to remove entitlements.
- **Escape GPL by native rewrite.** The `pear`/Mole cleanup engine is GPL-3.0.
  The clean, lawful way to make the GPL question disappear is to **reimplement
  the cleanup/optimize/analyze functions natively in Swift** (no GPL code in the
  app), using the **MIT-licensed** references below. Once there's no GPL code,
  there's nothing to disclose and nothing to hide — that is the whole point of
  the rewrite. (Do NOT ship GPL code while concealing it; that's a license
  violation. The rewrite removes the issue legitimately.) The CLI can remain a
  separate GPL project; the app stops depending on it.
- **No Terminal windows.** Clean/Optimize currently `osascript` open Terminal.app
  — the owner hates that. Fix below.

## The "no Terminal" fix (do early)

Replace `TerminalRunner` (which opens Terminal.app) with a native in-app runner:
- Run work with Swift `Process`, capture stdout/stderr + exit code, stream it
  into a native progress/console sheet in the app. No visible Terminal.
- When admin rights are needed, escalate with a **one-shot**
  `osascript -e 'do shell script "…" with administrator privileges'` — that
  shows the standard macOS auth dialog, no Terminal window. (Better long-term: a
  `SMAppService`/privileged helper, but the osascript one-shot is fine to start.)
- Best end state: once the cleanup is **rewritten natively**, most actions run
  in-process with a real SwiftUI progress UI and no subprocess at all.

## Open-source building blocks (researched — licenses matter for a paid app)

MIT / permissive = safe to adapt into a proprietary paid app. GPL / Commons
Clause = do NOT copy into a closed/paid build (reference only).

| Need | Repo | License | Use |
|---|---|---|---|
| **Disk viz (sunburst + treemap)** | colinvkim/Radix | **MIT** | Adapt directly. Native Swift, `RadixCore` package, **no deps**, dual sunburst/treemap, actor-based scanner, Quick Look + drag-drop. This is the owner's grid+circle, done right. |
| **Native cleaner (GPL escape)** | momenbasel/PureMac | **MIT** | Adapt to replace GPL Mole cleanup. Native SwiftUI, trashes via `FileManager.trashItem`, cache/Xcode/Homebrew cleanup, scheduled auto-clean. |
| Native cleaner (alt) | iliyami/MacSai | open (Swift 6/SwiftUI, notarized) | 16 scan categories; cross-check PureMac. Verify exact license before copying. |
| **Shelf / drag-drop** | iamsumanp/Dropshit | **MIT** | Exact Dropover clone: NSPanel + NSFilePromiseProvider + QLThumbnailGenerator, shake-to-summon, drop-anywhere. The reference for the floating-shelf fix. |
| **Window management** | rxhanson/Rectangle | **MIT** | AX (`AXUIElement`) move/resize + snap engine. Base for the Swish replacement. |
| Window mgmt (GUI tiling) | ianyh/Amethyst | MIT | Reference for auto-tiling if wanted. (yabai is MIT but needs SIP disabled — bad for general users; skip.) |
| **System monitor** | exelban/Stats | **MIT** | Expand our stats natively: per-core CPU, GPU, fans, sensors (temp/volt/power), network, battery detail. |
| Menu-bar manager | sane-apps/SaneBar | **MIT** | If we do Bartender-style hiding. (jordanbaird/Ice is GPL-3.0 — reference only. Note macOS Tahoe now has native menu-bar controls.) |
| Clipboard | p0deje/Maccy, Clipy/Clipy | MIT | Reference; we already have basic clipboard history. |
| Color picker / eyedropper | superhighfives/Pika, sindresorhus/System-Color-Picker | MIT | Easy, high-value add. |
| Launcher (stretch) | ospfranco/Sol, SuperCmd | MIT | Raycast-lite. Big scope — later. |
| App uninstaller | (our `pear uninstall`, or rewrite) | — | AVOID alienator88/Pearcleaner: Apache **+ Commons Clause** forbids selling. Use PureMac (MIT) or native. |
| Screenshot annotate | (ours, already native) | — | Keep ours. macshot/Flameshot/ksnip are all GPL — don't copy. |

## Work — orchestrate in this order (adjust with owner)

1. **No-Terminal fix** (above) — native `Process` runner + progress UI; osascript
   admin one-shot for privilege. Delete `TerminalRunner`'s Terminal path.
2. **Hide couple-note** — feature-flag off Notes/composer/poke/seen + CloudKit
   messaging wiring in `AppEnvironment.live()`. Keep files for a future sync tier.
   (Profile/entitlements stay — no signing change needed.)
3. **Disk viz → Radix** — adapt Radix's sunburst + treemap (MIT) to replace the
   bar view; keep bars as a third mode. Drill-in + breadcrumb. Delegate to opus.
4. **Shelf as floating window** — adapt Dropshit (MIT): non-activating NSPanel,
   shake-to-summon / hotkey (⌃⇧V) / drop-anywhere, persistent, drag-in + drag-out,
   Quick Look. NOT the menu-bar popover (that auto-closes — the bug the owner hit).
5. **Native cleanup engine** — reimplement clean/optimize/analyze in Swift using
   PureMac (MIT) as the base, trashing via `FileManager.trashItem`. Removes the
   GPL dependency and the Terminal/subprocess entirely. Big; stage it.
6. **Window management** — Rectangle (MIT) AX engine + custom trackpad title-bar
   two-finger swipe (Swish's signature) via `NSEvent`. Zones: halves/quarters/
   thirds/max/center + keyboard + edge-drag. Accessibility permission onboarding.
7. **More features (pick with owner):** color picker (Pika, MIT), richer system
   monitor (Stats, MIT — fans/sensors/per-core), menu-bar manager (SaneBar, MIT,
   maybe skip given Tahoe), Pomodoro/timers, scratchpad, scheduled cleanups.
8. **Correctness/audit pass** — review agents (companion code-review; repo's
   bash32/safety reviewers on any CLI; security). Verify build+tests, notarized
   release, and the auto-update chain.
9. **Rebrand copy** — README + app strings + a general onboarding (not couple).

## Known gotchas (from memory — do not rediscover)

- **Sparkle:** appcast `sparkle:version` must be **CFBundleVersion (build int)**,
  not the marketing string; bump BOTH version fields every release.
  `companion-release.yml` reads CFBundleVersion via plutil — keep it.
- **Sparkle notarization:** nested Updater.app/Autoupdate/XPC must be signed
  inside-out with `--timestamp --options runtime` before framework+app (in
  `build.sh` — don't regress).
- **Agent launcher flaky:** dead spawns / 600s stalls happen — resume via
  `SendMessage`, have agents write to disk incrementally, re-verify their output.
- **Pipe-safe CI:** `gh run watch | tail` masks failure — confirm with
  `gh run view <id> --json conclusion`.
- Hotkeys via shared `HotKeyManager` (taken: ⌃⇧P screenshot, ⌃⇧O OCR, ⌃⇧C
  clipboard). App is `LSUIElement`.

## Success criteria

- No Terminal window ever appears; actions show native progress.
- Disk view: interactive sunburst + treemap from real data.
- Shelf: persistent floating window, drag-in/out, no auto-close.
- Window snapping: keyboard + edge-drag + trackpad title-bar swipe.
- Cleanup runs natively (no GPL code, no subprocess) OR arm's-length if deferred.
- Notarized release ships; installed build auto-updates.
- Copy reads as a general product.

## Sources

- Radix (MIT, disk sunburst+treemap): https://github.com/colinvkim/Radix
- PureMac (MIT, native cleaner): https://github.com/momenbasel/PureMac
- Mac Sai (native cleaner): https://github.com/iliyami/MacSai
- Dropshit (MIT, shelf): https://github.com/iamsumanp/Dropshit
- Rectangle (MIT, window mgmt): https://github.com/rxhanson/Rectangle
- Amethyst (MIT, tiling): https://github.com/ianyh/Amethyst
- Stats (MIT, system monitor): https://github.com/exelban/stats
- SaneBar (MIT, menu-bar mgr): https://github.com/sane-apps/SaneBar
- Pika (MIT, color picker): https://github.com/superhighfives/pika
- Maccy (MIT, clipboard): https://github.com/p0deje/Maccy
- Sol (MIT, launcher): https://github.com/ospfranco/Sol
- AVOID for paid: jordanbaird/Ice (GPL), alienator88/Pearcleaner (Commons Clause),
  macshot/Flameshot/ksnip (GPL), MrKai77/Loop (GPL).
- Swish (closed, gesture UX to emulate): https://highlyopinionated.co/swish/
- burrow-public (closed competitor, no code): https://github.com/rmonst3r/burrow-public
