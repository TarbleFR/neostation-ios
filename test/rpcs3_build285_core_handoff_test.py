#!/usr/bin/env python3
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]

def read(path):
    return (ROOT / path).read_text()

jit = read('packages/rpcs3_internal_bridge/ios/Classes/Rpcs3JitBridgePlugin.mm')
host = read('packages/rpcs3_internal_bridge/ios/Classes/Rpcs3InternalBridgePlugin.mm')
helper = read('packages/rpcs3_jit_helper/ios/Classes/Rpcs3JITRequestHandlerBase.swift')
service = read('lib/services/rpcs3_internal_service.dart')

# A vAttach stop reply alone may not release Core dlopen. The helper must first
# enter universal.js's first continue loop and publish an explicit ready event.



assert 'RPCS3JitHasActiveCoreHandshake' in jit







# An incomplete boot is evidence of a crash, not proof of a corrupt PPU cache.
assert '_consumePreviousIncompleteBootMarker(normalized)' in service
assert 'Rpcs3InternalBridge.clearPpuCache(titleId)' not in service
assert 'preserving the title PPU cache for the retry.' in service

print('PASS: Core gate uses debugger probe; PPU cache preserved')

assert 'confirmCoreLoadReady' in jit
assert 'RPCS3DebuggerProbe(_probeNonce)' in jit
assert 'RPCS3HostHasLiveDebugger' in jit
assert 'RPCS3JitConfirmCoreLoadHandoff' in jit
assert 'RPCS3JitConfirmCoreLoadHandoff()' in host
load_boundary = host.split('for (NSString* path in candidates)', 1)[1].split('#define LOAD', 1)[0]
assert load_boundary.index('RPCS3JitConfirmCoreLoadHandoff()') < load_boundary.index('dlopen(')
assert 'core_handoff_begin' in load_boundary
assert 'core_handoff_end' in load_boundary
prepare_boundary = jit.split('if (![call.method isEqualToString:@"prepareJit"])', 1)[1]
assert '[session confirmCoreLoadReady]' not in prepare_boundary
assert 'final nonce validation is reserved for the Core load boundary' in prepare_boundary
assert 'helperToAttachMs=%.1f' in jit
assert 'final nonce resume proof pending' in jit
assert 'host resumed after vAttach' not in jit
assert 'scheduleCoreLoadReady' not in helper
assert 'Handling signal 1' not in helper
assert '.milliseconds(250)' not in helper
subprocess.run(['node', 'test/rpcs3_debugger_handshake_test.js'], cwd=ROOT, check=True)
