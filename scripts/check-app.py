#!/usr/bin/env python3
"""Check a relocated app's real startup and bundled resources before publishing."""
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import time


def check(app):
    with tempfile.TemporaryDirectory(prefix="startup-check-", dir=".build") as directory:
        root = Path(directory).resolve()
        relocated = root / "TinyMirror.app"
        subprocess.run(["ditto", str(app), str(relocated)], check=True)
        home = root / "home"
        home.mkdir()
        environment = dict(os.environ, CFFIXED_USER_HOME=str(home), TINYMIRROR_DEBUG="1")
        with (root / "startup.log").open("w+") as log:
            process = subprocess.Popen(
                [str(relocated / "Contents/MacOS/TinyMirror")],
                stdout=log, stderr=subprocess.STDOUT, env=environment)
            try:
                deadline = time.monotonic() + 5
                while time.monotonic() < deadline and process.poll() is None:
                    time.sleep(0.1)
                log.seek(0)
                output = log.read()
                if process.poll() is not None:
                    raise RuntimeError(f"App exited during startup ({process.returncode}):\n{output}")
                if "[TinyMirror] receiver started" not in output:
                    raise RuntimeError(f"Receiver did not finish starting:\n{output}")
                if "status item has no window" in output:
                    raise RuntimeError(f"Menu bar item was not placed:\n{output}")
            finally:
                if process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait()

        resources = relocated / "Contents/Resources"
        for language in ("en", "zh-Hans"):
            for name in ("Localizable.strings", "InfoPlist.strings"):
                if not (resources / f"{language}.lproj" / name).is_file():
                    raise RuntimeError(f"Missing {language}/{name}")
        records = json.loads(subprocess.check_output(
            ["/usr/bin/assetutil", "--info", str(resources / "Assets.car")], text=True))
        names = {record.get("Name") for record in records}
        if not {"AppIcon", "MenuBarIcon", "MenuBarIconConnected"} <= names:
            raise RuntimeError("Missing compiled app or menu bar icons")
        if not (resources / "AppIcon.icns").is_file():
            raise RuntimeError("Missing static app icon")
        with (relocated / "Contents/Info.plist").open("rb") as file:
            if plistlib.load(file).get("CFBundleIconName") != "AppIcon":
                raise RuntimeError("App icon metadata is incorrect")
        subprocess.run(["codesign", "--verify", "--deep", "--strict", str(relocated)], check=True)
        print("PASS: relocated app starts, receiver initializes, localized strings and icons are bundled")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("Usage: python3 scripts/check-app.py PATH/TO/TinyMirror.app")
    try:
        check(Path(sys.argv[1]).resolve())
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        sys.exit(f"FAIL: {error}")
