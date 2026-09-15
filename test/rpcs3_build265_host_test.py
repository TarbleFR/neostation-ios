#!/usr/bin/env python3
"""Current packaging identity and retained Build 265, patch order and bounded diagnostic contract."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

def main() -> None:
    build = (ROOT / 'build-utils/build_rpcs3_embedded_core.sh').read_text()
    assert 'BUILD_NUMBER=266' in build
    assert 'NeoStation-iOS-Build-266-JIT-v09' in build
    assert build.count('patch_rpcs3_build266_v09_core.py') == 2
    assert 'rpcs3_build266_v09_core_test.py' in build
    assert build.index('patch_rpcs3_build264_gow3_core.py') < build.index('patch_rpcs3_build265_core.py')
    assert build.count('patch_rpcs3_build265_core.py') == 2
    assert 'rpcs3_build265_core_test.py' in build
    bridge = (ROOT / 'packages/rpcs3_internal_bridge/ios/Classes/Rpcs3InternalBridgePlugin.mm').read_text()
    assert 'NEOSTATION_BUILD265_COREPROF_LOG' in bridge
    assert 'level > 5 && strstr(message, "COREPROF ") == nullptr &&' in bridge
    assert 'strstr(message, "COREPROF_RESILIENCE ") == nullptr' in bridge
    assert 'RPCS3Diagnostic(@"core_log", text);' in bridge
    print('Build 265 host/packaging/diagnostic contract: OK')

if __name__ == '__main__':
    main()
