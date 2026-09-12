#!/usr/bin/env python3
import importlib.util
from pathlib import Path
import sys


root = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location(
    "pipeline_scheduler", root / "build-utils/benchmark_rpcs3_pipeline_scheduler.py"
)
module = importlib.util.module_from_spec(spec)
assert spec.loader
sys.modules[spec.name] = module
spec.loader.exec_module(module)

before, after = module.benchmark()
assert after["mean_queue_ms"] < before["mean_queue_ms"] * 0.35
assert after["p95_queue_ms"] < before["p95_queue_ms"]
assert after["maximum_queue_ms"] < before["maximum_queue_ms"]
assert after["makespan_ms"] <= before["makespan_ms"]
print("RPCS3 Build 258 pipeline scheduler microbenchmark contract: OK")
