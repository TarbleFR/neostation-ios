#!/usr/bin/env python3
"""Fail-closed validation for NeoStation's embedded ARMSX2 distribution."""
from __future__ import annotations

import argparse
import os
import plistlib
import subprocess
import tempfile
import zipfile
from pathlib import Path


def demand(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


def run_output(*args: str) -> str:
    result = subprocess.run(
        list(args),
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    return result.stdout


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("ipa", type=Path)
    parser.add_argument("--source-revision", required=True)
    parser.add_argument("--build-number")
    args = parser.parse_args()

    demand(args.ipa.is_file(), f"IPA not found: {args.ipa}")
    with zipfile.ZipFile(args.ipa) as archive:
        names = archive.namelist()
        app_roots = sorted({
            "/".join(name.split("/")[:2]) + "/"
            for name in names
            if name.startswith("Payload/")
            and len(name.split("/")) >= 2
            and name.split("/")[1].endswith(".app")
        })
        demand(len(app_roots) == 1, f"Expected one top-level app, found {app_roots}")
        app = app_roots[0]

        info_name = app + "Info.plist"
        demand(info_name in names, "NeoStation Info.plist missing from IPA")
        info = plistlib.loads(archive.read(info_name))
        if args.build_number:
            demand(
                str(info.get("CFBundleVersion", "")) == str(args.build_number),
                f"Unexpected build number: {info.get('CFBundleVersion')}",
            )

        schemes = {
            str(value).lower()
            for value in info.get("LSApplicationQueriesSchemes", [])
            if isinstance(value, str)
        }
        demand("armsx2" not in schemes, "Retired external armsx2 query scheme remains")

        url_schemes: set[str] = set()
        for entry in info.get("CFBundleURLTypes", []):
            if isinstance(entry, dict):
                for value in entry.get("CFBundleURLSchemes", []):
                    if isinstance(value, str):
                        url_schemes.add(value.lower())
        demand("armsx2" not in url_schemes, "Retired external armsx2 URL scheme remains")

        core_root = app + "Frameworks/ARMSX2Core.framework/"
        core_binary = core_root + "ARMSX2Core"
        core_info = core_root + "Info.plist"
        demand(core_binary in names, "ARMSX2Core.framework binary is missing")
        demand(core_info in names, "ARMSX2Core.framework Info.plist is missing")
        framework_info = plistlib.loads(archive.read(core_info))
        demand(
            framework_info.get("CFBundleIdentifier")
            == "com.neogamelab.neostation.ARMSX2Core",
            f"Unexpected ARMSX2 Core bundle ID: {framework_info.get('CFBundleIdentifier')}",
        )

        helper_prefix = app + "PlugIns/ARMSX2JITHelper.appex/"
        helper_info_name = helper_prefix + "Info.plist"
        demand(helper_info_name in names, "Embedded ARMSX2 JIT helper is missing")
        helper_info = plistlib.loads(archive.read(helper_info_name))
        demand(
            helper_info.get("NeoStationARMSX2JITHelper") == "1",
            "ARMSX2 helper identity marker is missing",
        )
        extension = helper_info.get("NSExtension", {})
        demand(
            isinstance(extension, dict)
            and extension.get("NSExtensionPointIdentifier") == "com.apple.share-services",
            "ARMSX2 helper is not the expected app extension",
        )

        nested_apps = [
            name for name in names
            if name.startswith(app)
            and ".app/" in name[len(app):]
            and "armsx2" in name.lower()
        ]
        demand(not nested_apps, "Standalone ARMSX2 app is nested in NeoStation")

        for forbidden in (
            b"armsx2://",
            b"NeoStation+ARMSX2+JIT",
            b"/Users/runner/",
            b"/Users/builder/",
        ):
            demand(
                forbidden not in archive.read(core_binary),
                f"Forbidden Core marker present: {forbidden!r}",
            )

        with tempfile.TemporaryDirectory(prefix="armsx2-ipa-") as temp:
            root = Path(temp)
            binary_path = root / "ARMSX2Core"
            binary_path.write_bytes(archive.read(core_binary))
            os.chmod(binary_path, 0o755)

            file_output = run_output("file", str(binary_path))
            demand("arm64" in file_output, f"ARMSX2 Core is not arm64: {file_output.strip()}")

            nm_output = run_output("nm", "-gj", str(binary_path))
            demand(
                "_NeoARMSX2_GetAPI" in nm_output.splitlines(),
                "NeoARMSX2_GetAPI export is missing from packaged Core",
            )

            dependencies = run_output("otool", "-L", str(binary_path))
            demand(
                "@rpath/ARMSX2Core.framework/ARMSX2Core" in dependencies,
                "ARMSX2 Core install name is not @rpath-relative",
            )
            for line in dependencies.splitlines()[1:]:
                stripped = line.strip()
                demand(
                    not stripped.startswith("/Users/"),
                    f"Absolute CI dependency leaked into ARMSX2 Core: {stripped}",
                )

            strings = run_output("strings", str(binary_path))
            demand(
                args.source_revision in strings,
                "Pinned ARMSX2 source revision is missing from packaged Core",
            )

    print(
        "ARMSX2 IPA validation passed: single NeoStation app, embedded arm64 Core, "
        "embedded isolated JIT helper, no external ARMSX2 launch contract."
    )


if __name__ == "__main__":
    main()
