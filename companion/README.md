# Pear Companion

All-in-one macOS productivity app in the menu bar: screenshots with markup,
grab-text OCR, clipboard history, disk explorer, scratchpad, cleanup and Mac
health — one lightweight app instead of a stack of utilities, built on the
pear CLI. Distributed to friends & family; source stays shareable.

## Build

```bash
cd companion
./build.sh              # unsigned dev build → build/PearCompanion.app
open build/PearCompanion.app
```

Signed build: `IDENTITY="Developer ID Application: ..." ./build.sh 1.0.0`

Full setup guide (CloudKit container, push, signing secrets, install, daily
use, troubleshooting) is in [SETUP.md](SETUP.md).
