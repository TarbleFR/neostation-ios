#!/usr/bin/env python3
"""Embed RPCS3 Core after Xcode builds NeoStation and prove lazy loading.

The dylib is copied into the built .app only after the host and plugin have
linked. We then inspect every Mach-O in the application and reject the build if
anything except libRPCS3Core.dylib itself declares a dependency on it.
"""
from __future__ import annotations

import os
import plistlib
import shutil
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PRODUCTS = ROOT / 'build/ios/DolphinDerivedData/Build/Products/Release-iphoneos'
CORE = ROOT / 'packages/rpcs3_internal_bridge/ios/Frameworks/libRPCS3Core.dylib'


def is_macho(path: Path) -> bool:
    try:
        output = subprocess.check_output(['file', str(path)], text=True, stderr=subprocess.DEVNULL)
    except subprocess.CalledProcessError:
        return False
    return 'Mach-O' in output


def dependencies(path: Path) -> str:
    try:
        return subprocess.check_output(['otool', '-L', str(path)], text=True, stderr=subprocess.STDOUT)
    except subprocess.CalledProcessError as exc:
        raise SystemExit(f'Could not inspect Mach-O dependencies for {path}: {exc.output}')


def main() -> None:
    apps = [path for path in PRODUCTS.glob('*.app') if path.is_dir()]
    if len(apps) != 1:
        raise SystemExit(f'Expected exactly one built app, found {apps}')
    app = apps[0]
    if not CORE.is_file() or CORE.stat().st_size < 60_000_000:
        raise SystemExit(f'RPCS3 Core is missing or unexpectedly small: {CORE}')

    frameworks = app / 'Frameworks'
    frameworks.mkdir(parents=True, exist_ok=True)
    destination = frameworks / 'libRPCS3Core.dylib'
    shutil.copy2(CORE, destination)
    destination.chmod(0o755)

    linked = []
    inspected = 0
    for path in app.rglob('*'):
        if not path.is_file() or path == destination:
            continue
        if not is_macho(path):
            continue
        inspected += 1
        output = dependencies(path)
        if 'libRPCS3Core.dylib' in output:
            linked.append(str(path.relative_to(app)))

    if linked:
        raise SystemExit(
            'RPCS3 Core is still linked at application startup: ' + ', '.join(linked)
        )

    # Ensure the app executable itself exists and is part of the verified scan.
    info = plistlib.loads((app / 'Info.plist').read_bytes())
    executable = app / str(info.get('CFBundleExecutable', ''))
    if not executable.is_file() or not is_macho(executable):
        raise SystemExit('Built NeoStation executable is missing or not Mach-O')

    print(f'Embedded dormant RPCS3 Core at {destination}')
    print(f'RPCS3 lazy-link validation passed across {inspected} NeoStation Mach-O binaries.')


if __name__ == '__main__':
    main()
