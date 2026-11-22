#!/bin/bash
# Build an ad-hoc signed Release app through Make, plus a ZIP archive.
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
APP="dist/TinyMirror.app"
ZIP="dist/TinyMirror-$VERSION.zip"

rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

echo "Built $APP and $ZIP (ad-hoc signed, not notarized)."
echo "Gatekeeper may block downloaded copies on other Macs; ad-hoc signing does not verify the developer."
