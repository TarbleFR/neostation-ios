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
assert subprocess.check_output(
    ['git', 'hash-object', 'packages/stikjit_bridge/ios/Classes/NeoStationLocalTunnelManager.swift'],
    cwd=ROOT, text=True).strip() == 'db453b2fb2fbf1fe640afe7215d30e297b4b69a8'

# A vAttach stop reply alone may not release Core dlopen. The helper must first
# enter universal.js's first continue loop and publish an explicit ready event.
assert 'core_load_ready' in jit
assert 'waitUntilCoreLoadReady' in jit
assert 'kRpcs3CoreLoadReadyTimeout = 5.0' in jit
assert 'session.coreLoadReady' in jit
assert 'first Universal continue armed' in jit
assert 'firstUniversalContinue' in helper
assert 'Handling signal 1' in helper
assert 'scheduleCoreLoadReady' in helper
assert '.milliseconds(250)' in helper
assert 'Universal JIT first continue is armed for Core loading.' in helper

# An incomplete boot is evidence of a crash, not proof of a corrupt PPU cache.
assert '_consumePreviousIncompleteBootMarker(normalized)' in service
assert 'Rpcs3InternalBridge.clearPpuCache(titleId)' not in service
assert 'preserving the title PPU cache for the retry.' in service

print('PASS: Build 285 gates dlopen on Universal continue readiness, preserves PPU cache, VPN frozen')
