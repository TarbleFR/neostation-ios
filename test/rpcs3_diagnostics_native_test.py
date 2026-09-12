#!/usr/bin/env python3
"""Compile and exercise the actual Foundation logger on the macOS CI runner.

Only the Documents lookup is redirected to an owned temporary directory.
This checks behavior, not an on-device performance improvement.
"""
import pathlib
import subprocess
import sys
import tempfile

if sys.platform != "darwin":
    print("RPCS3 native diagnostics test: SKIP (requires macOS Foundation)")
    sys.exit(0)

root = pathlib.Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="rpcs3-log-test-") as directory:
    binary = pathlib.Path(directory) / "diagnostics-test"
    subprocess.run([
        "xcrun", "clang++", "-fobjc-arc", "-fblocks", "-std=c++20",
        "-framework", "Foundation", "-I", str(root),
        str(root / "test/native/rpcs3_diagnostics_test.mm"), "-o", str(binary),
    ], check=True)
    subprocess.run([str(binary), directory], check=True, timeout=60)
print("RPCS3 native diagnostics concurrency/rotation/reopen tests: OK")
