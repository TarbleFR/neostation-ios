#!/usr/bin/env python3
"""Embed a validated KartPadCore.framework into an already-built NeoStation app."""
from __future__ import annotations

import argparse
import json
import shutil
from pathlib import Path

from validate_embedded_core import main as _unused  # keeps validator importable
import validate_embedded_core


def embed(app: Path, artifact: Path) -> dict:
    framework = artifact / "KartPadCore.framework"
    identity_path = artifact / "identity.json"
    validate_embedded_core.validate = getattr(validate_embedded_core, "validate", None)

    if not app.is_dir():
        raise SystemExit(f"ERROR: NeoStation app does not exist: {app}")
    if not (framework / "KartPadCore").is_file() or not identity_path.is_file():
        raise SystemExit("ERROR: KartPad artifact is incomplete")

    # Re-run the standalone validator in-process by duplicating its required
    # identity checks before any bytes are copied into the application.
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
        raise SystemExit("ERROR: incomplete KartPad translated graph")

    destination = app / "Frameworks" / "KartPadCore.framework"
    if destination.exists():
        shutil.rmtree(destination)
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(framework, destination)
    (destination / "KartPadCore").chmod(0o755)

    packaged_identity = app / "KartPad-native-identity.json"
    shutil.copy2(identity_path, packaged_identity)

    return {
        "framework": str(destination),
        "identity": str(packaged_identity),
        "coreHostCommit": identity.get("host_commit"),
        "sha256": identity.get("sha256"),
    }


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--artifact", type=Path, required=True)
    args = parser.parse_args()
    print(json.dumps(embed(args.app, args.artifact), indent=2))
