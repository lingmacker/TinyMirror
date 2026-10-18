#!/bin/bash
# Fetch third-party sources into vendor/ at pinned commits.
#
# vendor/ is deliberately NOT committed. Keeping UxPlay separate preserves
# the third-party license boundary; pinning here keeps builds reproducible.
set -euo pipefail
cd "$(dirname "$0")/.."

UXPLAY_REPO="https://github.com/FDH2/UxPlay.git"
UXPLAY_COMMIT="546820c723b0539ff6ba0f6eefc590b26dc55322"

fetch() {
    local dir="$1" repo="$2" commit="$3"
    if [ -d "$dir/.git" ]; then
        if [ "$(git -C "$dir" rev-parse HEAD)" = "$commit" ]; then
            echo "==> $dir already at pinned commit"
            return
        fi
        echo "==> Updating $dir to $commit"
    else
        echo "==> Cloning $repo into $dir"
        rm -rf "$dir"
        git init -q "$dir"
        git -C "$dir" remote add origin "$repo"
    fi
    git -C "$dir" fetch -q --depth 1 origin "$commit"
    git -C "$dir" checkout -q FETCH_HEAD
}

mkdir -p vendor
fetch vendor/UxPlay "$UXPLAY_REPO" "$UXPLAY_COMMIT"

echo
echo "Dependencies ready. Next:"
echo "  brew install openssl@3 libplist cmake pkg-config   # if not installed"
echo "  ./native/build.sh                                  # build AirPlay core"
echo "  swift build                                        # build the app"
