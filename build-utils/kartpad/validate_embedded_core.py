#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PINS = json.loads((ROOT / "build-utils/kartpad/source.json").read_text())
OFFICIAL_IPA_SHA256 = "1474809c8e14447c159c30902aaf66b022db89d28a3181d69acfac3467508f58"


def fail(message: str) -> None:
    raise SystemExit(f"ERROR: {message}")


def output(*args: str) -> str:
    return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT)


def validate_common(framework: Path, identity: dict) -> tuple[Path, str]:
    binary = framework / "KartPadCore"
    if not binary.is_file():
        fail("missing KartPadCore framework")
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
        fail("incomplete RMCP01 translation identity")
    if identity.get("architectures") != ["arm64"]:
        fail("KartPadCore architecture identity is not arm64-only")

    exports = output("nm", "-gU", str(binary))
    if "_NeoKartPad_GetAPI" not in exports.split():
        fail("KartPadCore ABI export is missing")
    deps = output("otool", "-L", str(binary))
    if "/opt/homebrew" in deps or "/usr/local" in deps:
        fail("KartPadCore links a host-only dependency")
    return binary, digest


def validate_donor(framework: Path, identity: dict) -> dict:
    if identity.get("official_ipa_sha256") != OFFICIAL_IPA_SHA256:
        fail("unexpected official KartPad donor IPA")
    runtime = framework.parent / "KartPadRuntime.framework" / "KartPadRuntime"
    if not runtime.is_file():
        fail("KartPad donor runtime framework is missing")
    runtime_digest = hashlib.sha256(runtime.read_bytes()).hexdigest()
    if identity.get("runtime_sha256") != runtime_digest:
        fail("KartPad donor runtime hash mismatch")
    header = output("otool", "-hv", str(runtime))
    if "DYLIB" not in header or "EXECUTE" in header:
        fail("KartPad donor runtime is not MH_DYLIB")
    build = output("xcrun", "vtool", "-show-build", str(runtime))
    if "platform IOS" not in build:
        fail("KartPad donor runtime is not iphoneos")
    install_name = output("otool", "-D", str(runtime))
    if "@rpath/KartPadRuntime.framework/KartPadRuntime" not in install_name:
        fail("KartPad donor runtime install name is wrong")
    exports = output("nm", "-gU", str(runtime))
    for symbol in (
        "__Z11RuntimeMainiPPc",
        "_SDL_GetWindows",
        "_SDL_HideWindow",
        "_SDL_ShowWindow",
    ):
        if symbol not in exports:
            fail(f"KartPad donor runtime export missing: {symbol}")
    core_deps = output("otool", "-L", str(framework / "KartPadCore"))
    if "KartPadRuntime.framework" in core_deps:
        fail("KartPadCore must lazy-load the donor runtime")
    return {
        "mode": "official-ipa-donor",
        "runtimeSha256": runtime_digest,
    }


def main() -> None:
    if len(sys.argv) != 3:
        fail("usage: validate_embedded_core.py FRAMEWORK IDENTITY")
    framework = Path(sys.argv[1])
    identity_path = Path(sys.argv[2])
    if not identity_path.is_file():
        fail("missing KartPad identity")
    identity = json.loads(identity_path.read_text())
    _, digest = validate_common(framework, identity)
    extra = {}
    mode = identity.get("mode", "source-built")
    if mode == "official-ipa-donor":
        extra = validate_donor(framework, identity)
    elif mode not in ("source-built", None):
        fail(f"unsupported KartPad artifact mode: {mode}")
    print(json.dumps({
        "sha256": digest,
        "abi": identity["abi_version"],
        "runtime": identity["runtime_identity"],
        "translatedFunctions": identity["translated_function_count"],
        **extra,
    }, indent=2))


if __name__ == "__main__":
    main()
