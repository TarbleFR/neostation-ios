#!/usr/bin/env python3
"""Embed a validated KartPad runtime into an already-built NeoStation app."""
from __future__ import annotations

import argparse
import hashlib
import json
import shutil
from pathlib import Path

OFFICIAL_IPA_SHA256 = "1474809c8e14447c159c30902aaf66b022db89d28a3181d69acfac3467508f58"


def embed(app: Path, artifact: Path) -> dict:
    framework = artifact / "KartPadCore.framework"
    identity_path = artifact / "identity.json"
    if not app.is_dir():
        raise SystemExit(f"ERROR: NeoStation app does not exist: {app}")
    if not (framework / "KartPadCore").is_file() or not identity_path.is_file():
        raise SystemExit("ERROR: KartPad artifact is incomplete")

    identity = json.loads(identity_path.read_text())
    pins = json.loads((Path(__file__).resolve().parent / "source.json").read_text())
    if identity.get("upstream_commit") != pins["releaseTagCommit"]:
        raise SystemExit("ERROR: KartPad upstream identity mismatch")
    if identity.get("ios_runtime_commit") != pins["iosRuntimeCommit"]:
        raise SystemExit("ERROR: KartPad iOS runtime identity mismatch")
    if identity.get("abi_version") != pins["neoStationAbi"]:
        raise SystemExit("ERROR: KartPad ABI identity mismatch")
    if identity.get("runtime_identity") != pins["runtimeIdentity"]:
        raise SystemExit("ERROR: KartPad runtime profile mismatch")
    if identity.get("translated_function_count") != pins["discProfile"]["expectedTranslatedFunctions"]:
        raise SystemExit("ERROR: incomplete KartPad translated runtime identity")
    core_bytes = (framework / "KartPadCore").read_bytes()
    if hashlib.sha256(core_bytes).hexdigest() != identity.get("sha256"):
        raise SystemExit("ERROR: KartPadCore hash does not match identity")

    frameworks = app / "Frameworks"
    frameworks.mkdir(parents=True, exist_ok=True)

    runtime_destination = frameworks / "KartPadRuntime.framework"
    if runtime_destination.exists():
        shutil.rmtree(runtime_destination)

    mode = identity.get("mode", "source-built")
    if mode == "official-ipa-donor":
        if identity.get("official_ipa_sha256") != OFFICIAL_IPA_SHA256:
            raise SystemExit("ERROR: official KartPad donor IPA identity mismatch")
        runtime = artifact / "KartPadRuntime.framework"
        runtime_binary = runtime / "KartPadRuntime"
        if not runtime_binary.is_file():
            raise SystemExit("ERROR: KartPad donor runtime is missing")
        if hashlib.sha256(runtime_binary.read_bytes()).hexdigest() != identity.get("runtime_sha256"):
            raise SystemExit("ERROR: KartPad donor runtime hash mismatch")
        shutil.copytree(runtime, runtime_destination)
        (runtime_destination / "KartPadRuntime").chmod(0o755)
    elif mode not in ("source-built", None):
        raise SystemExit(f"ERROR: unsupported KartPad mode: {mode}")

    destination = frameworks / "KartPadCore.framework"
    if destination.exists():
        shutil.rmtree(destination)
    shutil.copytree(framework, destination)
    (destination / "KartPadCore").chmod(0o755)

    packaged_identity = app / "KartPad-native-identity.json"
    shutil.copy2(identity_path, packaged_identity)

    return {
        "framework": str(destination),
        "runtimeFramework": str(runtime_destination) if runtime_destination.exists() else None,
        "identity": str(packaged_identity),
        "coreHostCommit": identity.get("host_commit"),
        "mode": mode,
        "sha256": identity.get("sha256"),
    }


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--artifact", type=Path, required=True)
    args = parser.parse_args()
    print(json.dumps(embed(args.app, args.artifact), indent=2))
