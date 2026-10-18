#!/bin/bash
# Build an ad-hoc signed Release app through Make, plus an ad-hoc DMG.
# Usage: VERSION=0.2.0 ./scripts/package.sh
set -euo pipefail
cd "$(dirname "$0")/.."

if [ "${NOTARIZE:-0}" = "1" ]; then
    echo "Ad-hoc signatures cannot be notarized; NOTARIZE=1 is no longer supported." >&2
    exit 1
fi
VERSION="${VERSION:-0.1.0}"
case "$VERSION" in
    *[!0-9A-Za-z._-]*) echo "VERSION must contain only letters, digits, dots, underscores or hyphens." >&2; exit 1 ;;
esac
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
COPYRIGHT="${COPYRIGHT:-Copyright © $(date +%Y) Emerson Garland. All rights reserved.}"
export VERSION BUILD_NUMBER COPYRIGHT

make build CONFIGURATION=release
APP="dist/MirrorDeck.app"
DMG="dist/MirrorDeck-$VERSION.dmg"
STAGE="dist/dmg"
trap 'rm -rf "$STAGE"' EXIT

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/MirrorDeck.app"
ln -s /Applications "$STAGE/Applications"
if diskutil image create from --help >/dev/null 2>&1; then
    diskutil image create from --volumeName MirrorDeck --format UDZO "$STAGE" "$DMG"
else
    hdiutil create -volname MirrorDeck -srcfolder "$STAGE" -ov -format UDZO "$DMG"
fi
codesign --force --sign - "$DMG"
codesign --verify --strict "$DMG"

echo "Built $APP and $DMG (ad-hoc signed, not notarized)."
echo "Gatekeeper may block downloaded copies on other Macs; ad-hoc signing does not verify the developer."
