"""Headless Finder presentation, written on the image's own HFS+ volume."""

import argparse
from pathlib import Path
import subprocess

from ds_store import DSStore
from mac_alias import Alias


WINDOW_BOUNDS = "{{200, 160}, {560, 340}}"
ICON_LOCATIONS = {"Faderline.app": (150, 162), "Applications": (410, 162)}
BACKGROUND = ".background.tiff"
MODES = ("unsigned-development", "developer-id-notarized")


def window_settings():
    return {
        "WindowBounds": WINDOW_BOUNDS,
        "ShowToolbar": False,
        "ShowSidebar": False,
        "ContainerShowSidebar": False,
        "ShowStatusBar": False,
        "ShowPathbar": False,
        "ShowTabView": False,
        "PreviewPaneVisibility": False,
        "SidebarWidth": 0,
    }


def icon_settings(alias):
    return {
        "viewOptionsVersion": 1,
        "backgroundType": 2,
        "backgroundImageAlias": alias,
        "backgroundColorRed": 0.465,
        "backgroundColorGreen": 0.465,
        "backgroundColorBlue": 0.465,
        "gridOffsetX": 0.0,
        "gridOffsetY": 0.0,
        "gridSpacing": 100.0,
        "arrangeBy": "none",
        "showIconPreview": True,
        "showItemInfo": False,
        "labelOnBottom": True,
        "textSize": 13.0,
        "iconSize": 96.0,
        "scrollPositionX": 0.0,
        "scrollPositionY": 0.0,
    }


def write_presentation(mount, mode):
    mount = mount.resolve()
    background = mount / BACKGROUND
    subprocess.run(
        ["swift", str(Path(__file__).with_name("dmg-background.swift")),
         str(background), mode],
        check=True,
    )
    # Creating the alias here preserves volume-relative file IDs after remounting
    # elsewhere; an alias to a staging-directory image would not survive CI.
    alias = Alias.for_file(str(background)).to_bytes()
    with DSStore.open(str(mount / ".DS_Store"), "w+") as store:
        store["."]["vSrn"] = ("long", 1)
        store["."]["bwsp"] = window_settings()
        store["."]["icvp"] = icon_settings(alias)
        store["."]["icvl"] = ("type", b"icnv")
        for name, location in ICON_LOCATIONS.items():
            store[name]["Iloc"] = location


def verify_presentation(mount, mode, volume_name):
    def require(condition, message):
        if not condition:
            raise ValueError(message)

    require(
        {item.name for item in mount.iterdir() if not item.name.startswith(".")}
        == set(ICON_LOCATIONS),
        "DMG must show only Faderline.app and Applications",
    )
    require((mount / "Faderline.app").is_dir(), "Missing app bundle")
    require((mount / "Applications").is_symlink()
            and (mount / "Applications").readlink() == Path("/Applications"),
            "Invalid Applications shortcut")
    require(not (mount / "README.txt").exists(), "README.txt must not be packaged")
    background = mount / BACKGROUND
    require(background.is_file() and background.stat().st_size > 0,
            "Missing background image")
    with DSStore.open(str(mount / ".DS_Store"), "r") as store:
        require(store["."]["icvl"] == (b"type", b"icnv"), "Not Finder icon view")
        require(store["."]["bwsp"] == window_settings(), "Incorrect Finder window layout")
        actual_icons = store["."]["icvp"]
        require(actual_icons == icon_settings(actual_icons["backgroundImageAlias"]),
                "Incorrect Finder icon settings")
        for name, location in ICON_LOCATIONS.items():
            require(store[name]["Iloc"] == location, f"Incorrect icon position: {name}")
        alias = Alias.from_bytes(actual_icons["backgroundImageAlias"])
        require(alias.volume.name == volume_name, "Background alias has wrong volume")
        require(alias.target.filename == BACKGROUND, "Background alias has wrong file")
        require(alias.target.posix_path == f"/{BACKGROUND}",
                "Background alias must be volume-relative, not a staging path")
        require(alias.target.cnid == background.stat().st_ino,
                "Background alias does not reference this image's file")
        require(alias.target.folder_cnid == mount.stat().st_ino,
                "Background alias does not reference the volume root")
    require(("UNSIGNED DEVELOPMENT" in volume_name) == (mode == MODES[0]),
            "Incorrect unsigned-development volume labeling")
    print(f"Verified Finder layout: 560x340, 96px icons, {ICON_LOCATIONS}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("write", "verify"))
    parser.add_argument("mount", type=Path)
    parser.add_argument("--mode", choices=MODES, required=True)
    parser.add_argument("--volume-name", required=True)
    args = parser.parse_args()
    if args.action == "write":
        write_presentation(args.mount, args.mode)
    verify_presentation(args.mount, args.mode, args.volume_name)


if __name__ == "__main__":
    main()
