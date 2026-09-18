#!/usr/bin/env python3
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]

def read(path):
    return (ROOT / path).read_text()

host = read('packages/rpcs3_internal_bridge/ios/Classes/Rpcs3InternalBridgePlugin.mm')
diag = read('packages/rpcs3_internal_bridge/ios/Classes/Rpcs3Diagnostics.h')
service = read('lib/services/rpcs3_internal_service.dart')

# RPCS3 Build 283 must preserve the device-validated Build 279 provider.
# The host-side VPN manager is intentionally allowed to evolve independently.
assert subprocess.check_output(
    ['git', 'hash-object', 'native/local_jit_tunnel/PacketTunnelProvider.swift'],
    cwd=ROOT, text=True).strip() == 'f68c3e4f596cd75e554f91e6596fc9c234ceb4de'

assert 'NEOSTATION_BUILD283_BOUNDED_CORE_LOG' in host
assert 'if (level > 2 && !profiler) return;' in host
assert 'budgetCount >= 128' in host
assert 'RPCS3Milestone(@"core_load_begin"' in host
assert 'RPCS3Milestone(@"core_initialize_begin"' in host
assert 'RPCS3Milestone(@"game_boot_begin"' in host
assert 'RPCS3-milestones.log' in diag
assert 'static NSFileHandle* file;' in diag
assert '[file synchronizeFile];' in diag

assert 'incomplete-boot-title.txt' in service
assert '_recoverPreviousIncompleteBoot(normalized)' in service
assert 'Rpcs3InternalBridge.clearPpuCache(titleId)' in service
assert '_armBootCrashMarker(normalized)' in service
assert '_clearBootCrashMarkerWhenRunning(bootMarker)' in service
assert 'state == 5 || state == 6' in service
assert "await marker.writeAsString(titleId, flush: true)" in service

print('PASS: Build 283 bounded RPCS3 diagnostics, durable crash milestones, PPU boot recovery, VPN 279 provider frozen')
