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

# Preserve RTP silence sequence numbers and the fractional audio sample clock.
for AUDIO_PATCH in "$PWD/native/patches/uxplay-audio-silence.patch" \
                   "$PWD/native/patches/uxplay-audio-clock.patch" \
                   "$PWD/native/patches/uxplay-alac-pause.patch" \
                   "$PWD/native/patches/uxplay-audio-control-drain.patch"; do
    # The silence hunk omits trailing context changed by the ALAC patch.
    if git -C vendor/UxPlay apply --unidiff-zero --reverse --check "$AUDIO_PATCH" 2>/dev/null; then
        echo "==> $(basename "$AUDIO_PATCH") already applied"
    else
        git -C vendor/UxPlay apply --unidiff-zero --check "$AUDIO_PATCH"
        git -C vendor/UxPlay apply --unidiff-zero "$AUDIO_PATCH"
        echo "==> Applied $(basename "$AUDIO_PATCH")"
    fi
done

echo
echo "Dependencies ready. Next:"
echo "  brew install cmake pkg-config                       # if not installed"
echo "  make build                                          # build the native core and app"
