#!/usr/bin/env python3
"""Contract for the NeoStation iOS 2.8-second launch movie."""

from pathlib import Path
import hashlib

ROOT = Path(__file__).resolve().parents[1]
ASSET = ROOT / "assets/videos/neostation_ios_intro.mp4"
EXPECTED_SHA256 = "0c70a447e0754c6a1bfee650dba2881231dc8686e6158e3b6d1bbfaffff9a6d6"
EXPECTED_SIZE = 963_689


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


def main() -> None:
    require(ASSET.is_file(), "missing bundled NeoStation iOS intro movie")
    payload = ASSET.read_bytes()
    require(len(payload) == EXPECTED_SIZE, "intro movie byte size changed")
    require(hashlib.sha256(payload).hexdigest() == EXPECTED_SHA256,
            "intro movie no longer matches the approved upload")
    require(b"ftyp" in payload[:32], "intro movie is not an MP4 container")

    pubspec = (ROOT / "pubspec.yaml").read_text()
    main_dart = (ROOT / "lib/main.dart").read_text()
    widget = (ROOT / "lib/widgets/startup_intro_video.dart").read_text()

    require("assets/videos/neostation_ios_intro.mp4" in pubspec,
            "intro movie is not registered as a Flutter asset")
    require("_startupIntroAsset = 'assets/videos/neostation_ios_intro.mp4'" in main_dart,
            "startup does not point at the approved movie")
    require("await _waitForStartupIntro();" in main_dart,
            "main app can replace the intro before one-shot playback completes")
    require("if (Platform.isIOS)" in main_dart and
            "StartupIntroVideo(" in main_dart,
            "intro movie is not scoped to the iOS startup surface")
    require("setLooping(false)" in widget, "intro movie must remain one-shot")
    require("setVolume(0.0)" in widget, "intro movie must remain silent")
    require("BoxFit.contain" in widget, "intro movie must not be cropped")

    print("NeoStation iOS startup intro video contract: OK")


if __name__ == "__main__":
    main()
