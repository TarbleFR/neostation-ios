#!/usr/bin/env python3
import importlib.util
import json
from pathlib import Path
import tempfile


root = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location(
    "telemetry", root / "build-utils/compare_rpcs3_telemetry.py"
)
module = importlib.util.module_from_spec(spec)
assert spec.loader
spec.loader.exec_module(module)


def capture(path: Path, fps: list[float], boot: float) -> None:
    rows = [
        {"timestamp": 100.0, "stage": "game_boot_begin", "message": "BCUS98111"},
        {"timestamp": 100.0 + boot, "stage": "game_boot_return", "message": "BCUS98111 status=0"},
    ]
    for index, value in enumerate(fps):
        rows.append({
            "timestamp": 101.0 + boot + index,
            "stage": "performance_sample",
            "message": (
                f"title=BCUS98111 valid=0xf fps={value:.2f} cpu=70.0 rsx=40.0 "
                "memory=1073741824/8589934592 available=2147483648 thermal=0"
            ),
        })
    path.write_text("".join(json.dumps(row) + "\n" for row in rows))


with tempfile.TemporaryDirectory() as directory:
    before_path = Path(directory) / "before.log"
    after_path = Path(directory) / "after.log"
    capture(before_path, [20, 22, 21, 10, 23, 20], 12.0)
    capture(after_path, [27, 28, 29, 25, 30, 28], 8.0)
    before = module.measure(before_path, "bcus98111")
    after = module.measure(after_path, "BCUS98111")
    report = module.comparison(before, after)
    assert before["minimum_fps"] == 10
    assert after["average_fps"] > before["average_fps"]
    assert after["boot_seconds"] == 8
    assert "| Average FPS |" in report and "| Boot time (s) |" in report
print("RPCS3 real-device telemetry comparison contract: OK")
