#!/bin/bash
# Hardware integration check: real muted decoder/output queue, not an enqueue-only mock.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/audio-queue-replay .build/module-cache
xcrun swiftc -O -target "$(uname -m)-apple-macosx26.0" -module-cache-path .build/module-cache \
    Sources/TinyMirror/AirPlayAudioFormat.swift Sources/TinyMirror/MediaPlayback.swift \
    Sources/TinyMirror/VideoPipeline.swift Tests/AudioQueueReplayChecks.swift \
    -framework AVFoundation -framework AudioToolbox -o .build/audio-queue-replay/check-replay
python3 -B Tests/RunAudioQueueReplay.py .build/audio-queue-replay/check-replay
