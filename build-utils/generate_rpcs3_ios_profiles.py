#!/usr/bin/env python3
"""Build NeoStation's offline RPCS3 profile database from the official API.

The emitted JSON deliberately keeps RPCS3's original per-title YAML intact
apart from two iOS safety rules.  Classification metadata is advisory and is
ignored by the native core; it lets NeoStation explain the selected profile in
the UI without hard-coding thousands of serials in Dart.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import urllib.request


SOURCE_URL = "https://api.rpcs3.net/config/?api=v1"
SERIAL = re.compile(r"^[A-Z0-9]{9,16}$")
MINIMUM_COMPLETE_DATABASE_SIZE = 1000


def sanitise(config: str) -> tuple[str, list[str]]:
    """Remove settings that are invalid or unsafe on the iOS Vulkan port."""
    output: list[str] = []
    removed: list[str] = []
    for line in config.splitlines():
        if ":" not in line:
            output.append(line)
            continue
        name, value = line.split(":", 1)
        key = name.strip().removeprefix("- ")
        scalar = value.strip()
        if key == "Renderer" and scalar == "OpenGL":
            removed.append("Renderer: OpenGL")
            continue
        if key == "Frame limit" and scalar in {"Off", "Infinite"}:
            removed.append(f"Frame limit: {scalar}")
            continue
        output.append(line)
    return "\n".join(output).strip() + "\n", removed


def classify(config: str) -> str:
    """Assign one conservative, explainable family from the actual settings."""
    compatibility = (
        "Strict Rendering Mode",
        "Write Color Buffers",
        "Read Color Buffers",
        "Accurate RSX reservation access",
        "RSX FIFO Fetch Accuracy",
        "Driver Wake-Up Delay",
        "Accurate Cache Line Stores",
    )
    shader = (
        "Shader Precision",
        "Disable Vertex Cache",
        "Asynchronous Texture Streaming",
    )
    spu = (
        "SPU Block Size",
        "SPU XFloat Accuracy",
        "Max SPURS Threads",
        "Preferred SPU Threads",
    )
    gpu = (
        "Multithreaded RSX",
        "ZCULL",
        "Resolution Scale",
        "VBlank Frequency",
    )
    if any(token in config for token in compatibility):
        return "compatibility"
    if sum(token in config for token in shader) >= 2:
        return "shader-heavy"
    if any(token in config for token in spu):
        return "spu-heavy"
    if any(token in config for token in gpu):
        return "gpu-bound"
    return "balanced"


def build(source: dict) -> dict:
    if source.get("return_code") != 0 or not isinstance(source.get("games"), dict):
        raise ValueError("RPCS3 configuration response is not successful")
    if len(source["games"]) < MINIMUM_COMPLETE_DATABASE_SIZE:
        raise ValueError("RPCS3 configuration response is unexpectedly small")

    games: dict[str, dict[str, str]] = {}
    removals: dict[str, int] = {}
    for raw_serial, record in source["games"].items():
        serial = str(raw_serial).strip().upper()
        if not SERIAL.fullmatch(serial) or not isinstance(record, dict):
            continue
        raw_config = record.get("config")
        if not isinstance(raw_config, str) or not raw_config.strip():
            continue
        config, removed = sanitise(raw_config)
        if not any(":" in line and line.split(":", 1)[1].strip() for line in config.splitlines()):
            continue
        for item in removed:
            removals[item] = removals.get(item, 0) + 1
        games[serial] = {
            "config": config,
            "family": classify(config),
            "source": "rpcs3",
        }

    if len(games) < MINIMUM_COMPLETE_DATABASE_SIZE:
        raise ValueError("Too few usable RPCS3 title profiles after validation")
    return {
        "schema": 1,
        "return_code": 0,
        "source_url": SOURCE_URL,
        "policy": {
            "renderer": "Vulkan via MoltenVK; desktop OpenGL overrides removed",
            "frame_limit": "handheld-safe global pacing; Off/Infinite overrides removed",
            "user_priority": "global < recommended < explicit user override",
        },
        "sanitised": removals,
        "games": dict(sorted(games.items())),
    }


def read_source(path: Path | None) -> dict:
    if path is not None:
        return json.loads(path.read_text(encoding="utf-8"))
    request = urllib.request.Request(
        SOURCE_URL,
        headers={"Accept": "application/json", "User-Agent": "NeoStation-iOS/ProfileBuilder"},
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", type=Path, help="Previously downloaded API response")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    payload = build(read_source(args.input))
    args.output.parent.mkdir(parents=True, exist_ok=True)
    temporary = args.output.with_suffix(args.output.suffix + ".part")
    temporary.write_text(
        json.dumps(payload, ensure_ascii=False, separators=(",", ":")) + "\n",
        encoding="utf-8",
    )
    temporary.replace(args.output)
    print(
        f"Wrote {len(payload['games'])} iOS-safe RPCS3 profiles to {args.output} "
        f"({payload['sanitised']})"
    )


if __name__ == "__main__":
    main()
