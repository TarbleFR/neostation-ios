#!/usr/bin/env python3
"""Configure NeoStation for the lazy RPCS3 runtime and its required entitlements.

RPCS3 iOS 0.8.1 is still lazy-loaded, so it cannot crash NeoStation before a
PS3 action is requested. Once requested, however, the Core requires the same
host capabilities as the standalone RPCS3 IPA: get-task-allow, extended virtual
addressing and the increased memory limits. These are emitted into
Runner.entitlements and copied to NeoStation-signing.entitlements by the IPA
packager so the sideloading/signing step can preserve them.
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

REQUIRED_RUNTIME_ENTITLEMENTS = {
    'get-task-allow': True,
    'com.apple.developer.kernel.extended-virtual-addressing': True,
    'com.apple.developer.kernel.increased-memory-limit': True,
    'com.apple.developer.kernel.increased-debugging-memory-limit': True,
}


def configure_runner_entitlements() -> None:
    path = RUNNER / 'Runner.entitlements'
    payload = plistlib.loads(path.read_bytes()) if path.is_file() else {}
    if not isinstance(payload, dict):
        raise SystemExit('Existing Runner entitlements are not a dictionary')
    payload.update(REQUIRED_RUNTIME_ENTITLEMENTS)
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
    configure_runner_entitlements()
    print('Configured RPCS3 lazy runtime with required NeoStation JIT/memory entitlements.')


if __name__ == '__main__':
    main()
