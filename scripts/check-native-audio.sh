#!/bin/bash
# Isolate native checks from dylibs loaded by a running development app.
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/bootstrap.sh >/dev/null
./scripts/build-deps.sh >/dev/null
TEST_CORE=".build/native-audio-tests"
cmake -S native -B "$TEST_CORE" -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET=26.0 >/dev/null
cmake --build "$TEST_CORE" -j"$(sysctl -n hw.ncpu)" --target mirrorcore >/dev/null
mkdir -p .build/audio-tests
xcrun clang -g -fsanitize=address,undefined -mmacosx-version-min=26.0 \
    -I vendor/UxPlay/lib \
    Tests/RAOPAudioBufferChecks.c vendor/UxPlay/lib/raop_buffer.c \
    "$TEST_CORE/airplay/libairplay.a" native/build/deps/macos26/lib/libcrypto.a \
    -lpthread -o .build/audio-tests/check-raop-buffer
.build/audio-tests/check-raop-buffer
xcrun clang -g -fsanitize=address,undefined -mmacosx-version-min=26.0 \
    -I vendor/UxPlay/lib Tests/RAOPAudioClockChecks.c \
    "$TEST_CORE/airplay/libairplay.a" native/build/deps/macos26/lib/libplist-2.0.a \
    native/build/deps/macos26/lib/libcrypto.a -lpthread -o .build/audio-tests/check-raop-clock
.build/audio-tests/check-raop-clock
xcrun clang -g -fsanitize=address,undefined -mmacosx-version-min=26.0 \
    -I vendor/UxPlay/lib Tests/RAOPALACPauseChecks.c \
    "$TEST_CORE/airplay/libairplay.a" native/build/deps/macos26/lib/libplist-2.0.a \
    native/build/deps/macos26/lib/libcrypto.a -lpthread -o .build/audio-tests/check-alac-pause
.build/audio-tests/check-alac-pause
xcrun clang -g -fsanitize=address,undefined -mmacosx-version-min=26.0 \
    -I vendor/UxPlay/lib -I native/include Tests/AudioBridgeFormatChecks.c \
    "$TEST_CORE/airplay/libairplay.a" "$TEST_CORE/playfair/libplayfair.a" \
    "$TEST_CORE/dns_sd/libdnssd.a" "$TEST_CORE/llhttp/libllhttp.a" \
    native/build/deps/macos26/lib/libplist-2.0.a native/build/deps/macos26/lib/libcrypto.a \
    -lpthread -o .build/audio-tests/check-audio-bridge
.build/audio-tests/check-audio-bridge
xcrun clang -g -fsanitize=address,undefined -mmacosx-version-min=26.0 \
    -DPLIST_210 -DPLIST_230 -I vendor/UxPlay/lib -I native/build/deps/macos26/include \
    Tests/RAOPConnectionLifecycleChecks.c \
    "$TEST_CORE/airplay/libairplay.a" "$TEST_CORE/playfair/libplayfair.a" \
    "$TEST_CORE/dns_sd/libdnssd.a" "$TEST_CORE/llhttp/libllhttp.a" \
    native/build/deps/macos26/lib/libplist-2.0.a native/build/deps/macos26/lib/libcrypto.a \
    -lpthread -o .build/audio-tests/check-connection-lifecycle
.build/audio-tests/check-connection-lifecycle
xcrun clang -g -fsanitize=address,undefined -mmacosx-version-min=26.0 \
    -I vendor/UxPlay/lib -I native/include Tests/VideoConfigurationChecks.c \
    "$TEST_CORE/airplay/libairplay.a" "$TEST_CORE/playfair/libplayfair.a" \
    "$TEST_CORE/dns_sd/libdnssd.a" "$TEST_CORE/llhttp/libllhttp.a" \
    native/build/deps/macos26/lib/libplist-2.0.a native/build/deps/macos26/lib/libcrypto.a \
    -lpthread -o .build/audio-tests/check-video-configuration
.build/audio-tests/check-video-configuration
