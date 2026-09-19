#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

def read(path):
    return (ROOT / path).read_text()

host = read('packages/rpcs3_internal_bridge/ios/Classes/Rpcs3InternalBridgePlugin.mm')
diag_header = read('packages/rpcs3_internal_bridge/ios/Classes/Rpcs3Diagnostics.h')
diag = read('packages/rpcs3_internal_bridge/ios/Classes/Rpcs3Diagnostics.mm')
service = read('lib/services/rpcs3_internal_service.dart')

assert 'NEOSTATION_BUILD283_BOUNDED_CORE_LOG' in host
assert 'if (level > 2 && !profiler) return;' in host
assert 'budgetCount >= 128' in host
assert 'RPCS3Milestone(@"core_load_begin"' in host
assert 'RPCS3Milestone(@"core_initialize_begin"' in host
assert 'RPCS3Milestone(@"game_boot_begin"' in host
assert 'RPCS3-milestones.log' in diag
assert 'static inline' not in diag_header
assert 'RPCS3SharedDiagnosticsWriter' in diag
assert 'NSFileHandle* _diagnosticFile;' in diag
assert '[file synchronizeFile];' in diag

assert 'incomplete-boot-title.txt' in service
assert '_consumePreviousIncompleteBootMarker(normalized)' in service
assert 'Rpcs3InternalBridge.clearPpuCache(titleId)' not in service
assert 'preserving the title PPU cache for the retry.' in service
assert '_armBootCrashMarker(normalized)' in service
assert '_clearBootCrashMarkerWhenRunning(bootMarker)' in service
assert 'state == 5 || state == 6' in service
assert "await marker.writeAsString(titleId, flush: true)" in service

print('PASS: bounded centralized diagnostics, durable milestones, non-destructive incomplete-boot recovery')
