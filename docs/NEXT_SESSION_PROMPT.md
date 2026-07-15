# PearCompanion v2 — Next Session Prompt (the blueprint)

Paste this as the opening message of the next session.

---

You are the **Fable orchestrator** for PearCompanion v2. Operate as an
orchestrator: **spawn opus / sonnet-5 subagents** for parallel or mechanical
work (isolated **git worktrees** when they edit overlapping Swift files;
integrate their new files yourself). Keep architecture, integration, and
verification in your own Fable main loop. **Adversarially verify** — never
trust an agent's "done" without `swift build` + `swift test` passing and, for
anything shippable, a signed launch and a footprint check. Commit per feature.
Ship via `companion-v*` tags.

**Read these FIRST:**
`/Users/raws/.claude/projects/-Users-raws-Documents-Github-pear-cli/memory/`
(full project state + every hard-won gotcha), then the current app under
`companion/Sources/PearCompanion/`.

## The product

**PearCompanion = an all-in-one macOS productivity super-app** — one lightweight
app that replaces a stack of paid/separate menu-bar utilities (CleanShot,
Swish/Magnet, Maccy, iStat Menus, CleanMyMac, Yoink/Dropover, Pika). The
pear/cat is the **brand**. Distribution: **friends & family** for now (not sold
wide), so GPL code is fine as long as source stays shareable; if that ever
changes to paid, swap the GPL pieces for the MIT ones noted below.

Owner's mandate: **make the best possible app. Refactor or rewrite whatever is
needed for quality — don't preserve mediocrity to save effort.** But use proven
OSS engines rather than hand-rolling risky logic; the value is stitching them
into ONE coherent, light, "just works" experience — a *good* Frankenstein.

## Decisions already locked

- **Min macOS = 14** (bump from 13). Unlocks `@Observable`; owner doesn't care
  about dropping 13.
- **Keep the provisioning profile** and current signing (Developer ID cert + 7
  GH secrets all set). Don't touch the signing/notarization path except as noted.
- **Friends-and-family** → GPL OK. Use **Loop** (GPL) for windows; keep source
  shareable. (Sellable future → switch to Rectangle MIT.)
- **No engine rewrite of the cleaner** — keep pear's proven, safety-tested
  cleanup; only replace the Terminal-popping glue with a native runner.
