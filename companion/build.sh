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

# SPM emits the executable's resources as PearCompanion_PearCompanion.bundle next
# to the binary. Bundle.module resolves it via Bundle.main.resourceURL, so copy
# it into Contents/Resources (this is what ships the RunCat runner frames).
RESOURCE_BUNDLE="$(find .build -maxdepth 3 -type d -name 'PearCompanion_PearCompanion.bundle' -path '*release*' | head -1)"
if [[ -n "$RESOURCE_BUNDLE" ]]; then
    cp -R "$RESOURCE_BUNDLE" "$APP/Contents/Resources/"
fi

# Sparkle ships as a framework; bundle it and point the binary at it.
SPARKLE_FRAMEWORK="$(find .build -maxdepth 3 -type d -name Sparkle.framework -path '*release*' | head -1)"
if [[ -n "$SPARKLE_FRAMEWORK" ]]; then
    mkdir -p "$APP/Contents/Frameworks"
    cp -R "$SPARKLE_FRAMEWORK" "$APP/Contents/Frameworks/"
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/PearCompanion"
fi

cp Resources/Info.plist "$APP/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"

# Embed the Developer ID provisioning profile that authorizes the CloudKit and
# push entitlements. Without it a hardened, entitled build will not launch.
PROFILE="${PROVISION_PROFILE:-Resources/PearCompanion.provisionprofile}"
if [[ -f "$PROFILE" ]]; then
    cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"
    echo "Embedded provisioning profile: $PROFILE"
elif [[ -n "${IDENTITY:-}" ]]; then
    echo "WARNING: no provisioning profile found ($PROFILE); a signed build with"
    echo "         CloudKit/push entitlements will fail to launch without it."
fi

if [[ -n "${IDENTITY:-}" ]]; then
    echo "Codesigning with: $IDENTITY"
    sign() { codesign --force --options runtime --timestamp --sign "$IDENTITY" "$@"; }

    # Sparkle ships nested code (XPC services, Autoupdate, Updater.app) that
    # notarization checks individually. Sign inside-out, each with a secure
    # timestamp and the hardened runtime, before the framework and app.
    FW="$APP/Contents/Frameworks/Sparkle.framework"
    if [[ -d "$FW" ]]; then
        while IFS= read -r xpc; do
            sign --preserve-metadata=entitlements "$xpc"
        done < <(find "$FW" -name "*.xpc" -type d)
        while IFS= read -r nested; do
            sign "$nested"
        done < <(find "$FW" -name "Autoupdate" -type f; find "$FW" -name "Updater.app" -type d)
        sign "$FW"
    fi

    # Main app last, over the already-signed nested code.
    codesign --force --options runtime --timestamp \
        --entitlements Resources/PearCompanion.entitlements \
        --sign "$IDENTITY" "$APP"
    codesign --verify --deep --strict "$APP"
else
    echo "IDENTITY unset — skipping codesign (unsigned dev build)."
fi

echo "Built: companion/$APP"
