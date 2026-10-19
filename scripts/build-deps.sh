#!/bin/bash
# Recreate static dependencies locally instead of relying on Homebrew bottle deployment targets.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
PREFIX="$ROOT/native/build/deps/macos26"
SOURCES="$ROOT/vendor/dependency-sources"
ARCH="$(uname -m)"
STAMP="openssl-3.5.9 libplist-2.8.0 macos26 $ARCH $PREFIX"

if [ -f "$PREFIX/.built-for" ] && [ "$(< "$PREFIX/.built-for")" = "$STAMP" ] &&
   [ -f "$PREFIX/include/openssl/evp.h" ] && [ -f "$PREFIX/include/plist/plist.h" ] &&
   [ -f "$PREFIX/lib/libcrypto.a" ] && [ -f "$PREFIX/lib/libssl.a" ] &&
   [ -f "$PREFIX/lib/libplist-2.0.a" ] && [ -f "$PREFIX/lib/pkgconfig/openssl.pc" ] &&
   [ -f "$PREFIX/lib/pkgconfig/libplist-2.0.pc" ]; then
    echo "==> macOS 26 native dependencies ready"
    exit 0
fi
case "$ARCH" in
    arm64|x86_64) ;;
    *) echo "Unsupported native architecture: $ARCH" >&2; exit 1 ;;
esac
mkdir -p "$SOURCES" "$PREFIX"
rm -f "$PREFIX/.built-for"

fetch() {
    local name="$1" url="$2" checksum="$3"
    local archive="$SOURCES/$name"
    if ! printf '%s  %s\n' "$checksum" "$archive" | shasum -a 256 -c - >/dev/null 2>&1; then
        curl --fail --location --retry 3 "$url" -o "$archive.tmp"
        printf '%s  %s\n' "$checksum" "$archive.tmp" | shasum -a 256 -c -
        mv "$archive.tmp" "$archive"
    fi
}
fetch openssl-3.5.9.tar.gz \
    https://github.com/openssl/openssl/releases/download/openssl-3.5.9/openssl-3.5.9.tar.gz \
    603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a
fetch libplist-2.8.0.tar.bz2 \
    https://github.com/libimobiledevice/libplist/releases/download/2.8.0/libplist-2.8.0.tar.bz2 \
    b1f59f7634c58b2481325a23ff4e3bf51574a42d868cbe466d2b39b04550752a

if [ ! -f "$SOURCES/openssl-3.5.9/Configure" ]; then
    tar -xf "$SOURCES/openssl-3.5.9.tar.gz" -C "$SOURCES"
fi
if [ ! -f "$SOURCES/libplist-2.8.0/configure" ]; then
    tar -xf "$SOURCES/libplist-2.8.0.tar.bz2" -C "$SOURCES"
fi
# Application make variables must not override upstream dependency Makefiles.
unset MAKEFLAGS MFLAGS MAKEOVERRIDES
export MACOSX_DEPLOYMENT_TARGET=26.0
export CFLAGS="-O2 -mmacosx-version-min=26.0"
export CXXFLAGS="$CFLAGS"
export LDFLAGS="-mmacosx-version-min=26.0"
JOBS="$(sysctl -n hw.ncpu)"
echo "==> Building OpenSSL 3.5.9 and libplist 2.8.0 for macOS 26 ($ARCH)"
(
    cd "$SOURCES/openssl-3.5.9"
    if [ -f Makefile ]; then make clean; fi
    ./Configure "darwin64-$ARCH-cc" no-shared no-tests --prefix="$PREFIX" --libdir=lib
    make -j"$JOBS" build_libs
    make install_dev
)
(
    cd "$SOURCES/libplist-2.8.0"
    if [ -f Makefile ]; then make clean; fi
    # Modern static-only macOS builds do not use libtool\'s obsolete -single_module flag.
    LT_MULTI_MODULE=1 ./configure --prefix="$PREFIX" --disable-shared --enable-static --without-cython
    make -j"$JOBS"
    make install
)
printf '%s\n' "$STAMP" > "$PREFIX/.built-for"
