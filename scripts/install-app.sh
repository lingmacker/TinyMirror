#!/bin/bash
# Stage a complete bundle on the destination volume, then replace with rollback.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="$PWD/dist/MirrorDeck.app"
INSTALL_DIR="${1:?Usage: install-app.sh INSTALL_DIR}"
if [ ! -d "$APP" ]; then
    echo "Build MirrorDeck.app before installing." >&2
    exit 1
fi
if pgrep -x MirrorDeck >/dev/null; then
    echo "Quit the running MirrorDeck before installing." >&2
    exit 1
fi
mkdir -p "$INSTALL_DIR"
INSTALL_DIR="$(cd "$INSTALL_DIR" && pwd -P)"
case "$INSTALL_DIR/" in
    "$APP/"*) echo "Cannot install inside the source app bundle." >&2; exit 1 ;;
esac
DEST="$INSTALL_DIR/MirrorDeck.app"
if [ -L "$DEST" ] || { [ -e "$DEST" ] && [ ! -d "$DEST" ]; }; then
    echo "Refusing to replace a symlink or non-directory: $DEST" >&2
    exit 1
fi
if [ -d "$DEST" ]; then
    SOURCE_ID="$(plutil -extract CFBundleIdentifier raw "$APP/Contents/Info.plist")"
    DEST_ID="$(plutil -extract CFBundleIdentifier raw "$DEST/Contents/Info.plist")"
    if [ "$SOURCE_ID" != "$DEST_ID" ]; then
        echo "Refusing to replace a different application: $DEST" >&2
        exit 1
    fi
fi

STAGE="$(mktemp -d "$INSTALL_DIR/.mirrordeck-install.XXXXXX")"
cleanup() {
    if [ -d "$STAGE/previous.app" ] && [ ! -e "$DEST" ]; then
        if ! mv "$STAGE/previous.app" "$DEST"; then
            echo "Restore failed; the previous app is preserved at $STAGE/previous.app" >&2
            return
        fi
    fi
    rm -rf "$STAGE"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

ditto "$APP" "$STAGE/MirrorDeck.app"
codesign --verify --strict "$STAGE/MirrorDeck.app"
if [ -d "$DEST" ]; then mv "$DEST" "$STAGE/previous.app"; fi
mv "$STAGE/MirrorDeck.app" "$DEST"
echo "Installed $DEST"
