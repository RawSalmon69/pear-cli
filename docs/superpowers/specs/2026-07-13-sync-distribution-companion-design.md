# Pear: Upstream Sync, Distribution, and Companion App — Design

Date: 2026-07-13
Status: approved-pending-review

## Context

pear-cli is a full rebrand of tw93/Mole (GPL-3.0). Owner: RawSalmon69. Three goals:

1. Stay current with upstream Mole without merge hell.
2. Let anyone install with one command.
3. A beautiful macOS menu-bar companion app as a gift for Pear (owner's girlfriend) — non-technical user, Liquid Glass design, autoupdating, with private two-way love-note messaging between the couple's Macs (CloudKit + client-side encryption).

Owner has an Apple Developer account. Owner's Mac: macOS 26.2. Her Mac: macOS 13+.

## A. Upstream sync

**Approach: scripted rebrand pipeline (not git merge).** The rebrand renamed ~2,465 strings; direct merges from upstream would conflict on nearly every hunk. Instead the rebrand is captured as a deterministic script and re-applied to fresh upstream snapshots.

- Branch `upstream`: pristine mirror of tw93/Mole `main`. Never edited by hand.
- `scripts/rebrand-upstream.sh`: applies, in order:
  1. URL rewrites: `github.com/tw93/Mole|mole` → `github.com/RawSalmon69/pear-cli`; `tw93/Mole` → `RawSalmon69/pear-cli`; `mole.fit` → repo URL
  2. `MOLE_` → `PEAR_`; regex `\bMO_` → `PE_`
  3. `MOLE` → `PEAR`; `Mole` → `Pear`; `mole` → `pear`
  4. CLI alias word `mo` → `pe`
  5. File renames: `mole`→`pear`, `mo`→`pe`, any path containing `mole`
  6. Deletions: TRADEMARK.md, CONTRIBUTORS.svg, FUNDING.yml, tw93 Mac-app issue templates, update-contributors workflow
  7. Mascot identifiers in `cmd/status/view.go` → `cat*` (not `pear*`)
- **Protected paths** (ours, sync never overwrites): `README.md`, `companion/`, `feed/`, `scripts/rebrand-upstream.sh`, `.github/workflows/sync-upstream.yml`, `docs/superpowers/`, memory of banner/help customizations in `pear` (kept as `scripts/patches/*.patch`, applied after rebrand; if a patch fails, PR is marked needs-manual-fix).
- `.github/workflows/sync-upstream.yml`: weekly cron + manual dispatch. Fetches upstream/main; if new commits: rebrand a fresh tree, apply patches, diff vs `main` excluding protected paths, open PR titled `Upstream sync <date>` listing upstream commits. Owner reviews and merges.
- Verification: rebrand script run against the upstream commit our tree came from must reproduce our tree (modulo protected paths). CI check in the sync workflow.

## B. Distribution

- Repo pushed public to `github.com/RawSalmon69/pear-cli`.
- `release.yml` trimmed: keep build + checksum + release-asset jobs; remove Homebrew tap/core publish jobs until a tap exists (they'd fail without secrets/tap repo).
- Release tag `V1.45.0` (inherits upstream version scheme) → binaries attached → one-liner live:
  `curl -fsSL https://raw.githubusercontent.com/RawSalmon69/pear-cli/main/install.sh | bash`
- Homebrew tap: deferred.

## C. Companion app ("Pear" in the menu bar)

**Product**: a private two-person companion installed on BOTH Macs (owner's and Pear's). Three pillars: love-note messaging (the heart), the animated pet (the charm), Mac care (the utility). Not a chat-app clone; never multi-user; never telemetry.

`companion/` in the same repo. Swift Package Manager executable target + `companion/build.sh` assembling a `.app` bundle (Info.plist, icon, entitlements, codesign). No Xcode project files. Only OS frameworks (SwiftUI, CloudKit, CryptoKit, UserNotifications) plus one third-party dependency: Sparkle 2.

### Messaging (CloudKit, end-to-end encrypted)

- **Transport**: CloudKit public database in the owner's container, record type `Message`. No CKShare invite flow.
- **Privacy model**: payloads (text and images) encrypted client-side with a shared symmetric key (CryptoKit, ChaChaPoly or AES-GCM) stored in each Mac's Keychain. Owner sets the key on both Macs once during setup. Apple stores ciphertext only; container ID is unpublished. Authenticity: AEAD — records that fail to decrypt/authenticate are ignored.
- **Message fields**: `id`, `senderDevice`, `sentAt`, `kind` (text | image | poke), `ciphertext` (CKAsset for images — image bytes encrypted before upload), `seenAt?` (updated by recipient → powers "seen 🍐").
- **Delivery**: `CKQuerySubscription` on Message → APNs push → local notification even when the panel is closed. App is a login item, so effectively always running.
- **Features in v1**: text + emoji, photos/images (paste, drag-drop, file picker; encrypted CKAsset; thumbnail in panel), one-tap 🍐 poke, recent history in panel, subtle "seen 🍐" state. Retention: recent N in panel; records persist in CloudKit.
- **Screenshot-send (v1)**: global hotkey + panel button → `screencapture -i` (native region select) → encrypted image message to the other Mac. The flagship friction-remover.
- **Shared Shelf (v1)**: drop zone in the panel; any file dragged in appears on both shelves (`kind=file`, encrypted CKAsset, original filename in encrypted metadata). Last 20 items, 30-day expiry (app deletes expired records opportunistically). No folders, no sync engine — an append-only shelf with delete.
- **Not in v1**: typing indicators, threads, infinite scroll, reactions, message deletion sync, LocalSend/LAN transfer (CloudKit pipe covers it; AirDrop exists for in-person), clipboard auto-sync, presence.

### UX / design

- **Liquid Glass**: on macOS 26+, native APIs (`GlassEffectContainer`, `.glassEffect(...)`, glass button styles). On macOS 13–15, availability-gated fallback to `.ultraThinMaterial` + vibrancy. One design, two material backends.
- `MenuBarExtra` with `.menuBarExtraStyle(.window)` → custom glass panel (~360 pt):
  1. Header: animated pear/cat mascot — idle blink, excited on new message, worried when disk nearly full — greeting varies by time of day.
  2. Messages: recent notes as glass cards (text/images), composer with emoji + image attach, poke button, "seen 🍐" indicator, spring-in animations.
  3. Stats row: three glass tiles — disk free, memory, battery — SF Symbols, ring gauges, `contentTransition(.numericText)`.
  4. Actions: "Clean Now", "Optimize" buttons.
  5. Footer: version, update state.
- Type: SF Rounded. Accent: pear green. Menu-bar icon: pear glyph template image (badge on unread); app icon: glossy pear.
- Quality bar: gift-grade. No default-looking controls; every state (loading, no messages yet, missing CLI, offline) designed.

### Mac care behavior

- **Stats**: runs `/usr/local/bin/pear status --json` every 60 s while panel open (on open otherwise). If CLI missing → designed setup card with install instructions. Gentle nudge notification when disk nearly full.
- **Clean Now / Optimize (v1)**: opens Terminal running `pear clean` / `pear optimize` via AppleScript — preserves the CLI's own confirmations and safety UX. Headless native versions are v2.

### Updates & install

- **Autoupdate**: Sparkle 2 (SPM dependency). `SUFeedURL` → `appcast.xml` in the repo (raw URL on main). CI on tag: build app → Developer ID sign → notarize (`notarytool`) → staple → zip → attach to GitHub release → regenerate appcast entry (EdDSA-signed) → commit appcast. Owner pushes tag → both Macs self-update. Signing keys/Apple credentials live as GitHub Actions secrets (owner adds; documented in companion/README).
- **Owner one-time setup (manual, documented)**: create CloudKit container + enable push in the Apple Developer portal; add signing/notarization secrets to GitHub; install app + shared key on both Macs.
- First install on her Mac: owner installs the notarized app himself (drag to /Applications) — Gatekeeper-clean thanks to notarization.

### Testing

- `swift build` in CI (macOS runner) on every PR.
- Unit tests: encryption round-trip (text + image bytes, tampered ciphertext rejected), Message record encode/decode, status JSON parsing, appcast generation script.
- Manual: visual pass on macOS 26 (glass) and 13-15 fallback; two-device message exchange (both directions, images, poke, seen) before her rollout; end-to-end Sparkle update on owner's Mac.

## Order of work

1. **B** — trim release.yml, initial commit, push public, cut V1.45.0, verify one-liner.
2. **A** — rebrand script + patches + sync workflow; CI reproducibility check.
3. **C** — companion scaffold → design pass → feed/stats/clean → Sparkle CI.

## Success criteria

- Sync: weekly PR appears when upstream moves; rebrand script reproduces current tree from upstream snapshot.
- Distribution: fresh Mac one-liner installs a working `pear`.
- Companion: message sent from one Mac appears as a notification on the other within seconds (both directions, text + image + poke, seen-state); tag push → app self-updates; panel is Liquid Glass on macOS 26 and still beautiful on 13-15; ciphertext-only in CloudKit (verified by inspecting records).

## Out of scope (v1)

- Headless native clean/optimize, scheduled cleaning, Homebrew tap/core, iOS/widget versions, typing indicators/threads/infinite scroll, anything multi-user, analytics of any kind (it's a gift, not a product).
