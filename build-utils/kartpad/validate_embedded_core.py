#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PINS = json.loads((ROOT / "build-utils/kartpad/source.json").read_text())


def fail(message: str) -> None:
    raise SystemExit(f"ERROR: {message}")


def main() -> None:
    if len(sys.argv) != 3:
        fail("usage: validate_embedded_core.py FRAMEWORK IDENTITY")
    framework = Path(sys.argv[1])
    identity_path = Path(sys.argv[2])
    binary = framework / "KartPadCore"
    if not binary.is_file() or not identity_path.is_file():
        fail("missing KartPadCore framework or identity")

    identity = json.loads(identity_path.read_text())
    digest = hashlib.sha256(binary.read_bytes()).hexdigest()
    if identity.get("sha256") != digest:
        fail("KartPadCore hash does not match identity")
    if identity.get("upstream_commit") != PINS["releaseTagCommit"]:
        fail("unexpected KartPad upstream source")
    if identity.get("ios_runtime_commit") != PINS["iosRuntimeCommit"]:
        fail("unexpected KartPad iOS runtime")
    if identity.get("abi_version") != PINS["neoStationAbi"]:
        fail("unexpected KartPad ABI version")
    if identity.get("runtime_identity") != PINS["runtimeIdentity"]:
        fail("unexpected KartPad runtime identity")
    if identity.get("translated_function_count") != PINS["discProfile"]["expectedTranslatedFunctions"]:
        fail("incomplete RMCP01 translation graph")
    if identity.get("architectures") != ["arm64"]:
        fail("KartPadCore architecture identity is not arm64-only")

    exports = subprocess.check_output(["nm", "-gU", str(binary)], text=True)
    symbols = set(exports.split())
    if "_NeoKartPad_GetAPI" not in symbols:
        fail("KartPadCore ABI export is missing")
    if "_main" in symbols:
        fail("KartPadCore still exports a standalone main entry point")

    undefined = subprocess.check_output(["nm", "-u", str(binary)], text=True)
    if "_UIApplicationMain" in undefined.split():
        fail("KartPadCore still depends on UIApplicationMain")

    install_name = subprocess.check_output(["otool", "-D", str(binary)], text=True)
    if "@rpath/KartPadCore.framework/KartPadCore" not in install_name:
        fail("KartPadCore install name is not @rpath-relative")

    deps = subprocess.check_output(["otool", "-L", str(binary)], text=True)
    if "/opt/homebrew" in deps or "/usr/local" in deps:
        fail("KartPadCore links a host-only dependency")

    print(json.dumps({
        "sha256": digest,
        "abi": identity["abi_version"],
        "runtime": identity["runtime_identity"],
        "translatedFunctions": identity["translated_function_count"],
    }, indent=2))


if __name__ == "__main__":
    main()
