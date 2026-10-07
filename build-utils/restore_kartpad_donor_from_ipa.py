#!/usr/bin/env python3
"""Restore the pinned KartPadCore-3934ac9d donor artifact from a packaged IPA.

The KartPadCore-3934ac9d artifact (run 36322395443) was purged with every
workflow run before 7 October 2026 11:51 UTC, and the official KartPad
v0.5.1-experimental.1 IPA it was converted from is no longer published, so the
donor can no longer be rebuilt. The published NeoStation 0.0.1 IPA (the Build
350 package, SHA-256 e1017b96...) embeds that exact artifact byte for byte:
KartPadCore.framework, KartPadRuntime.framework, the runtime resources copied
to the app root and the artifact identity as KartPad-native-identity.json.

This restores the artifact layout consumed by embed_core.py and the KartPad
harnesses, and refuses any byte that does not match the pinned identity.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import stat
import zipfile
from pathlib import Path, PurePosixPath

PUBLISHED_IPA_SHA256 = "e1017b96842ec970be3ed0cd981083ee945d069cf76e689a4ca3c81339299b46"
HOST_COMMIT = "3934ac9d333247d5374b9fb7d71f8ef49bbcd79e"
CORE_SHA256 = "995e876715b98be8fde897a88f7b93fb2357b6c47826d99c1df0a0b05a98930c"
RUNTIME_SHA256 = "ad5c00a0a508bbfcc0dc3eb1ee04a17f10919cde0b5cccd90d1d9e6a31c39eb0"


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def demand(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit("ERROR: " + message)


def restore(ipa: Path, output: Path, *, ipa_sha256: str = PUBLISHED_IPA_SHA256,
            host_commit: str = HOST_COMMIT, core_sha256: str = CORE_SHA256,
            runtime_sha256: str = RUNTIME_SHA256) -> dict:
    digest = hashlib.sha256()
    with ipa.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    demand(digest.hexdigest() == ipa_sha256, f"unexpected source IPA {digest.hexdigest()}")
    demand(not output.exists() or not any(output.iterdir()), f"output is not empty: {output}")

    with zipfile.ZipFile(ipa) as archive:
        names = archive.namelist()
        apps = sorted({name.split("/")[1] for name in names
                       if name.startswith("Payload/") and len(name.split("/")) > 2
                       and name.split("/")[1].endswith(".app")})
        demand(len(apps) == 1, f"expected one application, found {apps}")
        app = "Payload/" + apps[0] + "/"
        identity = json.loads(archive.read(app + "KartPad-native-identity.json"))
        demand(identity.get("host_commit") == host_commit, "donor host commit mismatch")
        demand(identity.get("mode") == "official-ipa-donor", "donor mode mismatch")
        demand(identity.get("sha256") == core_sha256, "donor Core identity mismatch")
        demand(identity.get("runtime_sha256") == runtime_sha256, "donor runtime identity mismatch")
        resources = identity.get("runtime_resources")
        demand(isinstance(resources, dict) and bool(resources), "donor runtime resources missing")

        def extract(member: str, destination: Path) -> bytes:
            info = archive.getinfo(member)
            data = archive.read(info)
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(data)
            if (info.external_attr >> 16) & 0o111:
                destination.chmod(destination.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
            return data

        output.mkdir(parents=True, exist_ok=True)
        copied = []
        for framework in ("KartPadCore.framework", "KartPadRuntime.framework"):
            prefix = app + "Frameworks/" + framework + "/"
            members = [name for name in names if name.startswith(prefix) and not name.endswith("/")]
            demand(bool(members), f"{framework} missing from IPA")
            for member in members:
                relative = PurePosixPath(member[len(prefix):])
                demand(".." not in relative.parts, f"unsafe path {member}")
                extract(member, output / framework / Path(*relative.parts))
                copied.append(framework + "/" + relative.as_posix())
        for name, expected in (("KartPadCore.framework/KartPadCore", core_sha256),
                               ("KartPadRuntime.framework/KartPadRuntime", runtime_sha256)):
            binary = output / name
            demand(binary.is_file() and sha256(binary.read_bytes()) == expected, f"{name} hash mismatch")
            binary.chmod(0o755)
        for relative, expected in sorted(resources.items()):
            parts = PurePosixPath(relative).parts
            demand(".." not in parts and not PurePosixPath(relative).is_absolute(), f"unsafe resource {relative}")
            data = extract(app + relative, output / "runtime-resources" / Path(*parts))
            demand(sha256(data) == expected, f"runtime resource hash mismatch: {relative}")
        (output / "identity.json").write_bytes(archive.read(app + "KartPad-native-identity.json"))

    return {
        "sourceIpaSha256": ipa_sha256,
        "host_commit": identity["host_commit"],
        "sha256": identity["sha256"],
        "runtime_sha256": identity["runtime_sha256"],
        "frameworkFiles": len(copied),
        "runtimeResources": len(resources),
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("ipa", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    print(json.dumps(restore(args.ipa, args.output), indent=2))


if __name__ == "__main__":
    main()
