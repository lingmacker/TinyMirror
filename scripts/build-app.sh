#!/bin/bash
# Build and ad-hoc sign a complete app for local development or installation.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIGURATION="${CONFIGURATION:-debug}"
case "$CONFIGURATION" in
    debug|release) ;;
    *) echo "CONFIGURATION must be debug or release" >&2; exit 1 ;;
esac
VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
COPYRIGHT="${COPYRIGHT:-Copyright © $(date +%Y) Emerson Garland. All rights reserved.}"
APP="dist/TinyMirror.app"
RESOURCES="Sources/TinyMirror/Resources"
SWIFT_ARGS=(--cache-path .build/cache --config-path .build/config --security-path .build/security --disable-sandbox)

./native/build.sh
swift build "${SWIFT_ARGS[@]}" -c "$CONFIGURATION"
BIN_DIR="$(swift build "${SWIFT_ARGS[@]}" -c "$CONFIGURATION" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN_DIR/TinyMirror" "$APP/Contents/MacOS/"
# Packaged apps must use their bundled core, not a different workspace build.
for RPATH in @executable_path/../../../../native/build @executable_path/../../../native/build @executable_path/../../native/build; do
    install_name_tool -delete_rpath "$RPATH" "$APP/Contents/MacOS/TinyMirror"
done
cp -R "$RESOURCES/en.lproj" "$RESOURCES/zh-Hans.lproj" "$APP/Contents/Resources/"
cp native/build/libMirrorCore.dylib "$APP/Contents/Frameworks/"
cp -R licenses "$APP/Contents/Resources/licenses"
cp "$RESOURCES/Info.plist" "$APP/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$APP/Contents/Info.plist"
plutil -replace NSHumanReadableCopyright -string "$COPYRIGHT" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Compile app and menu bar artwork into the main bundle on every toolchain.
xcrun actool "$RESOURCES/AppIcon.icon" "$RESOURCES/Assets.xcassets" \
    --compile "$APP/Contents/Resources" \
    --platform macosx --minimum-deployment-target 26.0 \
    --app-icon AppIcon --output-partial-info-plist .build/icon-info.plist \
    --output-format human-readable-text --warnings --errors

# Both the replaceable core and enclosing app use offline ad-hoc signatures.
codesign --force --sign - "$APP/Contents/Frameworks/libMirrorCore.dylib"
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"
echo "Built $APP ($CONFIGURATION, local ad-hoc signature)"
