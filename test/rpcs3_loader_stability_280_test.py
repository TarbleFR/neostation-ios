#!/usr/bin/env python3
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]

def text(path):
    return (ROOT / path).read_text()

host = text('packages/rpcs3_internal_bridge/ios/Classes/Rpcs3InternalBridgePlugin.mm')
diag_header = text('packages/rpcs3_internal_bridge/ios/Classes/Rpcs3Diagnostics.h')
diag = text('packages/rpcs3_internal_bridge/ios/Classes/Rpcs3Diagnostics.mm')
jit = text('packages/rpcs3_internal_bridge/ios/Classes/Rpcs3JitBridgePlugin.mm')
helper = text('packages/rpcs3_jit_helper/ios/Classes/Rpcs3JITRequestHandlerBase.swift')

assert '#import "Rpcs3EarlyLoaderDiagnostics.h"' in host
assert 'RPCS3RecoverEarlyLoaderLog();' in host
assert 'RPCS3EarlyLoaderCapture earlyLoaderCapture;' in host
assert 'RTLD_NOW | RTLD_LOCAL' in host

assert 'static inline' not in diag_header
assert 'FOUNDATION_EXPORT void RPCS3Diagnostic' in diag_header
assert 'dispatch_async(_diagnosticQueue' in diag
assert 'RPCS3-milestones.log' in diag
assert 'NEOSTATION_BUILD283_BOUNDED_CORE_LOG' in host

assert 'pendingLogs < 32' in helper
assert 'if event == "log"' in helper
assert 'String(message.prefix(4096))' in helper
assert 'Timed out writing control state to NeoStation.' in helper
assert '#import "Rpcs3Diagnostics.h"' in jit
assert 'jit_helper_' in jit
assert '_mutableLogs.count > 64' in jit


assert 'RPCS3JitHasActiveCoreHandshake' in jit




# Verify abrupt dlopen-style termination leaves recoverable stderr on macOS CI.
if sys.platform == 'darwin':
    with tempfile.TemporaryDirectory(prefix='rpcs3-loader-280-') as directory:
        exe = str(Path(directory) / 'early-loader-test')
        subprocess.run([
            'clang++', '-std=c++17', '-fobjc-arc', '-fblocks',
            '-DRPCS3_DIAGNOSTICS_TESTING=1',
            '-framework', 'Foundation', '-I', str(ROOT),
            str(ROOT / 'packages/rpcs3_internal_bridge/ios/Classes/Rpcs3Diagnostics.mm'),
            str(ROOT / 'test/native/rpcs3_early_loader_test.mm'),
            '-o', exe,
        ], check=True)
        assert subprocess.run([exe, directory, 'crash'], check=False).returncode == 23
        subprocess.run([exe, directory, 'recover'], check=True)

print('PASS: centralized loader diagnostics recoverable')

assert 'confirmCoreLoadReady' in jit
assert 'RPCS3DebuggerProbe(_probeNonce)' in jit
assert 'RPCS3HostHasLiveDebugger' in jit
assert 'RPCS3JitConfirmCoreLoadHandoff' in host
assert 'scheduleCoreLoadReady' not in helper
assert 'Handling signal 1' not in helper
assert '.milliseconds(250)' not in helper
subprocess.run(['node', 'test/rpcs3_debugger_handshake_test.js'], cwd=ROOT, check=True)
subprocess.run(
    [sys.executable, 'test/rpcs3_reporter_send_order_test.py'],
    cwd=ROOT,
    check=True,
)
