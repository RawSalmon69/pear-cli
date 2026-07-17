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

# App icon (Finder, About panel, Sparkle dialogs, notifications).
if [[ -f Resources/PearCompanion.icns ]]; then
    cp Resources/PearCompanion.icns "$APP/Contents/Resources/PearCompanion.icns"
fi

# Bundle the pear CLI so Clean/Optimize and the disk bars work on Macs with no
# installed pear (an installed copy still wins — see PearStatsService). The
# tree is self-locating (pear resolves bin/ and lib/ from its own path), so a
# straight copy of the entry script, the tracked shell scripts, and lib/ is a
# working install. The repo's bin/ also holds untracked local Go artifacts —
# copy only *.sh and build the two Go helpers fresh, arm64-only (every F&F
# machine is Apple silicon; min macOS is 14).
CLI_DEST="$APP/Contents/Resources/pear-cli"
mkdir -p "$CLI_DEST/bin"
cp ../pear "$CLI_DEST/pear"
cp -R ../lib "$CLI_DEST/lib"
cp ../bin/*.sh "$CLI_DEST/bin/"
# The app drives clean/optimize (shell) and `analyze --json` (analyze-go). It
# never invokes `pear status` — stats are computed natively in Swift — so the
# status-go Go binary (~3.8 MB) is not bundled; drop its now-binaryless wrapper
# so the embedded CLI has no broken command.
rm -f "$CLI_DEST/bin/status.sh"
echo "Building bundled CLI helper (analyze-go)..."
(cd .. && go build -ldflags "-s -w" -o "companion/$CLI_DEST/bin/analyze-go" ./cmd/analyze)

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

    # The bundled CLI's Go helper is Mach-O and notarization checks it
    # individually; shell scripts need no signature.
    ANALYZE_GO="$APP/Contents/Resources/pear-cli/bin/analyze-go"
    if [[ -f "$ANALYZE_GO" ]]; then sign "$ANALYZE_GO"; fi

    # Main app last, over the already-signed nested code.
    codesign --force --options runtime --timestamp \
        --entitlements Resources/PearCompanion.entitlements \
        --sign "$IDENTITY" "$APP"
    codesign --verify --deep --strict "$APP"
else
    echo "IDENTITY unset — skipping codesign (unsigned dev build)."
fi

echo "Built: companion/$APP"
