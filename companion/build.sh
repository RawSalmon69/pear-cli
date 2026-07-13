#!/bin/bash
# Assembles PearCompanion.app from the SPM build.
# Usage: ./build.sh [version]
# Env: IDENTITY="Developer ID Application: ..." enables codesigning (skipped when unset).

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

VERSION="${1:-$(git describe --tags --always 2> /dev/null | sed 's/^V//' || echo 0.1.0)}"
APP="build/PearCompanion.app"

echo "Building PearCompanion ${VERSION}..."
swift build -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/release/PearCompanion "$APP/Contents/MacOS/PearCompanion"

# Sparkle ships as a framework; bundle it beside the binary.
if [[ -d .build/release/Sparkle.framework ]]; then
    mkdir -p "$APP/Contents/Frameworks"
    cp -R .build/release/Sparkle.framework "$APP/Contents/Frameworks/"
fi

sed "s/<string>0\.1\.0<\/string>/<string>${VERSION}<\/string>/" Resources/Info.plist > "$APP/Contents/Info.plist"

if [[ -n "${IDENTITY:-}" ]]; then
    echo "Codesigning with: $IDENTITY"
    if [[ -d "$APP/Contents/Frameworks/Sparkle.framework" ]]; then
        codesign --force --options runtime --sign "$IDENTITY" "$APP/Contents/Frameworks/Sparkle.framework"
    fi
    codesign --force --options runtime \
        --entitlements Resources/PearCompanion.entitlements \
        --sign "$IDENTITY" "$APP"
    codesign --verify --deep --strict "$APP"
else
    echo "IDENTITY unset — skipping codesign (unsigned dev build)."
fi

echo "Built: companion/$APP"
