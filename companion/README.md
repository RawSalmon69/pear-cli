# Pear Companion

Private two-person menu-bar app: love notes, screenshot-send, shared shelf,
Mac health — end-to-end encrypted over CloudKit. See the design spec at
`docs/superpowers/specs/2026-07-13-sync-distribution-companion-design.md`.

## Build

```bash
cd companion
./build.sh              # unsigned dev build → build/PearCompanion.app
open build/PearCompanion.app
```

Signed build: `IDENTITY="Developer ID Application: ..." ./build.sh 1.0.0`

Full setup guide (CloudKit container, push, shared key, her Mac) coming with v1.
