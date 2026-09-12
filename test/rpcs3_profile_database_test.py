#!/usr/bin/env python3
"""Fast contract checks for the generated offline RPCS3 profile database."""

import json
from pathlib import Path


root = Path(__file__).resolve().parents[1]
payload = json.loads((root / "assets/data/rpcs3_ios_profiles.json").read_text())
games = payload["games"]

assert payload["return_code"] == 0
assert payload["source_url"] == "https://api.rpcs3.net/config/?api=v1"
assert len(games) >= 2000
assert set(record["family"] for record in games.values()) <= {
    "balanced", "compatibility", "gpu-bound", "shader-heavy", "spu-heavy"
}
all_config = "\n".join(record["config"] for record in games.values())
assert "Renderer: OpenGL" not in all_config
assert "Frame limit: Infinite" not in all_config
assert "Frame limit: Off" not in all_config
for serial in ("BCUS98111", "BCES00510", "BCAS25003"):
    config = games[serial]["config"]
    assert "Shader Precision: Ultra" in config
    assert "Write Color Buffers: true" in config
    assert "SPU Block Size: Mega" in config

service = (root / "lib/services/rpcs3_game_profile_service.dart").read_text()
database = (root / "lib/services/rpcs3_game_profile_database.dart").read_text()
assert "Rpcs3GameProfileDatabase.entryFor" in service
assert "Rpcs3ConfigAdapter.mergeScalarOverrides" in service
assert "user overrides remain last" in service
assert "Duration(days: 7)" in database
assert ".part" in database and "rename(file.path)" in database
print(f"RPCS3 profile database contract: OK ({len(games)} profiles)")
