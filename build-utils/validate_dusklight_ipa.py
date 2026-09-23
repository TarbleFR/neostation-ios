#!/usr/bin/env python3
"""Verify the actual packaged native port, its resources and lazy load boundary."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import sys
import zipfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "packages/dolphin_internal_bridge/ci"))
from verify_ipa import macho  # noqa: E402


def validate(ipa, identity_path, core_host, build_number):
    identity = json.loads(identity_path.read_text())
    pins = json.loads((ROOT / "build-utils/dusklight/source.json").read_text())
    assert identity["host_commit"] == core_host, "Wrong native Core build"
    assert identity["source_commit"] == pins["commit"], "Wrong Dusklight revision"
    assert identity["sdl_commit"] == pins["sdl"]["commit"], "Wrong SDL revision"
    assert identity["abi_version"] == 3
    assert identity["session_policy"] == "host_frame_loop_suspend_resume_same_disc"
    with zipfile.ZipFile(ipa) as z:
        apps = [n for n in z.namelist() if n.startswith("Payload/") and n.endswith(".app/Info.plist") and n.count("/") == 2]
        assert len(apps) == 1
        app = apps[0].removesuffix("Info.plist")
        info = plistlib.loads(z.read(apps[0]))
        assert str(info["CFBundleVersion"]) == build_number
        framework = app + "Frameworks/DusklightCore.framework/"
        binary = z.read(framework + "DusklightCore")
        assert hashlib.sha256(binary).hexdigest() == identity["sha256"], "Native Core bytes changed"
        core_info = plistlib.loads(z.read(framework + "Info.plist"))
        assert core_info["CFBundlePackageType"] == "FMWK"
        assert core_info["CFBundleIdentifier"] == "fr.neostation.DusklightCore"
        core = macho(binary)
        assert core["fileType"] == 6 and core["platform"] == 2, "Not an iPhoneOS dylib"
        assert core["id"] == "@rpath/DusklightCore.framework/DusklightCore"
        assert "_NeoDusklight_GetAPI" in core["definedSymbols"]
        for relative, digest in identity["resources"].items():
            assert hashlib.sha256(z.read(framework + relative)).hexdigest() == digest, relative
        # Verify the host and every other native library remain passive: nothing
        # may load Dusklight via a dyld load command at application startup.
        for name in z.namelist():
            if name == framework + "DusklightCore" or z.getinfo(name).is_dir():
                continue
            with z.open(name) as stream:
                magic = stream.read(4)
            if magic not in (b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf"):
                continue
            image = macho(z.read(name))
            assert not any("DusklightCore" in d["path"] for d in image["dependencies"]), name
        art = app + "Frameworks/App.framework/flutter_assets/assets/images/ports-gaming.webp"
        assert art in z.namelist(), "Ports artwork missing"
        assert not any("Dusklight.app/" in name for name in z.namelist()), "Standalone app was nested"
    return {"build": build_number, "core_host_commit": core_host,
            "core_sha256": identity["sha256"], "resources": len(identity["resources"]),
            "passive_load": True, "device_gameplay_tested": False}


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("ipa", type=Path)
    parser.add_argument("--identity", type=Path, required=True)
    parser.add_argument("--core-host", required=True)
    parser.add_argument("--build-number", required=True)
    args = parser.parse_args()
    print(json.dumps(validate(args.ipa, args.identity, args.core_host, args.build_number), indent=2))
