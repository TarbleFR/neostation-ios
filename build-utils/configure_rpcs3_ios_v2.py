#!/usr/bin/env python3
"""Configure the RPCS3 helper without forcing host entitlements.

Build 216 intentionally ships a neutral NeoStation entitlement file. Users may
apply get-task-allow / memory capabilities when they sign the IPA themselves
(e.g. developer account or a compatible sideloading workflow). RPCS3 remains a
lazy-loaded optional engine and must never prevent NeoStation from reaching its
menus when those capabilities are absent.
"""
from __future__ import annotations

import plistlib
from pathlib import Path

from configure_rpcs3_ios_v1 import (
    IOS,
    ROOT,
    RUNNER,
    configure_helper_files,
    configure_podfile,
    configure_xcode_project,
)

FORCED_RUNTIME_ENTITLEMENTS = (
    'get-task-allow',
    'com.apple.developer.kernel.extended-virtual-addressing',
    'com.apple.developer.kernel.increased-memory-limit',
    'com.apple.developer.kernel.increased-debugging-memory-limit',
)


def neutralize_runner_entitlements() -> None:
    path = RUNNER / 'Runner.entitlements'
    payload = plistlib.loads(path.read_bytes()) if path.is_file() else {}
    if not isinstance(payload, dict):
        raise SystemExit('Existing Runner entitlements are not a dictionary')
    for key in FORCED_RUNTIME_ENTITLEMENTS:
        payload.pop(key, None)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(plistlib.dumps(payload, fmt=plistlib.FMT_XML, sort_keys=False))


def main() -> None:
    if not (IOS / 'Runner.xcodeproj').is_dir():
        raise SystemExit('Generate the Flutter iOS host before configuring RPCS3')
    core = ROOT / 'packages/rpcs3_internal_bridge/ios/Frameworks/libRPCS3Core.dylib'
    if not core.is_file():
        raise SystemExit(f'RPCS3 Core has not been materialized: {core}')
    stik = ROOT / 'packages/stikjit_bridge/ios/Frameworks/StikJIT.xcframework/ios-arm64/StikJIT.framework/StikJIT'
    if not stik.is_file():
        raise SystemExit(f'StikJIT device framework missing: {stik}')

    configure_helper_files()
    configure_podfile()
    configure_xcode_project()
    # Run this last because the Dolphin configurator legitimately prepares its
    # own host files first. We do not modify Dolphin code; we only ensure the
    # distributed NeoStation IPA does not force user-specific capabilities.
    neutralize_runner_entitlements()
    print('Configured RPCS3 lazy runtime with neutral NeoStation entitlements.')


if __name__ == '__main__':
    main()
