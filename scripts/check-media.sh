#!/bin/bash
# Generate codec fixtures with Apple's encoders and exercise the actual media code.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/audio-tests .build/window-tests .build/module-cache
bash scripts/check-native-audio.sh
python3 - <<'PY'
import math
import struct
import wave
with wave.open('.build/audio-tests/tone.wav', 'wb') as audio:
    audio.setparams((2, 2, 44100, 0, 'NONE', 'not compressed'))
    audio.writeframes(b''.join(struct.pack('<hh',
        int(4000 * math.sin(2 * math.pi * 440 * i / 44100)),
        int(4000 * math.sin(2 * math.pi * 660 * i / 44100))) for i in range(44100 * 3)))
PY
afconvert .build/audio-tests/tone.wav .build/audio-tests/eld.caf -f caff -d 'aace#480' -b 128000
afconvert .build/audio-tests/tone.wav .build/audio-tests/eld512.caf -f caff -d 'aace#512' -b 128000
afconvert .build/audio-tests/tone.wav .build/audio-tests/aac.caf -f caff -d 'aac #1024' -b 128000
afconvert .build/audio-tests/tone.wav .build/audio-tests/alac.caf -f caff -d 'alac#352'
xcrun swiftc -target "$(uname -m)-apple-macosx26.0" -module-cache-path .build/module-cache \
    Sources/TinyMirror/AirPlayAudioFormat.swift \
    Sources/TinyMirror/MediaPlayback.swift \
    Sources/TinyMirror/VideoPipeline.swift \
    Tests/MediaPlaybackChecks.swift \
    -framework AVFoundation -framework AudioToolbox \
    -o .build/audio-tests/check-media
.build/audio-tests/check-media
xcrun swiftc -target "$(uname -m)-apple-macosx26.0" -module-cache-path .build/module-cache \
    Sources/TinyMirror/AirPlayAudioFormat.swift Sources/TinyMirror/MediaPlayback.swift \
    Sources/TinyMirror/VideoPipeline.swift Tests/ALACSampleClockChecks.swift \
    -framework AVFoundation -framework AudioToolbox -o .build/audio-tests/check-alac-sample-clock
.build/audio-tests/check-alac-sample-clock
xcrun swiftc -target "$(uname -m)-apple-macosx26.0" -module-cache-path .build/module-cache \
    Sources/TinyMirror/MirrorVideoView.swift \
    Sources/TinyMirror/MirrorWindowController.swift \
    Sources/TinyMirror/Localization.swift \
    Tests/WindowBehaviorChecks.swift \
    -framework AppKit -framework AVFoundation \
    -o .build/window-tests/check-window
.build/window-tests/check-window
mkdir -p .build/audio-tests/CMirrorBridge
printf 'module CMirrorBridge { header "%s/native/include/mirror_bridge.h" export * }\n' "$PWD" \
    > .build/audio-tests/CMirrorBridge/module.modulemap
xcrun clang -c -mmacosx-version-min=26.0 Tests/ReceiverBridgeStub.c -o .build/audio-tests/receiver-stub.o
xcrun swiftc -target "$(uname -m)-apple-macosx26.0" -module-cache-path .build/module-cache \
    -I .build/audio-tests/CMirrorBridge -import-objc-header Tests/ReceiverBridgeStub.h \
    Sources/TinyMirror/AirPlayReceiver.swift Sources/TinyMirror/Settings.swift \
    Sources/TinyMirror/Localization.swift Tests/ReceiverFormatChecks.swift \
    .build/audio-tests/receiver-stub.o -o .build/audio-tests/check-receiver-format
.build/audio-tests/check-receiver-format
xcrun swiftc -target "$(uname -m)-apple-macosx26.0" -module-cache-path .build/module-cache \
    -I .build/audio-tests/CMirrorBridge -import-objc-header Tests/ReceiverBridgeStub.h \
    Sources/TinyMirror/AirPlayReceiver.swift Sources/TinyMirror/Settings.swift \
    Sources/TinyMirror/Localization.swift Sources/TinyMirror/AirPlayAudioFormat.swift \
    Sources/TinyMirror/MediaPlayback.swift Sources/TinyMirror/VideoPipeline.swift \
    Tests/ReceiverLifecycleChecks.swift .build/audio-tests/receiver-stub.o \
    -framework AVFoundation -framework AudioToolbox -o .build/audio-tests/check-receiver-lifecycle
.build/audio-tests/check-receiver-lifecycle
mkdir -p .build/frame-rate-tests/home
xcrun swiftc -target "$(uname -m)-apple-macosx26.0" -module-cache-path .build/module-cache \
    -I .build/audio-tests/CMirrorBridge -import-objc-header Tests/ReceiverBridgeStub.h \
    Sources/TinyMirror/AirPlayReceiver.swift Sources/TinyMirror/Settings.swift \
    Sources/TinyMirror/Localization.swift Sources/TinyMirror/AirPlayAudioFormat.swift \
    Sources/TinyMirror/MediaPlayback.swift Sources/TinyMirror/VideoPipeline.swift \
    Sources/TinyMirror/MirrorVideoView.swift Sources/TinyMirror/MirrorWindowController.swift \
    Sources/TinyMirror/StatusBarController.swift Sources/TinyMirror/AppDelegate.swift \
    Tests/FrameRateMenuChecks.swift .build/audio-tests/receiver-stub.o \
    -framework AppKit -framework AVFoundation -framework AudioToolbox \
    -o .build/frame-rate-tests/check-menu
CFFIXED_USER_HOME="$PWD/.build/frame-rate-tests/home" .build/frame-rate-tests/check-menu
cmp native/include/mirror_bridge.h Sources/CMirrorBridge/include/mirror_bridge.h
