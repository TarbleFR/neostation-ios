#!/usr/bin/env python3
"""Validate that a packaged NeoStation IPA contains the legal/source bundle."""

from __future__ import annotations

import argparse
import json
import zipfile
from pathlib import Path

REQUIRED = (
    "NeoStation-GPL-3.0.txt",
    "NeoStation-NOTICE.md",
    "LEGAL_AND_CREDITS.md",
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
    "BUILD_SOURCE_IDENTITY.json",
)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("ipa", type=Path)
    parser.add_argument("--build-number", required=True)
    parser.add_argument("--commit", required=True)
    args = parser.parse_args()

    with zipfile.ZipFile(args.ipa) as archive:
        names = archive.namelist()
        app_roots = sorted(
            {
                name.split("/", 2)[1]
                for name in names
                if name.startswith("Payload/")
                and name.count("/") >= 2
                and name.split("/", 2)[1].endswith(".app")
            }
        )
        if len(app_roots) != 1:
            raise SystemExit(f"Expected one app bundle, found: {app_roots}")
        prefix = f"Payload/{app_roots[0]}/Legal/"

        missing = [name for name in REQUIRED if prefix + name not in names]
        if missing:
            raise SystemExit("Missing legal files: " + ", ".join(missing))

        identity = json.loads(
            archive.read(prefix + "BUILD_SOURCE_IDENTITY.json").decode("utf-8")
        )
        if identity["build_number"] != str(args.build_number):
            raise SystemExit(
                f"Legal identity build mismatch: {identity['build_number']}"
            )
        if identity["host_commit"] != args.commit:
            raise SystemExit(
                f"Legal identity commit mismatch: {identity['host_commit']}"
            )

        notice = archive.read(prefix + "NeoStation-NOTICE.md").decode("utf-8")
        if "UPSTREAM NEOSTATION ATTRIBUTION" not in notice:
            raise SystemExit("NeoStation notice is incomplete")

        credits = archive.read(prefix + "LEGAL_AND_CREDITS.md").decode("utf-8")
        for marker in (
            "Dolphin / DolphiniOS",
            "RPCS3 / XITRIX",
            "ARMSX2 / PCSX2",
            "Dusklight",
            "KartPad / WiiCompiled",
            "StikJIT",
            "GameDB / GameDB-PS3",
        ):
            if marker not in credits:
                raise SystemExit(f"Missing legal credit marker: {marker}")

    print("NeoStation IPA legal bundle validated.")


if __name__ == "__main__":
    main()
