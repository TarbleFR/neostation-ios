#!/usr/bin/env python3
"""Exercise the production dlopen boundary, not a mock presence predicate."""
from pathlib import Path
import platform
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
source = ROOT / "test/dusklight_core_loader_test.cpp"
header = ROOT / "packages/dusklight_internal_bridge/ios/Classes/DusklightCoreLoader.h"
# CocoaPods exposes .h files through an Objective-C umbrella as well as C++.
subprocess.run(["cc", "-x", "c", "-fsyntax-only", "-include", str(header), "-"],
               input="", text=True, check=True)
with tempfile.TemporaryDirectory(prefix="neostation-dusklight-loader-") as folder:
    root = Path(folder)
    library = root / "DusklightCore.dylib"
    executable = root / "loader-test"
    subprocess.run(["c++", "-std=c++17", "-shared", "-fPIC", "-DDUSKLIGHT_LOADER_FIXTURE",
                    str(source), "-o", str(library)], check=True)
    library.chmod(0o644)
    command = ["c++", "-std=c++17", "-Wall", "-Wextra", "-Werror",
               "-I" + str(ROOT / "packages/dusklight_internal_bridge/ios/Classes"),
               str(source), "-o", str(executable)]
    if platform.system() == "Linux":
        command += ["-ldl"]
    subprocess.run(command, check=True)
    subprocess.run([str(executable), str(library), str(source)], check=True)
