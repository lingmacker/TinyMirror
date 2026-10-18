#!/usr/bin/env python3
"""Verify reproducible native lookup without relying on native/build's cache."""
from pathlib import Path
import json
import re
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
prefix = root / ".build/deps/macos26"
for relative in ["include/openssl/evp.h", "include/plist/plist.h", "lib/libcrypto.a", "lib/libplist-2.0.a"]:
    assert (prefix / relative).is_file(), relative

objects = 0
for library in ["libcrypto.a", "libssl.a", "libplist-2.0.a"]:
    archive = prefix / "lib" / library
    members = subprocess.check_output(["ar", "-t", str(archive)], text=True).splitlines()
    count = sum(name.endswith(".o") for name in members)
    commands = subprocess.check_output(["otool", "-l", str(archive)], text=True)
    targets = re.findall(r"^\s*minos (\d+\.\d+)", commands, re.M)
    assert len(targets) == count and count > 0, (library, len(targets), count)
    assert set(targets) == {"26.0"}, (library, set(targets))
    objects += count

with tempfile.TemporaryDirectory(prefix="check-native-", dir=root / ".build") as temporary:
    build = Path(temporary)
    subprocess.run([
        "cmake", "-S", str(root / "native"), "-B", str(build),
        "-DCMAKE_OSX_DEPLOYMENT_TARGET=26.0", "-DCMAKE_BUILD_TYPE=Release",
        "-DCMAKE_EXPORT_COMPILE_COMMANDS=ON", "-DLIBCRYPTO=/deleted/libcrypto.a",
        "-DLIBPLIST=/deleted/libplist.a", "-DOPENSSL_INCLUDE_DIRS=/deleted/include",
        "-D__pkg_config_checked_OPENSSL=1", "-DPKG_CONFIG_ARGN=--with-path=/deleted/pkgconfig",
    ], check=True, stdout=subprocess.DEVNULL)
    cache = (build / "CMakeCache.txt").read_text()
    assert f"LIBCRYPTO:FILEPATH={prefix}/lib/libcrypto.a" in cache
    assert f"LIBPLIST:FILEPATH={prefix}/lib/libplist-2.0.a" in cache
    entries = json.loads((build / "compile_commands.json").read_text())
    crypto = next(entry for entry in entries if entry["file"].endswith("/crypto.c"))
    assert str(prefix / "include") in crypto["command"]
    assert "/deleted/" not in crypto["command"]
    subprocess.run(["cmake", "--build", str(build), "--target", "mirrorcore", "-j", "4"],
                   check=True, stdout=subprocess.DEVNULL)
print(f"Fresh native build ignores stale cache; all {objects} dependency objects target macOS 26")
