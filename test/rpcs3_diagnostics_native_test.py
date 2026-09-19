#!/usr/bin/env python3
"""Compile and exercise the actual Foundation logger on the macOS CI runner.

Only the Documents lookup is redirected to an owned temporary directory.
This checks behavior, not an on-device performance improvement.
"""
import pathlib
import subprocess
import sys
import tempfile

root = pathlib.Path(__file__).resolve().parents[1]
header = (root / "packages/rpcs3_internal_bridge/ios/Classes/Rpcs3Diagnostics.h").read_text()
if "static inline" in header:
    raise AssertionError("RPCS3 diagnostics must have one implementation, not per-TU inline state")

if sys.platform != "darwin":
    print("RPCS3 diagnostics source contract: OK; native multi-TU test SKIP (requires macOS Foundation)")
    sys.exit(0)

with tempfile.TemporaryDirectory(prefix="rpcs3-log-test-") as directory:
    binary = pathlib.Path(directory) / "diagnostics-test"
    subprocess.run([
        "xcrun", "clang++", "-fobjc-arc", "-fblocks", "-std=c++20",
        "-DRPCS3_DIAGNOSTICS_TESTING=1",
        "-framework", "Foundation", "-I", str(root),
        str(root / "packages/rpcs3_internal_bridge/ios/Classes/Rpcs3Diagnostics.mm"),
        str(root / "test/native/rpcs3_diagnostics_test.mm"),
        str(root / "test/native/rpcs3_diagnostics_core_writer.mm"),
        str(root / "test/native/rpcs3_diagnostics_jit_writer.mm"),
        "-o", str(binary),
    ], check=True)
    subprocess.run([str(binary), directory], check=True, timeout=60)
print("RPCS3 native diagnostics concurrency/rotation/reopen tests: OK")
