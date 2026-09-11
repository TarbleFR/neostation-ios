#!/usr/bin/env python3
"""Install NeoStation's source-built StikJIT 1.5.0 XCFramework.

This intentionally mirrors the established framework placement performed by
Dolphin's build support, while requiring the Build 240 RPCS3 transport markers
before the framework can enter the iOS host.
"""
from __future__ import annotations

import hashlib
import json
import plistlib
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LOGS = ROOT / 'build/dolphin-ci'
STIK_VERSION = '1.5.0'
STIK_SOURCE_REVISION = '640fac91de403fdb85a3778aa0bbb7f30737b74c'
SWIFT_MARKER = b'NEOSTATION_STIKJIT_RPCS3_V1'
JS_MARKER = b'NEOSTATION_STIKJIT_UNIVERSAL_V1'


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open('rb') as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def write_plist(path: Path, data: dict) -> None:
    path.write_bytes(plistlib.dumps(data, fmt=plistlib.FMT_XML, sort_keys=False))


def repair_swift_interfaces(root: Path) -> None:
    for interface in root.rglob('*.swiftinterface'):
        text = interface.read_text()
        # Preserve the qualification repair already used by NeoStation for the
        # official 1.5.0 binary distribution. This does not alter StikJIT API.
        for name in ('DDIPaths', 'DeveloperDiskImageService', 'StikJITError'):
            text = text.replace('StikJIT.' + name, name)
        text = text.replace('StikJIT.StikJIT.', 'StikJIT.')
        interface.write_text(text)


def install(xcframework: Path) -> None:
    if not xcframework.is_dir() or xcframework.name != 'StikJIT.xcframework':
        raise SystemExit(f'Expected StikJIT.xcframework directory, got {xcframework}')

    repair_swift_interfaces(xcframework)
    device = xcframework / 'ios-arm64/StikJIT.framework'
    binary = device / 'StikJIT'
    if not binary.is_file():
        raise SystemExit('Source-built StikJIT device framework is missing its binary')
    binary_data = binary.read_bytes()
    if SWIFT_MARKER not in binary_data:
        raise SystemExit('Source-built StikJIT binary is missing the NeoStation RPCS3 patch marker')

    universal_scripts = list(device.rglob('universal.js'))
    if len(universal_scripts) != 1:
        raise SystemExit(f'Expected exactly one bundled universal.js, found {universal_scripts}')
    if JS_MARKER not in universal_scripts[0].read_bytes():
        raise SystemExit('Source-built StikJIT universal.js is missing the NeoStation failure-propagation patch')

    info_path = device / 'Info.plist'
    info = plistlib.loads(info_path.read_bytes()) if info_path.is_file() else {}
    info.update({
        'CFBundleExecutable': 'StikJIT',
        'CFBundleIdentifier': 'com.stik.StikJIT',
        'CFBundleInfoDictionaryVersion': '6.0',
        'CFBundleName': 'StikJIT',
        'CFBundlePackageType': 'FMWK',
        'CFBundleShortVersionString': STIK_VERSION,
        'CFBundleVersion': '1',
        'CFBundleSupportedPlatforms': ['iPhoneOS'],
        'MinimumOSVersion': '17.4',
        'UIDeviceFamily': [1, 2],
    })
    write_plist(info_path, info)

    for package in ('stikjit_bridge', 'dolphin_jit_helper'):
        destination = ROOT / 'packages' / package / 'ios/Frameworks/StikJIT.xcframework'
        if destination.exists():
            shutil.rmtree(destination)
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copytree(xcframework, destination)
        (destination / 'ios-arm64/StikJIT.framework/StikJIT').chmod(0o755)

    LOGS.mkdir(parents=True, exist_ok=True)
    report = {
        'release': STIK_VERSION,
        'sourceRevision': STIK_SOURCE_REVISION,
        'patch': SWIFT_MARKER.decode('ascii'),
        'universalScriptPatch': JS_MARKER.decode('ascii'),
        'binarySha256': sha256(binary),
        'platform': 'ios-arm64',
    }
    (LOGS / 'stikjit-release.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    if len(sys.argv) != 2:
        raise SystemExit('usage: install_patched_stikjit.py <StikJIT.xcframework>')
    install(Path(sys.argv[1]).resolve())
