#!/usr/bin/env python3
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]

def read(path):
    return (ROOT / path).read_text()

jit = read('packages/rpcs3_internal_bridge/ios/Classes/Rpcs3JitBridgePlugin.mm')
helper = read('packages/rpcs3_jit_helper/ios/Classes/Rpcs3JITRequestHandlerBase.swift')
service = read('lib/services/rpcs3_internal_service.dart')

# Working VPN stack is frozen for this RPCS3-only build.
assert subprocess.check_output(
    ['git', 'hash-object', 'native/local_jit_tunnel/PacketTunnelProvider.swift'],
    cwd=ROOT, text=True).strip() == 'f68c3e4f596cd75e554f91e6596fc9c234ceb4de'
# Manager behavior is now tested by vpn_state_machine_test.py.

# A vAttach stop reply alone may not release Core dlopen. The helper must first
# enter universal.js's first continue loop and publish an explicit ready event.



assert 'session.coreLoadReady' in jit







# An incomplete boot is evidence of a crash, not proof of a corrupt PPU cache.
assert '_consumePreviousIncompleteBootMarker(normalized)' in service
assert 'Rpcs3InternalBridge.clearPpuCache(titleId)' not in service
assert 'preserving the title PPU cache for the retry.' in service

print('PASS: Core gate uses debugger probe; PPU cache and VPN provider preserved')

assert 'confirmCoreLoadReady' in jit
assert 'RPCS3DebuggerProbe(_probeNonce)' in jit
assert 'RPCS3HostHasLiveDebugger' in jit
assert 'scheduleCoreLoadReady' not in helper
assert 'Handling signal 1' not in helper
assert '.milliseconds(250)' not in helper
subprocess.run(['node', 'test/rpcs3_debugger_handshake_test.js'], cwd=ROOT, check=True)
