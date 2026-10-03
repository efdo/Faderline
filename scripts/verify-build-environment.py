#!/usr/bin/env python3

import argparse
import os
from pathlib import Path
import plistlib
import subprocess
import sys


def command(*args):
    return subprocess.check_output(args, text=True).strip()


def require_equal(label, actual, expected):
    print(f"{label}: {actual}", flush=True)
    if actual != expected:
        raise ValueError(f"{label}: expected {expected!r}, got {actual!r}")


def verify_toolchain(expected):
    print(f"macOS: {command('sw_vers', '-productVersion')} "
          f"({command('sw_vers', '-buildVersion')})", flush=True)
    print(f"Runner image: {os.environ.get('ImageOS', 'local')} "
          f"{os.environ.get('ImageVersion', '')}", flush=True)
    print(f"DEVELOPER_DIR: {os.environ.get('DEVELOPER_DIR', '(system selection)')}",
          flush=True)
    require_equal("Host architecture", command("uname", "-m"), "arm64")
    require_equal(
        "Xcode",
        command("xcodebuild", "-version"),
        f"Xcode {expected['EXPECTED_XCODE_VERSION']}\n"
        f"Build version {expected['EXPECTED_XCODE_BUILD']}",
    )
    require_equal(
        "macOS SDK",
        command("xcrun", "--sdk", "macosx", "--show-sdk-version"),
        expected["EXPECTED_MACOS_SDK_VERSION"],
    )
    print(command("swift", "--version"), flush=True)


def verify_app(app, expected):
    with (app / "Contents/Info.plist").open("rb") as source:
        metadata = plistlib.load(source)
    required = {
        "CFBundleIdentifier": "com.faderline.app",
        "CFBundleExecutable": "Faderline",
        "DTSDKName": f"macosx{expected['EXPECTED_MACOS_SDK_VERSION']}",
        "DTXcode": expected["EXPECTED_DTXCODE"],
        "DTXcodeBuild": expected["EXPECTED_XCODE_BUILD"],
        "LSMinimumSystemVersion": "15.0",
    }
    print(f"Built app: {app}", flush=True)
    for key, value in required.items():
        require_equal(key, metadata.get(key), value)
    require_equal(
        "Executable architectures",
        command("lipo", "-archs", str(app / "Contents/MacOS/Faderline")),
        "arm64",
    )


def main():
    parser = argparse.ArgumentParser(
        description="Verify pinned CI toolchain and optional Faderline bundle metadata."
    )
    parser.add_argument("--app", type=Path)
    args = parser.parse_args()
    keys = (
        "EXPECTED_XCODE_VERSION", "EXPECTED_XCODE_BUILD",
        "EXPECTED_DTXCODE", "EXPECTED_MACOS_SDK_VERSION",
    )
    expected = {}
    try:
        for key in keys:
            value = os.environ.get(key)
            if not value:
                raise ValueError(f"Set {key} explicitly; no toolchain fallback is allowed")
            expected[key] = value
        verify_toolchain(expected)
        if args.app is not None:
            verify_app(args.app, expected)
    except (OSError, ValueError, plistlib.InvalidFileException,
            subprocess.CalledProcessError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
