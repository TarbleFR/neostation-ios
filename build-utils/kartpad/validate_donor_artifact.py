#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
from pathlib import Path

from patch_donor_language_bridge import validate_bridge
from patch_donor_session_bridge import validate as validate_session_bridge

OFFICIAL_IPA_SHA256 = "1474809c8e14447c159c30902aaf66b022db89d28a3181d69acfac3467508f58"


def command(*args: str) -> str:
    return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT)


def validate(root: Path) -> dict:
    identity = json.loads((root / "identity.json").read_text())
    core = root / "KartPadCore.framework" / "KartPadCore"
    runtime = root / "KartPadRuntime.framework" / "KartPadRuntime"
    if not core.is_file() or not runtime.is_file():
        raise SystemExit("ERROR: donor artifact frameworks are incomplete")
    if identity.get("mode") != "official-ipa-donor":
        raise SystemExit("ERROR: donor mode identity is missing")
    if identity.get("official_ipa_sha256") != OFFICIAL_IPA_SHA256:
        raise SystemExit("ERROR: unexpected official KartPad IPA")
    if identity.get("abi_version") != 1:
        raise SystemExit("ERROR: unexpected donor ABI")
    if identity.get("runtime_identity") != "kartpad_rmcp01_full_game_v1":
        raise SystemExit("ERROR: unexpected donor runtime identity")

    core_sha = hashlib.sha256(core.read_bytes()).hexdigest()
    runtime_sha = hashlib.sha256(runtime.read_bytes()).hexdigest()
    if identity.get("sha256") != core_sha:
        raise SystemExit("ERROR: donor Core hash mismatch")
    if identity.get("runtime_sha256") != runtime_sha:
        raise SystemExit("ERROR: donor runtime hash mismatch")

    language_bridge = validate_bridge(runtime.read_bytes())
    session_bridge = validate_session_bridge(runtime.read_bytes())

    resource_root = root / "runtime-resources"
    expected_resources = identity.get("runtime_resources")
    if not isinstance(expected_resources, dict) or not expected_resources:
        raise SystemExit("ERROR: donor runtime resource identity is missing")
    required_resources = {
        "dsp_coef.bin",
        "initial_pipeline_cache.db",
        "wii_bootstrap/shared2/wc24/misc.bin",
    }
    if not required_resources.issubset(expected_resources):
        raise SystemExit("ERROR: donor runtime resource identity is incomplete")
    actual_resources = {}
    for item in sorted(p for p in resource_root.rglob("*") if p.is_file()):
        actual_resources[item.relative_to(resource_root).as_posix()] = hashlib.sha256(
            item.read_bytes()
        ).hexdigest()
    if actual_resources != expected_resources:
        raise SystemExit("ERROR: donor runtime resources do not match identity")

    header = command("otool", "-hv", str(runtime))
    if "DYLIB" not in header or "EXECUTE" in header:
        raise SystemExit("ERROR: converted KartPad runtime is not MH_DYLIB")
    build = command("xcrun", "vtool", "-show-build", str(runtime))
    if "platform IOS" not in build:
        raise SystemExit("ERROR: converted KartPad runtime is not iphoneos")
    install_name = command("otool", "-D", str(runtime))
    if "@rpath/KartPadRuntime.framework/KartPadRuntime" not in install_name:
        raise SystemExit("ERROR: donor runtime install name is wrong")
    exports = command("nm", "-gU", str(runtime))
    for symbol in (
        "__Z11RuntimeMainiPPc",
        "_SDL_GetWindows",
        "_SDL_HideWindow",
        "_SDL_ShowWindow",
        "_SDL_SetMainReady",
        "_SDL_SetiOSEventPump",
        "_SDL_GetError",
    ):
        if symbol not in exports:
            raise SystemExit(f"ERROR: donor runtime export missing: {symbol}")

    core_exports = command("nm", "-gU", str(core))
    if "_NeoKartPad_GetAPI" not in core_exports:
        raise SystemExit("ERROR: donor Core ABI export missing")
    if "_NeoKartPad_PrepareUserGame" not in core_exports:
        raise SystemExit("ERROR: donor Core RVZ preparation export missing")
    core_deps = command("otool", "-L", str(core))
    if "KartPadRuntime.framework" in core_deps:
        raise SystemExit("ERROR: donor Core must lazy-load KartPadRuntime")

    return {
        "mode": identity["mode"],
        "coreSha256": core_sha,
        "runtimeSha256": runtime_sha,
        "officialIpaSha256": identity["official_ipa_sha256"],
        "runtimeResources": len(expected_resources),
        "languageBridge": language_bridge,
        "sessionBridge": session_bridge,
    }


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("root", type=Path)
    args = parser.parse_args()
    print(json.dumps(validate(args.root), indent=2))
