# Pear Companion — owner setup guide

One-time setup for RawSalmon69. Do sections 1-3 once, ever. Section 4 is the
release ritual. Sections 5-7 are for installing/using/debugging the app on
both Macs.

## 1. Apple Developer portal (one-time)

1. [developer.apple.com/account/resources/identifiers/list](https://developer.apple.com/account/resources/identifiers/list) →
   **+** → App IDs → App → bundle ID `com.rawsalmon69.pear.companion`.
   Enable capabilities **iCloud** (with CloudKit) and **Push Notifications**. Save.
2. Identifiers → filter by **iCloud Containers** → **+** → identifier
   `iCloud.com.rawsalmon69.pear`. Register. Back on the App ID, edit the
   iCloud capability and select this container.
3. [icloud.developer.apple.com](https://icloud.developer.apple.com) → pick the
   `iCloud.com.rawsalmon69.pear` container → **Schema** → **Record Types**
   (Development environment first):
   - **Message**: add fields
     - `kind` — String
     - `sentAt` — Date/Time (mark **Sortable**)
     - `senderDevice` — String
     - `ciphertext` — Bytes
     - `asset` — Asset
   - **Receipt**: add fields
     - `messageID` — String (mark **Queryable**)
     - `seenAt` — Date/Time
     - `byDevice` — String
   - On both record types, open **Indexes** and add a **Queryable** index on
     `recordName` (the built-in record ID field — CloudKit doesn't make it
     queryable by default).
   - Confirm the **Public Database** is selected (default) — the app never
     touches the private database.
4. **Schema** → **Deploy Schema Changes** → deploy Development → Production.
   The app talks to Production; nothing works until this step is done.

## 2. Sparkle EdDSA keys

Same tool the CI workflow uses — no Xcode project needed:

```bash
curl -fsSL -o /tmp/sparkle.tar.xz \
  https://github.com/sparkle-project/Sparkle/releases/download/2.9.4/Sparkle-2.9.4.tar.xz
mkdir -p /tmp/sparkle-tools && tar -xJf /tmp/sparkle.tar.xz -C /tmp/sparkle-tools bin
chmod +x /tmp/sparkle-tools/bin/generate_keys

/tmp/sparkle-tools/bin/generate_keys
```

This generates a keypair, stores the private key in your login Keychain, and
prints the public key plus the exact `SUPublicEDKey` plist snippet.

- **Public key** → paste into `companion/Resources/Info.plist`, replacing the
  `REPLACE_ME` placeholder already sitting in the `SUPublicEDKey` value.
- **Private key** → export it once so CI can use it, then put it in a GitHub
  secret:

  ```bash
  /tmp/sparkle-tools/bin/generate_keys -x /tmp/sparkle_private_key.txt
  gh secret set SPARKLE_ED_PRIVATE_KEY --repo RawSalmon69/pear-cli < /tmp/sparkle_private_key.txt
  rm /tmp/sparkle_private_key.txt
  ```

If `companion/Package.resolved` ever bumps past Sparkle 2.9.4, use the
matching version in the URL above (same tool works for any 2.x release).

## 3. Signing secrets

Export your Developer ID Application certificate (Keychain Access → My
Certificates → right-click the cert → Export → `.p12`, set an export
password) and base64 it:

```bash
base64 -i /path/to/DeveloperIDApplication.p12 | pbcopy
```

Add all 7 secrets — GitHub web UI (Settings → Secrets and variables →
Actions → New repository secret) or `gh secret set NAME --repo RawSalmon69/pear-cli`:

| Secret | Value | Where to find it |
|---|---|---|
| `MACOS_CERT_P12` | base64 of the `.p12` above | clipboard from the command above |
| `MACOS_CERT_PASSWORD` | the export password you set | the password you just typed |
| `MACOS_SIGN_IDENTITY` | `Developer ID Application: <Name> (<TEAMID>)` | `security find-identity -v -p codesigning` |
| `APPLE_ID` | your Apple ID email | the account under developer.apple.com |
| `APPLE_TEAM_ID` | your Team ID | developer.apple.com/account → Membership details |
| `APPLE_APP_PASSWORD` | an app-specific password (not your Apple ID password) | appleid.apple.com → Sign-In and Security → App-Specific Passwords |
| `SPARKLE_ED_PRIVATE_KEY` | Sparkle private key | step 2 above |

## 4. First release

```bash
git tag companion-v1.0.0
git push origin companion-v1.0.0
```

Watch the Actions tab: `companion-release.yml` builds, signs, notarizes
(usually a few minutes — notarization is the slow part), publishes a GitHub
release named `companion-v1.0.0` with the zip attached, and commits the
updated `companion/appcast.xml` back to `main`. Future releases are just
another tag push (`companion-v1.0.1`, ...); both Macs pick it up via Sparkle.

## 5. Install on both Macs

1. Download the zip from the release page, unzip, drag `PearCompanion.app`
   to `/Applications`, open it. It's notarized, so Gatekeeper won't complain.
2. Click the pear glyph in the menu bar to open the panel.
3. On Mac 1: gear icon → **Generate new key (copies to clipboard)**.
4. On Mac 2: gear icon → paste into the key field → **Save**.
5. Relaunch Pear on **both** Macs (quit and reopen) so the couple key takes
   effect.
6. On each Mac, gear icon → **I am** → pick `raws` or `Pear 🍐` for that
   Mac.
7. The first time you send or receive, macOS prompts for notification
   permission — click **Allow**.
8. Login item: the app doesn't register itself yet (planned for v2). Add it
   manually — System Settings → General → Login Items & Extensions → **+** →
   select PearCompanion — so it's always running to catch pushes/polls.

## 6. Daily use

- **Notes**: type in the composer, hit send. Emoji work as text. Poke button
  sends a one-tap 🍐. A note shows "seen 🍐" once the other Mac has opened it.
- **Capture**: `⌃⇧P` (or the panel's screenshot button) → drag to select a
  region → auto-copied to the clipboard, auto-saved to
  `~/Pictures/Pear Screenshots`, and a floating preview appears bottom-corner
  for ~6s (hover to keep it open) with **Copy** / **Show in Finder** /
  **Send 🍐**.
- **Shared Shelf**: drag any file onto the shelf drop zone in the panel — it
  shows up on both Macs' shelves. Last 20 items, 30-day expiry.
- **Clean Now / Optimize**: opens Terminal and runs `pear clean` /
  `pear optimize`, so the CLI's own confirmations and safety prompts still
  apply.

## 7. Troubleshooting

- **"Two Macs, one key" card ("needs setup")** — this Mac's Keychain has no
  couple key, or the saved value isn't valid base64/32 bytes. Gear icon →
  paste or generate the key → Save → relaunch.
- **Offline banner reasons**:
  - "No iCloud account" — this Mac isn't signed into iCloud (System Settings
    → Apple ID). Sign in and reopen the panel.
  - "iCloud unavailable" — the iCloud account-status check itself failed
    (network blip or iCloud outage); it'll clear on its own.
  - "Couldn't reach iCloud" — the last send/save request failed; retry.
  - "Sync error" — the last refresh/fetch failed; retry.
  - Any of these are soft failures — the panel keeps working and keeps
    retrying; nothing is lost.
- **Push feels slow / arrives late** — unsigned or dev builds have no APNs
  entitlement, so there's no instant push; the app falls back to a 5-minute
  foreground poll. Signed, notarized releases (the normal path via section 4)
  get real push and near-instant delivery. Reopening the panel also forces
  an immediate refresh.
- **Screenshots** save to `~/Pictures/Pear Screenshots` by default. Change
  the folder via gear icon → Screenshots → **Change…**.
- **"Install the pear CLI..." card** on the stats tiles means neither
  `/usr/local/bin/pear` nor `/opt/homebrew/bin/pear` exists. Install the
  `pear` CLI (see the main repo README) and reopen the panel.
