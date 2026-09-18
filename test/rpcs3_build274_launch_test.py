#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

def text(name):
    return (ROOT / name).read_text()

manager = text('packages/stikjit_bridge/ios/Classes/NeoStationLocalTunnelManager.swift')
segment = manager.split('NEOSTATION_VPN_STABLE_PREFLIGHT_274', 1)[1].split('// Explicit Settings ON', 1)[0]
assert segment.count('probeJitRoute') == 2, 'preflight must be one bounded two-sample stability gate'
for forbidden in ('loadAllFromPreferences', 'saveToPreferences', 'startVPNTunnel', 'stopVPNTunnel', 'activeManager'):
    assert forbidden not in segment, f'RPCS3 preflight mutates VPN: {forbidden}'
assert '.now() + 0.25' in segment

service = text('lib/services/rpcs3_internal_service.dart')
jit_block = service.split('static Future<void> _prepareJitInternal()',1)[1].split('static String _actionableJitFailure',1)[0]
assert 'Timer.periodic' not in jit_block, 'JIT boot still polls status every second'
assert jit_block.count('await _jitStatus()') == 1, 'only the initial reusable-JIT observation is allowed'
assert "jit['debugged'] != true" in jit_block
assert jit_block.index('LocalJitTunnelService.ensureRunningForJit()') < jit_block.index('Rpcs3InternalBridge.prepareJit')
assert 'ensureRunningForJit' not in service.split('Rpcs3InternalBridge.prepareJit',1)[1].split('static String _actionableJitFailure',1)[0]

bridge = text('packages/rpcs3_internal_bridge/ios/Classes/Rpcs3JitBridgePlugin.mm')
assert 'kRpcs3HelperConnectTimeout = 12.0' in bridge
assert 'kRpcs3CompletionTimeout = 45.0' in bridge
assert 'kRpcs3AttachTimeout = 600.0' in bridge, 'first DDI preparation must remain supported'

core = text('packages/rpcs3_internal_bridge/ios/Classes/Rpcs3InternalBridgePlugin.mm')
assert 'memoryPreflightPassed' in core
assert 'validated and cached for this process' in core
assert 'if (_api.handle)' in core, 'dlopen must remain one-time per process'
assert 'cache_path = cache.fileSystemRepresentation' in core, 'persistent cache path must remain wired into the Core'
assert 'precompileShader' not in core and 'compileAllShaders' not in core

diag = text('packages/rpcs3_internal_bridge/ios/Classes/Rpcs3Diagnostics.h')
assert 'dispatch_async(queue' in diag
assert 'synchronizeFile' not in diag
assert '@synchronized' not in diag

print('PASS: Build 274 RPCS3 launch path is bounded before JIT and quiet during boot')
