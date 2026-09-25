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
sys.path.insert(0, str(ROOT / "build-utils/kartpad"))
from patch_donor_language_bridge import validate_bridge  # noqa: E402

OFFICIAL_IPA_SHA256 = "1474809c8e14447c159c30902aaf66b022db89d28a3181d69acfac3467508f58"


def _single_app(z: zipfile.ZipFile) -> tuple[str, dict]:
    apps = [
        n for n in z.namelist()
        if n.startswith("Payload/")
        and n.endswith(".app/Info.plist")
        and n.count("/") == 2
    ]
    assert len(apps) == 1, "IPA must contain one application"
    app = apps[0].removesuffix("Info.plist")
    info = plistlib.loads(z.read(apps[0]))
    return app, info


def validate_absent(ipa: Path, build_number: str):
    with zipfile.ZipFile(ipa) as z:
        app, info = _single_app(z)
        assert str(info["CFBundleVersion"]) == str(build_number)
        assert not any(
            n.startswith(app + "Frameworks/KartPadCore.framework/")
            for n in z.namelist()
        ), "Unexpected KartPadCore.framework in non-candidate IPA"
        assert not any(
            n.startswith(app + "Frameworks/KartPadRuntime.framework/")
            for n in z.namelist()
        ), "Unexpected KartPadRuntime.framework in non-candidate IPA"
        assert app + "KartPad-native-identity.json" not in z.namelist(),             "Unexpected KartPad identity in non-candidate IPA"
        assert not any("KartPad.app/" in n for n in z.namelist()),             "Standalone KartPad app must never be nested"
    return {
        "build": str(build_number),
        "kartPadCorePresent": False,
        "kartPadRuntimePresent": False,
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
        app, info = _single_app(z)
        assert str(info["CFBundleVersion"]) == str(build_number)

        binary_path = app + "Frameworks/KartPadCore.framework/KartPadCore"
        assert binary_path in z.namelist(), "KartPadCore.framework missing"
        binary = z.read(binary_path)
        assert hashlib.sha256(binary).hexdigest() == identity["sha256"],             "KartPadCore bytes changed"

        core = macho(binary)
        assert core["fileType"] == 6, "KartPadCore is not a dynamic library"
        assert core["platform"] == 2, "KartPadCore is not an iPhoneOS image"
        assert core["id"] == "@rpath/KartPadCore.framework/KartPadCore",             "KartPadCore install name is not @rpath-relative"
        assert "_NeoKartPad_GetAPI" in core["definedSymbols"], "KartPad ABI export missing"
        assert "_NeoKartPad_PrepareUserGame" in core["definedSymbols"], \
            "KartPad RVZ preparation export missing"
        assert "_main" not in core["definedSymbols"],             "Standalone KartPad main entry point remains"
        assert "_UIApplicationMain" not in core["undefinedSymbols"],             "KartPadCore still depends on UIApplicationMain"
        assert not any(
            "KartPadRuntime.framework" in dependency["path"]
            for dependency in core["dependencies"]
        ), "KartPadCore must lazy-load KartPadRuntime"

        mode = identity.get("mode", "source-built")
        runtime_binary_path = app + "Frameworks/KartPadRuntime.framework/KartPadRuntime"
        if mode == "official-ipa-donor":
            assert identity.get("official_ipa_sha256") == OFFICIAL_IPA_SHA256
            assert runtime_binary_path in z.namelist(),                 "KartPad donor runtime framework missing"
            runtime_bytes = z.read(runtime_binary_path)
            assert hashlib.sha256(runtime_bytes).hexdigest() == identity["runtime_sha256"],                 "KartPad donor runtime bytes changed"
            validate_bridge(runtime_bytes)
            runtime = macho(runtime_bytes)
            assert runtime["fileType"] == 6, "KartPad donor runtime is not a dylib"
            assert runtime["platform"] == 2, "KartPad donor runtime is not iPhoneOS"
            assert runtime["id"] == "@rpath/KartPadRuntime.framework/KartPadRuntime",                 "KartPad donor runtime install name is wrong"
            for symbol in (
                "__Z11RuntimeMainiPPc",
                "_SDL_GetWindows",
                "_SDL_HideWindow",
                "_SDL_ShowWindow",
                "_SDL_SetMainReady",
                "_SDL_SetiOSEventPump",
                "_SDL_GetError",
            ):
                assert symbol in runtime["definedSymbols"], f"Donor export missing: {symbol}"

            resources = identity.get("runtime_resources")
            assert isinstance(resources, dict) and resources,                 "KartPad donor runtime resources missing from identity"
            for relative, expected_hash in resources.items():
                packaged = app + relative
                assert packaged in z.namelist(),                     f"KartPad runtime resource missing: {relative}"
                assert hashlib.sha256(z.read(packaged)).hexdigest() == expected_hash,                     f"KartPad runtime resource hash mismatch: {relative}"
            for required in (
                "dsp_coef.bin",
                "initial_pipeline_cache.db",
                "wii_bootstrap/shared2/wc24/misc.bin",
            ):
                assert required in resources,                     f"KartPad required runtime resource missing from identity: {required}"
        else:
            assert runtime_binary_path not in z.namelist(),                 "Unexpected donor runtime in source-built KartPad candidate"

        packaged_identity = app + "KartPad-native-identity.json"
        assert packaged_identity in z.namelist(), "KartPad identity missing from app"
        assert json.loads(z.read(packaged_identity)) == identity

        # Neither Runner nor unrelated frameworks may have a startup dyld edge
        # to KartPad. Both KartPad images are host-owned and loaded lazily.
        for name in z.namelist():
            if name in (binary_path, runtime_binary_path) or z.getinfo(name).is_dir():
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
                "KartPadCore" in dependency["path"] or
                "KartPadRuntime" in dependency["path"]
                for dependency in image["dependencies"]
            ), name

        assert not any("KartPad.app/" in name for name in z.namelist()),             "Standalone KartPad app must never be nested"

    return {
        "build": str(build_number),
        "coreHostCommit": core_host,
        "coreSha256": identity["sha256"],
        "mode": identity.get("mode", "source-built"),
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
