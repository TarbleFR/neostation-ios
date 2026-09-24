#!/usr/bin/env python3
"""Validate KartPad's lazy embedded Core inside a packaged NeoStation IPA."""
from __future__ import annotations

import argparse
import hashlib
import json
import plistlib
from pathlib import Path
import sys
import zipfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "packages/dolphin_internal_bridge/ci"))
from verify_ipa import macho  # noqa: E402


def validate_absent(ipa: Path, build_number: str):
    with zipfile.ZipFile(ipa) as z:
        apps = [
            n for n in z.namelist()
            if n.startswith("Payload/")
            and n.endswith(".app/Info.plist")
            and n.count("/") == 2
        ]
        assert len(apps) == 1, "IPA must contain one application"
        app = apps[0].removesuffix("Info.plist")
        info = plistlib.loads(z.read(apps[0]))
        assert str(info["CFBundleVersion"]) == str(build_number)
        assert not any(
            n.startswith(app + "Frameworks/KartPadCore.framework/")
            for n in z.namelist()
        ), "Unexpected KartPadCore.framework in non-candidate IPA"
        assert app + "KartPad-native-identity.json" not in z.namelist(),             "Unexpected KartPad identity in non-candidate IPA"
        assert not any("KartPad.app/" in n for n in z.namelist()),             "Standalone KartPad app must never be nested"
    return {
        "build": str(build_number),
        "kartPadCorePresent": False,
        "standaloneKartPadPresent": False,
    }


def validate(ipa: Path, identity_path: Path, core_host: str, build_number: str):
    identity = json.loads(identity_path.read_text())
    pins = json.loads((ROOT / "build-utils/kartpad/source.json").read_text())
    assert identity["host_commit"] == core_host, "Wrong KartPad Core host commit"
    assert identity["upstream_commit"] == pins["releaseTagCommit"], "Wrong KartPad source"
    assert identity["ios_runtime_commit"] == pins["iosRuntimeCommit"], "Wrong KartPad iOS runtime"
    assert identity["abi_version"] == pins["neoStationAbi"], "Wrong KartPad ABI"
    assert identity["runtime_identity"] == pins["runtimeIdentity"], "Wrong KartPad runtime profile"
    assert identity["translated_function_count"] == pins["discProfile"]["expectedTranslatedFunctions"]

    with zipfile.ZipFile(ipa) as z:
        apps = [
            n for n in z.namelist()
            if n.startswith("Payload/")
            and n.endswith(".app/Info.plist")
            and n.count("/") == 2
        ]
        assert len(apps) == 1, "IPA must contain one application"
        app = apps[0].removesuffix("Info.plist")
        info = plistlib.loads(z.read(apps[0]))
        assert str(info["CFBundleVersion"]) == str(build_number)

        framework = app + "Frameworks/KartPadCore.framework/"
        binary_path = framework + "KartPadCore"
        assert binary_path in z.namelist(), "KartPadCore.framework missing"
        binary = z.read(binary_path)
        assert hashlib.sha256(binary).hexdigest() == identity["sha256"], "KartPadCore bytes changed"

        core = macho(binary)
        assert core["fileType"] == 6, "KartPadCore is not a dynamic library"
        assert core["platform"] == 2, "KartPadCore is not an iPhoneOS image"
        assert core["id"] == "@rpath/KartPadCore.framework/KartPadCore",             "KartPadCore install name is not @rpath-relative"
        assert "_NeoKartPad_GetAPI" in core["definedSymbols"], "KartPad ABI export missing"
        assert "_main" not in core["definedSymbols"],             "Standalone KartPad main entry point remains"
        assert "_UIApplicationMain" not in core["undefinedSymbols"],             "KartPadCore still depends on UIApplicationMain"

        packaged_identity = app + "KartPad-native-identity.json"
        assert packaged_identity in z.namelist(), "KartPad identity missing from app"
        assert json.loads(z.read(packaged_identity)) == identity

        # Lazy-load boundary: no Mach-O other than the Core may carry a dyld
        # load command for KartPadCore.
        for name in z.namelist():
            if name == binary_path or z.getinfo(name).is_dir():
                continue
            with z.open(name) as stream:
                magic = stream.read(4)
            if magic not in (
                b"\xcf\xfa\xed\xfe",
                b"\xca\xfe\xba\xbe",
                b"\xca\xfe\xba\xbf",
            ):
                continue
            image = macho(z.read(name))
            assert not any(
                "KartPadCore" in dependency["path"]
                for dependency in image["dependencies"]
            ), name

        assert not any("KartPad.app/" in name for name in z.namelist()),             "Standalone KartPad app must never be nested"

    return {
        "build": str(build_number),
        "coreHostCommit": core_host,
        "coreSha256": identity["sha256"],
        "runtimeIdentity": identity["runtime_identity"],
        "translatedFunctions": identity["translated_function_count"],
        "passiveLoad": True,
    }


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("ipa", type=Path)
    parser.add_argument("--identity", type=Path)
    parser.add_argument("--core-host")
    parser.add_argument("--build-number", required=True)
    parser.add_argument("--expect-absent", action="store_true")
    args = parser.parse_args()
    if args.expect_absent:
        result = validate_absent(args.ipa, args.build_number)
    else:
        if args.identity is None or not args.core_host:
            parser.error("--identity and --core-host are required unless --expect-absent is used")
        result = validate(
            args.ipa,
            args.identity,
            args.core_host,
            args.build_number,
        )
    print(json.dumps(result, indent=2))
