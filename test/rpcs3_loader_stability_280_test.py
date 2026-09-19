#!/usr/bin/env python3
from pathlib import Path
import hashlib
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]

def text(path):
    return (ROOT / path).read_text()

# Build 279 VPN is frozen during this RPCS3-only fix.
assert subprocess.check_output(
    ['git', 'hash-object', 'native/local_jit_tunnel/PacketTunnelProvider.swift'],
    cwd=ROOT, text=True).strip() == 'f68c3e4f596cd75e554f91e6596fc9c234ceb4de'
# Manager behavior is now tested by vpn_state_machine_test.py.

host = text('packages/rpcs3_internal_bridge/ios/Classes/Rpcs3InternalBridgePlugin.mm')
diag = text('packages/rpcs3_internal_bridge/ios/Classes/Rpcs3Diagnostics.h')
jit = text('packages/rpcs3_internal_bridge/ios/Classes/Rpcs3JitBridgePlugin.mm')
helper = text('packages/rpcs3_jit_helper/ios/Classes/Rpcs3JITRequestHandlerBase.swift')

assert '#import "Rpcs3EarlyLoaderDiagnostics.h"' in host
assert 'RPCS3RecoverEarlyLoaderLog();' in host
assert 'RPCS3EarlyLoaderCapture earlyLoaderCapture;' in host
assert 'RTLD_NOW | RTLD_LOCAL' in host

assert 'dispatch_async(queue' in diag
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
            '-framework', 'Foundation', '-I', str(ROOT),
            str(ROOT / 'test/native/rpcs3_early_loader_test.mm'), '-o', exe,
        ], check=True)
        assert subprocess.run([exe, directory, 'crash'], check=False).returncode == 23
        subprocess.run([exe, directory, 'recover'], check=True)

print('PASS: loader diagnostics recoverable; provider unchanged')

assert 'confirmCoreLoadReady' in jit
assert 'RPCS3DebuggerProbe(_probeNonce)' in jit
assert 'RPCS3HostHasLiveDebugger' in jit
assert 'RPCS3JitConfirmCoreLoadHandoff' in host
assert 'scheduleCoreLoadReady' not in helper
assert 'Handling signal 1' not in helper
assert '.milliseconds(250)' not in helper
subprocess.run(['node', 'test/rpcs3_debugger_handshake_test.js'], cwd=ROOT, check=True)
