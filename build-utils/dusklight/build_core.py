#!/usr/bin/env python3
"""Materialize reviewed full sources and validate the embedded Dusklight framework.

No patch chain: every changed upstream file is a canonical, reviewable source
file in native/dusklight. The unmodified inputs are pinned and hash checked.
"""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[2]
NATIVE = ROOT / "native/dusklight"
PINS = json.loads((ROOT / "build-utils/dusklight/source.json").read_text())


def sha(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def run(*args):
    return subprocess.check_output(args, text=True).strip()


def prepare(source, sdl):
    assert run("git", "-C", str(source), "rev-parse", "HEAD") == PINS["commit"]
    assert run("git", "-C", str(sdl), "rev-parse", "HEAD") == PINS["sdl"]["commit"]
    for module in ("aurora", "borealis"):
        assert run("git", "-C", str(source / "extern" / module), "rev-parse", "HEAD") == PINS["submodules"][module]
    manifest = json.loads((NATIVE / "upstream-manifest.json").read_text())
    for name, expected in manifest.items():
        group, relative = name.split("/", 1)
        target = (source if group == "upstream" else sdl) / relative
        assert sha(target) == expected, f"Unreviewed upstream input: {name}"
    identities = {}
    for name in manifest:
        group, relative = name.split("/", 1)
        target = (source if group == "upstream" else sdl) / relative
        shutil.copy2(NATIVE / name, target)
        identities[name] = sha(target)
    destination = source / "neostation"
    shutil.copytree(NATIVE / "core", destination, dirs_exist_ok=True)
    abi = ROOT / "packages/dusklight_internal_bridge/ios/Classes/DusklightCoreABI.h"
    shutil.copy2(abi, destination / abi.name)
    for item in destination.iterdir():
        if item.is_file():
            identities["neostation/" + item.name] = sha(item)
    (source / "neostation-sources.json").write_text(json.dumps(identities, indent=2) + "\n")
    print(f"Materialized {len(identities)} canonical files; all pristine input hashes verified.")


def package(source, framework, destination):
    assert framework.is_dir(), framework
    destination.mkdir(parents=True, exist_ok=True)
    target = destination / "DusklightCore.framework"
    if target.exists():
        shutil.rmtree(target)
    shutil.copytree(framework, target, symlinks=True)
    binary = target / "DusklightCore"
    assert "arm64" in run("lipo", "-archs", str(binary))
    info = plistlib.loads((target / "Info.plist").read_bytes())
    assert info["CFBundleExecutable"] == "DusklightCore", info
    assert info["CFBundlePackageType"] == "FMWK", info
    # This revision constructs RmlUi documents in C++; its bundled files are
    # RCSS stylesheets, fonts and images, not standalone .rml documents.
    resource_root = source / "res"
    resources = sorted(p for p in resource_root.rglob("*") if p.is_file())
    assert resources, "Empty upstream resource tree"
    for required in ("rml/global.rcss", "rml/touch_controls.rcss", "Inter-Regular.ttf", "icon.png"):
        assert (resource_root / required).is_file(), f"Missing upstream resource: {required}"
    for item in resources:
        relative = item.relative_to(source)
        assert (target / relative).is_file(), f"Missing native resource: {relative}"
        assert sha(target / relative) == sha(item), f"Changed native resource: {relative}"
    exports = run("nm", "-gjU", str(binary)).splitlines()
    assert "_NeoDusklight_GetAPI" in exports
    assert not any(n in exports for n in ("_main", "_SDL_main", "_SDL_RunApp", "_aurora_main"))
    assert not any(n.startswith("_SDL_") for n in exports), "Public SDL symbols leak from Core"
    symbols = run("nm", "-j", str(binary)).splitlines()
    objc_classes = sorted(n for n in symbols if "OBJC_CLASS_$_" in n and not n.startswith("U "))
    assert not any("OBJC_CLASS_$_SDL" in n for n in objc_classes), "SDL Objective-C class collision"
    loads = run("otool", "-L", str(binary))
    assert "@rpath/DusklightCore.framework/DusklightCore" in loads, loads
    assert "/opt/homebrew" not in loads and "/Users/" not in loads, loads
    identity = {
        "host_commit": run("git", "-C", str(ROOT), "rev-parse", "HEAD"),
        "source_commit": PINS["commit"],
        "submodules": PINS["submodules"],
        "sdl_commit": PINS["sdl"]["commit"],
        "abi_version": 4,
        "sha256": sha(binary),
        "resources": {str(p.relative_to(target)): sha(p) for p in sorted((target / "res").rglob("*")) if p.is_file()},
        "canonical_sources": json.loads((source / "neostation-sources.json").read_text()),
        "objc_classes": objc_classes,
        "session_policy": "host_frame_loop_terminal_shutdown",
    }
    (destination / "identity.json").write_text(json.dumps(identity, indent=2) + "\n")
    # Preserve source notices alongside the generated framework.
    notices = destination / "licenses"
    notices.mkdir(exist_ok=True)
    for name, directory in (("dusklight", source), ("aurora", source / "extern/aurora"), ("borealis", source / "extern/borealis")):
        for item in directory.glob("*LICENSE*"):
            if item.is_file(): shutil.copy2(item, notices / f"{name}-{item.name}")
    print(f"Validated arm64 framework, private SDL classes, ABI v4 and {len(identity['resources'])} resources.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    prep = sub.add_parser("prepare")
    prep.add_argument("source", type=Path)
    prep.add_argument("sdl", type=Path)
    pack = sub.add_parser("package")
    pack.add_argument("source", type=Path)
    pack.add_argument("framework", type=Path)
    pack.add_argument("destination", type=Path)
    args = parser.parse_args()
    if args.command == "prepare": prepare(args.source, args.sdl)
    else: package(args.source, args.framework, args.destination)
