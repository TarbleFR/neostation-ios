#!/usr/bin/env python3
"""Embed NeoStation and third-party legal notices into a built iOS app.

This affects future builds only. It never rewrites an existing IPA asset.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LEGAL_ASSETS = ROOT / "assets" / "legal"

REQUIRED_LEGAL_FILES = (
    "THIRD_PARTY_NOTICES.md",
    "Dolphin-COPYING.txt",
    "RPCS3-GPL-2.0.txt",
    "ARMSX2-GPL-3.0.txt",
    "Dusklight-CC0-1.0.txt",
    "KartPad-RIGHTS_AND_LICENSES.md",
    "KartPad-THIRD_PARTY_NOTICES.md",
    "StikJIT-MPL-2.0.txt",
    "NeoStation-Assets-CC-BY-NC-SA-4.0.txt",
    "RiiSU-ATTRIBUTION.md",
    "NeoStation-GPL-3.0.txt",
    "GameDB-PS3-GPL-3.0.txt",
    "Guest-Page-Relay-MIT.txt",
)


def load_json(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def require_pinned_header(path: Path, expected: str) -> None:
    text = path.read_text(encoding="utf-8")
    marker = f"Pinned revision/tag: {expected}"
    if marker not in text:
        raise SystemExit(
            f"Legal notice {path.relative_to(ROOT)} is stale: expected {marker!r}"
        )


def copy_file(source: Path, destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, destination)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", type=Path)
    parser.add_argument("--build-number")
    parser.add_argument("--dolphin-sha", required=True)
    parser.add_argument("--validate-only", action="store_true",
                        help="Check source notices without requiring or writing an app bundle")
    args = parser.parse_args()

    if not args.validate_only:
        if args.app is None or args.build_number is None:
            parser.error("--app and --build-number are required when embedding notices")
        app = args.app.resolve()
        if not app.is_dir() or app.suffix != ".app":
            raise SystemExit(f"Expected built .app bundle, got: {app}")

    for name in REQUIRED_LEGAL_FILES:
        if not (LEGAL_ASSETS / name).is_file():
            raise SystemExit(f"Missing legal bundle file: assets/legal/{name}")

    rpcs3 = load_json(ROOT / "build-utils/rpcs3/canonical-source.json")
    armsx2 = load_json(ROOT / "build-utils/armsx2/source.json")
    dusklight = load_json(ROOT / "build-utils/dusklight/source.json")
    kartpad = load_json(ROOT / "build-utils/kartpad/source.json")

    require_pinned_header(
        LEGAL_ASSETS / "Dolphin-COPYING.txt", args.dolphin_sha
    )
    require_pinned_header(
        LEGAL_ASSETS / "RPCS3-GPL-2.0.txt", rpcs3["upstream_commit"]
    )
    require_pinned_header(
        LEGAL_ASSETS / "ARMSX2-GPL-3.0.txt", armsx2["revision"]
    )
    require_pinned_header(
        LEGAL_ASSETS / "Dusklight-CC0-1.0.txt", dusklight["commit"]
    )
    require_pinned_header(
        LEGAL_ASSETS / "KartPad-RIGHTS_AND_LICENSES.md",
        kartpad["releaseTagCommit"],
    )
    require_pinned_header(
        LEGAL_ASSETS / "KartPad-THIRD_PARTY_NOTICES.md",
        kartpad["releaseTagCommit"],
    )
    require_pinned_header(
        LEGAL_ASSETS / "StikJIT-MPL-2.0.txt", "1.9.0"
    )

    if args.validate_only:
        print("Validated all required notices and pinned revisions before compilation")
        return

    destination = app / "Legal"
    if destination.exists():
        shutil.rmtree(destination)
    destination.mkdir(parents=True)

    copy_file(ROOT / "LICENSE.md", destination / "NeoStation-GPL-3.0.txt")
    copy_file(ROOT / "NOTICE.md", destination / "NeoStation-NOTICE.md")
    copy_file(
        ROOT / "docs/LEGAL_AND_CREDITS.md",
        destination / "LEGAL_AND_CREDITS.md",
    )

    for name in REQUIRED_LEGAL_FILES:
        copy_file(LEGAL_ASSETS / name, destination / name)

    dusklight_licenses = ROOT / "dist/dusklight/licenses"
    if dusklight_licenses.is_dir():
        shutil.copytree(
            dusklight_licenses,
            destination / "Dusklight-Dependency-Licenses",
        )

    identity = {
        "schema": 1,
        "build_number": str(args.build_number),
        "host_commit": os.environ.get("GITHUB_SHA", ""),
        "source_repository": "https://github.com/TarbleFR/neostation-ios",
        "dolphin": {
            "repository": "https://github.com/OatmealDome/dolphin-ios",
            "revision": args.dolphin_sha,
        },
        "rpcs3": {
            "repository": "https://github.com/XITRIX/rpcs3",
            "revision": rpcs3["upstream_commit"],
            "license_note": "Most RPCS3 files: GPL-2.0-only; per-file notices apply",
        },
        "armsx2": {
            "repository": armsx2.get(
                "repository", "https://github.com/ARMSX2/ARMSX2.git"
            ),
            "revision": armsx2["revision"],
        },
        "dusklight": {
            "repository": dusklight["repository"],
            "revision": dusklight["commit"],
            "sdl_revision": dusklight["sdl"]["commit"],
            "submodules": dusklight["submodules"],
        },
        "kartpad": {
            "repository": "https://github.com/chrissotraidis/kartpad",
            "release": kartpad["release"],
            "release_tag_commit": kartpad["releaseTagCommit"],
            "compiled_source": kartpad["compiledSource"],
            "ios_runtime_commit": kartpad["iosRuntimeCommit"],
            "public_source_limitation": kartpad["publicSourceLimitation"],
        },
        "stikjit": {
            "repository": "https://github.com/StikDebug/StikJIT",
            "version": "1.9.0",
            "license": "MPL-2.0",
        },
    }
    (destination / "BUILD_SOURCE_IDENTITY.json").write_text(
        json.dumps(identity, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )

    print(f"Embedded legal bundle: {destination}")
    for item in sorted(destination.rglob("*")):
        if item.is_file():
            print(item.relative_to(app))


if __name__ == "__main__":
    main()
