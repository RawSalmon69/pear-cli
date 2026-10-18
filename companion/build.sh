#!/bin/bash
# Assembles Pear.app from the SPM build.
# Usage: ./build.sh [version]
# Env: IDENTITY="Developer ID Application: ..." enables codesigning (skipped when unset).

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

VERSION="${1:-$(git describe --tags --always 2> /dev/null | sed 's/^V//' || echo 0.1.0)}"
APP="build/Pear.app"

echo "Building Pear ${VERSION}..."
# The const-values flags make swiftc record the App Intents declarations, which
# the metadata step below turns into Metadata.appintents (Xcode's
# ExtractAppIntentsMetadata, which SwiftPM never runs). The list is a committed
# plain JSON array: the native backend rejects the toolchain's versioned file.
swift build -c release \
    -Xswiftc -emit-const-values \
    -Xswiftc -Xfrontend -Xswiftc -const-gather-protocols-file \
    -Xswiftc -Xfrontend -Xswiftc "$PWD/Resources/AppIntentsProtocols.json"
# Ask SwiftPM where the products went: `.build/<triple>/release` under the native
# backend, `.build/out/Products/Release` under SwiftBuild (Swift 6.4's default).
BIN="$(swift build -c release --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# SPM still builds the binary as "PearCompanion" (the module name is unchanged);
# only the on-disk executable is renamed to Pear, matching CFBundleExecutable.
cp "$BIN/PearCompanion" "$APP/Contents/MacOS/Pear"

# SPM emits the executable's resources as PearCompanion_PearCompanion.bundle next
# to the binary. Bundle.module resolves it via Bundle.main.resourceURL, so copy
# it into Contents/Resources (this is what ships the RunCat runner frames).
RESOURCE_BUNDLE="$BIN/PearCompanion_PearCompanion.bundle"
if [[ -d "$RESOURCE_BUNDLE" ]]; then
    cp -R "$RESOURCE_BUNDLE" "$APP/Contents/Resources/"
fi

# Sparkle ships as a framework; bundle it and point the binary at it.
SPARKLE_FRAMEWORK="$BIN/Sparkle.framework"
if [[ -d "$SPARKLE_FRAMEWORK" ]]; then
    mkdir -p "$APP/Contents/Frameworks"
    cp -R "$SPARKLE_FRAMEWORK" "$APP/Contents/Frameworks/"
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/Pear"
fi

cp Resources/Info.plist "$APP/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"

# App icon (Finder, About panel, Sparkle dialogs, notifications).
if [[ -f Resources/PearCompanion.icns ]]; then
    cp Resources/PearCompanion.icns "$APP/Contents/Resources/PearCompanion.icns"
fi

# App Intents metadata (Shortcuts/Spotlight actions), written into Resources
# before codesign seals it, once per module that declares intents: the app, and
# the Control Center control (its toggle intent). Each module has one const-values
# file: `<M>.swiftconstvalues` inside the bin path under the native backend,
# `<M>-primary.swiftconstvalues` in the sibling Intermediates tree under SwiftBuild.
# Usage: intents_metadata <module> <binary> <resources dir> <bundle id> <deployment target>
INTENTS_TMP="build/appintents"
# Derived at build time, so CI's Xcode and a local one each describe themselves.
XCODE_BUILD="$(xcodebuild -version | awk '/Build version/ { print $3 }')"
intents_metadata() {
    local module="$1" binary="$2" output="$3" bundle_id="$4" deployment="$5"
    local const_values
    const_values="$(find "$BIN" -name "$module.swiftconstvalues")"
    if [[ -z "$const_values" ]]; then
        const_values="$(find "$BIN/../.." -path '*/Release/*' -name "$module-primary.swiftconstvalues")"
    fi
    if [[ -z "$const_values" ]]; then
        echo "ERROR: no $module .swiftconstvalues under $BIN; App Intents metadata cannot be built."
        exit 1
    fi
    mkdir -p "$INTENTS_TMP"
    echo "$const_values" > "$INTENTS_TMP/constvalues.txt"
    find "$PWD/Sources/$module" -name '*.swift' > "$INTENTS_TMP/sources.txt"
    xcrun appintentsmetadataprocessor \
        --output "$output" \
        --toolchain-dir "$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain" \
        --module-name "$module" \
        --sdk-root "$(xcrun --sdk macosx --show-sdk-path)" \
        --xcode-version "$XCODE_BUILD" \
        --platform-family macOS \
        --deployment-target "$deployment" \
        --target-triple "$(uname -m)-apple-macos$deployment" \
        --bundle-identifier "$bundle_id" \
        --binary-file "$binary" \
        --source-file-list "$INTENTS_TMP/sources.txt" \
        --swift-const-vals-list "$INTENTS_TMP/constvalues.txt" \
        --compile-time-extraction \
        --deployment-aware-processing \
        --no-app-shortcuts-localization \
        --force
    rm -rf "$INTENTS_TMP"
}
intents_metadata PearCompanion "$APP/Contents/MacOS/Pear" "$APP/Contents/Resources" \
    "$(plutil -extract CFBundleIdentifier raw Resources/Info.plist)" 14.0

# The Control Center control (macOS 26+), a WidgetKit extension. Its
# LSMinimumSystemVersion 26.0 keeps 14–15 from loading it. Its versions are the
# app's, so the pair never disagree.
APPEX="$APP/Contents/PlugIns/PearControl.appex"
mkdir -p "$APPEX/Contents/MacOS" "$APPEX/Contents/Resources"
cp "$BIN/PearControl" "$APPEX/Contents/MacOS/PearControl"
cp Resources/PearControl-Info.plist "$APPEX/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APPEX/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$(plutil -extract CFBundleVersion raw Resources/Info.plist)" \
    "$APPEX/Contents/Info.plist"
intents_metadata PearControl "$APPEX/Contents/MacOS/PearControl" "$APPEX/Contents/Resources" \
    "$(plutil -extract CFBundleIdentifier raw Resources/PearControl-Info.plist)" 14.0

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
        done < <(
            find "$FW" -name "Autoupdate" -type f
            find "$FW" -name "Updater.app" -type d
        )
        sign "$FW"
    fi

    # The control extension: sandboxed, as WidgetKit requires; no profile needed.
    sign --entitlements Resources/PearControl.entitlements "$APPEX"

    # Main app last, over the already-signed nested code.
    codesign --force --options runtime --timestamp \
        --entitlements Resources/PearCompanion.entitlements \
        --sign "$IDENTITY" "$APP"
    codesign --verify --deep --strict "$APP"
else
    echo "IDENTITY unset — skipping codesign (unsigned dev build)."
fi

echo "Built: companion/$APP"
