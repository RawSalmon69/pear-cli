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

# Sparkle ships as a framework; bundle it and point the binary at it.
SPARKLE_FRAMEWORK="$(find .build -maxdepth 3 -type d -name Sparkle.framework -path '*release*' | head -1)"
if [[ -n "$SPARKLE_FRAMEWORK" ]]; then
    mkdir -p "$APP/Contents/Frameworks"
    cp -R "$SPARKLE_FRAMEWORK" "$APP/Contents/Frameworks/"
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/PearCompanion"
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
