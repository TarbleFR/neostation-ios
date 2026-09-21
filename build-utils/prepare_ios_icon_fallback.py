#!/usr/bin/env python3
"""Install classic SpringBoard icon fallbacks beside the modern AppIcon catalog."""
from __future__ import annotations

import argparse
import plistlib
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "assets/images/fork-icon-valid.jpg"
RUNNER = ROOT / "ios/Runner"
INFO = RUNNER / "Info.plist"
FALLBACK_DIR = RUNNER

FALLBACKS = {
    "NeoStationIcon60@2x.png": 120,
    "NeoStationIcon60@3x.png": 180,
    "NeoStationIcon76@2x~ipad.png": 152,
    "NeoStationIcon83.5@2x~ipad.png": 167,
    "NeoStationIcon1024.png": 1024,
}


def png_size(path: Path) -> tuple[int, int]:
    data = path.read_bytes()
    if len(data) < 24 or data[:8] != b"\x89PNG\r\n\x1a\n" or data[12:16] != b"IHDR":
        raise RuntimeError(f"Not a PNG file: {path}")
    return int.from_bytes(data[16:20], "big"), int.from_bytes(data[20:24], "big")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.parse_args()

    if not SOURCE.is_file():
        raise SystemExit(f"Missing icon source: {SOURCE}")
    if not INFO.is_file():
        raise SystemExit(f"Missing generated Info.plist: {INFO}")

    FALLBACK_DIR.mkdir(parents=True, exist_ok=True)
    for name, pixels in FALLBACKS.items():
        destination = FALLBACK_DIR / name
        subprocess.run(
            ["sips", "-s", "format", "png", "-z", str(pixels), str(pixels),
             str(SOURCE), "--out", str(destination)],
            check=True,
            stdout=subprocess.DEVNULL,
        )
        actual = png_size(destination)
        if actual != (pixels, pixels):
            raise SystemExit(
                f"Unexpected fallback icon dimensions for {name}: {actual[0]}x{actual[1]}"
            )

    info = plistlib.loads(INFO.read_bytes())
    iphone = ["NeoStationIcon60"]
    ipad = ["NeoStationIcon60", "NeoStationIcon76", "NeoStationIcon83.5"]

    info["CFBundleIconName"] = "AppIcon"
    info["CFBundleIconFiles"] = ipad

    icons = dict(info.get("CFBundleIcons") or {})
    primary = dict(icons.get("CFBundlePrimaryIcon") or {})
    primary["CFBundleIconName"] = "AppIcon"
    primary["CFBundleIconFiles"] = iphone
    icons["CFBundlePrimaryIcon"] = primary
    info["CFBundleIcons"] = icons

    icons_ipad = dict(info.get("CFBundleIcons~ipad") or {})
    primary_ipad = dict(icons_ipad.get("CFBundlePrimaryIcon") or {})
    primary_ipad["CFBundleIconName"] = "AppIcon"
    primary_ipad["CFBundleIconFiles"] = ipad
    icons_ipad["CFBundlePrimaryIcon"] = primary_ipad
    info["CFBundleIcons~ipad"] = icons_ipad

    INFO.write_bytes(plistlib.dumps(info, fmt=plistlib.FMT_XML, sort_keys=False))
    print("Prepared SpringBoard fallback PNGs and explicit icon plist keys.")


if __name__ == "__main__":
    main()
