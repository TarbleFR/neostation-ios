#!/usr/bin/env python3
"""Remove external iOS launchers from GameCube/Wii system definitions."""

from __future__ import annotations

import json
from pathlib import Path

root = Path(__file__).resolve().parents[1]
for folder in ("gc", "wii"):
    source = root / "assets" / "systems" / f"{folder}.json"
    payload = json.loads(source.read_text(encoding="utf-8"))
    original = payload.get("emulators", [])
    cleaned = []
    removed = []
    for emulator in original:
        platforms = emulator.get("platforms", {})
        if "ios" in platforms:
            removed.append(emulator.get("unique_id", emulator.get("name", "unknown")))
            continue
        cleaned.append(emulator)
    payload["emulators"] = cleaned
    payload["system"]["ios_native_engine"] = "dolphin_internal"
    source.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    print(f"{folder}: removed external iOS launchers: {', '.join(removed) or 'none'}")

for source in (root / "assets" / "systems" / "gc.json", root / "assets" / "systems" / "wii.json"):
    text = source.read_text(encoding="utf-8")
    if '"ios"' in text or '"url_scheme"' in text:
        raise SystemExit(f"External iOS launcher remains in {source}")

print("GameCube and Wii are internal-only on iOS.")