- **Hide the couple-note feature** (keep files, flag it off).
- **Menu-bar management: not built.** Owner uses SaneBar (MIT) separately; macOS
  Tahoe covers the basics natively. Revisit only if ever folding it in (adopt
  SaneBar's MIT code then).

---

## PHASE 0 — Refactor the foundation FIRST (before any new tool)

An architecture audit (2026-07-15) found the base **robust and clean on the
expensive fundamentals** (zero force-unwraps/`as!`/`try!`, per-subsystem
soft-fail, sound MainActor concurrency, a real design-token + `glassCard()`
material seam, one correct lazy module in `DiskAnalyzeView`) — but **three
patterns that rot combinatorially** as tools are added. Fix these before piling
on. Do them in this order; `swift build` + `swift test` after each.

1. **Enforce strict concurrency** (audit C4). `Package.swift` is tools 5.9 in
   Swift-5 mode — races aren't checked. Bump to tools 6.0 + `swiftLanguageMode(.v6)`
   (or `.enableExperimentalFeature("StrictConcurrency")`) and fix fallout now, at
   ~4k LOC, not at 20k after vendoring.
2. **Introduce a Tool module system** (audit C3). Define a `Tool` protocol
   (`id`, `title`, `icon`, optional `hotkey`, `makeService()`, `makePanelEntry()`)
   + a registry. Make `ToolsSection` **data-driven** from the registry so adding a
   tool is one registration, not edits in 3-4 files. **Lazy-instantiate** each
   tool's service on first activation — generalize the existing
   `DiskAnalyzeView` pattern (`@StateObject` created when opened). No eager engine
   construction at launch. This is the core "clean plug-in foundation" enabler.
3. **Break the AppEnvironment change-funnel** (audit C1). Today every service
   `objectWillChange` is republished through the container, so any tick (e.g. the
   clipboard poll) re-renders the whole panel. Migrate services to `@Observable`
   (now that we're macOS 14) and let each subview observe the specific service it
   uses. Delete the `changes`/`.receive(on:)` republish workaround.
4. **Fix the StatsService seam** (audit C2). The protocol is a fake — the
   container reaches through it with `as? PearStatsService` downcasts for
   `diskUsedFraction`/`uptime`/`healthScore`/etc. Widen the protocol or drop the
   pretense; whatever you choose becomes the template every tool copies, so make
   it clean.
5. **HotKeyManager.unregister** (audit S1). Currently register-only; actions +
   `EventHotKeyRef`s leak. Add `unregister` (returns a token from `register`,
   calls `UnregisterEventHotKey`). Required before load/unloadable modules.
6. **Image discipline** (audit S2/S3). Add an ImageIO downsampling helper
   (`CGImageSourceCreateThumbnailAtIndex`) for all thumbnails (clipboard/preview/
   shelf); cap clipboard image history by **total bytes**, not count; back the
   clipboard poll off to 2-3s and/or pause when no consumer is active.
7. **Cleanups** (audit S4/S5/S6): remove dead `MockStatsService`; extract the
   duplicated `screencapture` region-capture into one `ScreenCapture.region()`
   helper (ScreenshotService + OCRService are byte-identical); inject a tiny
   `CommandRunner` protocol so `Process`-shelling services are testable.

**Exit gate for Phase 0:** build + tests green under strict concurrency; adding a
trivial demo tool is a single registry entry; footprint still ~≤55 MB idle / 0%
idle CPU. Commit. Then and only then, start tools.

---

## DESIGN CONSTITUTION (every tool built to this)

**UX**
1. **One interaction model.** Every tool: a global hotkey to summon from
   anywhere + presence in the menu-bar panel as calm home base. Same dismiss
   (Esc/swipe), same sound feedback, everywhere.
2. **One visual system.** Adopt OSS **engines**, but **re-skin their surface** in
   our design system (`Theme` + `glassCard()`). Do NOT drop raw upstream UI in —
   that's the "5 apps in a trenchcoat" failure. Coherence is the whole product.
3. **Modular + lazy = light.** Each tool loads only when first used; event-driven,
   not polling; tear down what's not visible.
4. **Toggle what you don't use.** Settings disables any tool → its subsystem never
   loads. All-in-one, pruned to the user's needs.
5. **One-sentence mental model:** *PearCompanion is your Mac's control center —
   menu bar is home, a hotkey summons any tool anywhere, tools appear as clean
   floating panels that all look like one app.* If a feature doesn't fit that
   sentence, it doesn't go in.

**Robustness / maintenance**
6. **Vendor-and-own.** Copy the useful subsystem into our repo and make it ours;
   do NOT take live dependencies (they break/abandon — see Ice). Cherry-pick
   upstream fixes manually, on our schedule. Only real live deps: **Sparkle**
   (pinned) and the **pear CLI** (updated via the existing reviewed weekly sync
   PR). Keep source shareable (GPL parts stay GPL).
7. **Every tool fails alone.** Defined, contained failure state per tool
   (degraded UI, not a crash). Feature toggles are circuit breakers. No
   force-unwraps; guard every external edge (CLI JSON, pasteboard, AX, CloudKit).
   Blast-radius discipline is the price of all-in-one — enforce it.

---

## PHASE 1+ — Adopt tools (each as a Tool module: engine vendored + re-skinned)

Order by value/safety; parallelize self-contained ones to worktree agents.

- **No-Terminal cleaner fix (do first, low-risk).** Replace `TerminalRunner`'s
  Terminal.app path: run `pear clean/optimize` via Swift `Process`, stream
  stdout/exit into a **native progress sheet**; escalate sudo with a one-shot
  `osascript … with administrator privileges` (native auth dialog, no Terminal).
  Engine untouched.
- **Hide couple-note.** Flag off Notes/composer/poke/seen + the CloudKit
  messaging wiring; keep files for a future sync tier. (Profile/entitlements stay.)
- **Disk → Radix (MIT).** Vendor Radix's scan engine + sunburst + treemap; re-skin
  to our system; replace the bar view (keep bars as a 3rd mode). Drill-in +
  breadcrumb. Good opus-agent task.
- **Shelf → Dropshit (MIT).** Standalone non-activating floating `NSPanel`
  (shake-to-summon / hotkey ⌃⇧V / drop-anywhere), persistent, drag-in + drag-out,
  Quick Look, local storage. NOT the menu-bar popover (auto-closes — the known bug).
- **Windows → Loop (GPL, OK for F&F).** Vendor Loop's radial snap engine + AX
  window move/resize; re-skin. Add trackpad title-bar two-finger swipe (Swish's
  signature) via `NSEvent`. Zones: halves/quarters/thirds/max/center + keyboard.
  Accessibility-permission onboarding. High-maintenance module — gate behind
  availability checks + graceful degradation.
- **Markup freehand.** Add a `.freehand` pen tool to the existing markup editor
  (path of drag points) — we have arrow/rect/highlighter/text/blur, not freehand.
- **Clipboard → Maccy (MIT).** Vendor Maccy's store/search/pin logic (fuzzy
  search, pins, ignore-apps, images); re-skin the list into our panel. Replaces
  our basic clipboard.
- **Scratchpad → Antinote-style.** Floating quick-note (`NSPanel`, ⌃⇧N,
  autosave, swipe between notes), with top-of-note commands: inline math/`sum`,
  unit/currency convert, `timer`/`todo`, strip-formatting-on-paste. Light original
  build (or lift an MIT quick-note engine).
- **Color picker → Pika (MIT).** Vendor eyedropper + formats; re-skin.
- **System monitor → Stats (MIT).** Expand our stats natively: per-core CPU, GPU,
  fans, temp/voltage sensors, network, battery detail.

## Lightweightness — budgets + verification (check every release)

- Idle RAM ≤ ~80 MB even with tools loaded (currently ~55 MB); idle CPU ~0%;
  bundle small (currently 5 MB). Measure with `ps -axo rss,pcpu` on a running
  build + `du -sh` for bundle; add bundle-size to CI. The pitch — *lighter than
  the 5 apps it replaces (250 MB+ across 5 processes)* — is provable; keep it true.

## Rebrand / reposition

README + app strings + onboarding from couple-gift → general product. Remove
personal identities baked in code (`greeting(role:)` "raws"/"Pear 🍐" at
MascotView, CoupleKey roles) — audit N2.

## Known gotchas (do NOT rediscover — cost us real cycles)

- **Sparkle, two bugs:** appcast `sparkle:version` must be **CFBundleVersion
  (build integer)**, not the marketing string; and bump **both**
  CFBundleShortVersionString and CFBundleVersion every release.
  `companion-release.yml` reads CFBundleVersion via plutil — keep it.
- **Sparkle notarization:** nested Updater.app/Autoupdate/XPC signed inside-out,
  each with `--timestamp --options runtime`, before framework+app (in `build.sh`
  — don't regress).
- **Agent launcher flaky:** dead spawns / 600s stalls — resume via `SendMessage`,
  have agents write to disk incrementally, re-verify their output yourself.
- **Pipe-safe CI:** `gh run watch | tail` masks failure — confirm with
  `gh run view <id> --json conclusion`.
- Hotkeys via shared `HotKeyManager` (taken: ⌃⇧P screenshot, ⌃⇧O OCR, ⌃⇧C
  clipboard; planned ⌃⇧V shelf, ⌃⇧N scratchpad). App is `LSUIElement`.

## OSS building blocks (licenses — matter if this ever goes paid)

| Need | Repo | License | Note |
|---|---|---|---|
| Disk sunburst+treemap | colinvkim/Radix | MIT | adopt engine + viz |
| Shelf | iamsumanp/Dropshit | MIT | Dropover clone, NSPanel |
| Windows | MrKai77/Loop | **GPL** | OK for F&F; swap → Rectangle (MIT) if paid |
| Windows (MIT alt) | rxhanson/Rectangle | MIT | the sellable option |
| Clipboard | p0deje/Maccy | MIT | store/search/pins |
| System monitor | exelban/Stats | MIT | fans/sensors/per-core |
| Color picker | superhighfives/Pika | MIT | eyedropper |
| Menu-bar (NOT building) | sane-apps/SaneBar | MIT | use separately |
| AVOID for paid | Ice (GPL), Pearcleaner (Commons Clause), macshot/Flameshot/ksnip (GPL) | — | reference only |

## Success criteria

- Phase 0 done: strict-concurrency clean, Tool registry + lazy loading, no
  AppEnvironment funnel, clean stats seam, hotkey unregister, image downsampling.
- No Terminal window ever; actions show native progress.
- Disk: interactive sunburst + treemap. Shelf: persistent floating window,
  drag-in/out, no auto-close. Windows: keyboard + edge-drag + trackpad swipe.
  Clipboard/color/monitor/scratchpad in, coherent skin. Markup has freehand.
- Couple-note hidden. Idle ≤~80 MB / ~0% CPU. Notarized release auto-updates.
- Copy reads as a general product. Every tool fails alone + is toggleable.

## Sources

Radix https://github.com/colinvkim/Radix · Dropshit https://github.com/iamsumanp/Dropshit ·
Loop https://github.com/MrKai77/Loop · Rectangle https://github.com/rxhanson/Rectangle ·
Maccy https://github.com/p0deje/Maccy · Stats https://github.com/exelban/stats ·
Pika https://github.com/superhighfives/pika · SaneBar https://github.com/sane-apps/SaneBar ·
Swish (closed, gesture to emulate) https://highlyopinionated.co/swish/
