#!/usr/bin/env python3
"""After make build, verify the bundle and safe installation inside .build/."""
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
os.chdir(root)
app = root / "dist/MirrorDeck.app"
info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
assert info["CFBundleIdentifier"] == "com.emersongarland.MirrorDeck"
assert info["LSMinimumSystemVersion"] == "26.0"
assert info["CFBundleLocalizations"] == ["en", "zh-Hans"]
assert "__" not in info["CFBundleShortVersionString"]
assert "__" not in info["CFBundleVersion"]
make_env = dict(os.environ)
make_env.pop("CONFIGURATION", None)
make_env.pop("MAKEFLAGS", None)
for configuration in ["debug", "release"]:
    command = ["make", "-n", "install"]
    if configuration == "release":
        command.append("CONFIGURATION=release")
    plan = subprocess.run(command, env=make_env, capture_output=True, text=True, check=True)
    assert 'CONFIGURATION="debug" ./scripts/build-app.sh' in plan.stdout
    assert 'CONFIGURATION="release" ./scripts/build-app.sh' not in plan.stdout
for relative in [
    "Contents/MacOS/MirrorDeck", "Contents/Frameworks/libMirrorCore.dylib",
    "Contents/Resources/MirrorDeck_MirrorDeck.bundle", "Contents/Resources/AppIcon.icns",
    "Contents/Resources/en.lproj/InfoPlist.strings", "Contents/Resources/zh-Hans.lproj/InfoPlist.strings",
    "Contents/Resources/licenses/NOTICE.md",
]:
    assert (app / relative).exists(), relative
subprocess.run(["codesign", "--verify", "--strict", str(app)], check=True)
for code in [app, app / "Contents/Frameworks/libMirrorCore.dylib"]:
    signature = subprocess.run(["codesign", "-dvv", str(code)], capture_output=True, text=True, check=True)
    assert "Signature=adhoc" in signature.stderr and "Authority=" not in signature.stderr
notarize = subprocess.run(["./scripts/package.sh"], env=dict(os.environ, NOTARIZE="1"),
                          capture_output=True, text=True)
assert notarize.returncode != 0 and "cannot be notarized" in notarize.stderr
invalid = subprocess.run(["./scripts/build-app.sh"], env=dict(os.environ, CONFIGURATION="invalid"),
                         capture_output=True, text=True)
assert invalid.returncode != 0 and "CONFIGURATION" in invalid.stderr


def install(directory, env=None, succeeds=True):
    result = subprocess.run(["./scripts/install-app.sh", str(directory)], env=env, capture_output=True, text=True)
    assert (result.returncode == 0) == succeeds, result.stdout + result.stderr


with tempfile.TemporaryDirectory(prefix="check-build-", dir=root / ".build") as temporary:
    temporary = Path(temporary)
    destination = temporary / "Applications With Spaces"
    install(destination)
    installed = destination / "MirrorDeck.app"
    marker = installed / "Contents/Resources/previous-build-marker"
    marker.write_text("must survive a failed replacement")

    # Fail only the final rename; the previous bundle must be restored intact.
    tools = temporary / "tools"
    tools.mkdir()
    move = tools / "mv"
    move.write_text('#!/bin/bash\ncase "$1" in */.mirrordeck-install.*/MirrorDeck.app) exit 1 ;; esac\nexec /bin/mv "$@"\n')
    move.chmod(0o755)
    install(destination, env=dict(os.environ, PATH=f"{tools}:{os.environ['PATH']}"), succeeds=False)
    assert marker.read_text() == "must survive a failed replacement"
    assert not list(destination.glob(".mirrordeck-install.*"))

    install(destination)
    assert not marker.exists(), "Installing must replace, not merge with stale bundle resources"
    subprocess.run(["codesign", "--verify", "--strict", str(installed)], check=True)

    symlink_directory = temporary / "Symlink Destination"
    symlink_directory.mkdir()
    (symlink_directory / "MirrorDeck.app").symlink_to(installed)
    install(symlink_directory, succeeds=False)
    assert (symlink_directory / "MirrorDeck.app").is_symlink()

    other = temporary / "Different App/MirrorDeck.app/Contents"
    other.mkdir(parents=True)
    other_info = plistlib.dumps({"CFBundleIdentifier": "example.unrelated"})
    (other / "Info.plist").write_bytes(other_info)
    install(other.parent.parent, succeeds=False)
    assert (other / "Info.plist").read_bytes() == other_info
    install(app / "Contents", succeeds=False)

subprocess.run(["codesign", "--verify", "--strict", str(app)], check=True)
print("Build bundle, installation, replacement rollback and path safety checks passed")
