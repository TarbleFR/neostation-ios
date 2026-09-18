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
assert subprocess.check_output(
    ['git', 'hash-object', 'packages/stikjit_bridge/ios/Classes/NeoStationLocalTunnelManager.swift'],
    cwd=ROOT, text=True).strip() == '928c70f8cdb7ef156618a2d58091a4dee74069fe'

host = text('packages/rpcs3_internal_bridge/ios/Classes/Rpcs3InternalBridgePlugin.mm')
diag = text('packages/rpcs3_internal_bridge/ios/Classes/Rpcs3Diagnostics.h')
jit = text('packages/rpcs3_internal_bridge/ios/Classes/Rpcs3JitBridgePlugin.mm')
helper = text('packages/rpcs3_jit_helper/ios/Classes/Rpcs3JITRequestHandlerBase.swift')

assert '#import "Rpcs3EarlyLoaderDiagnostics.h"' in host
assert 'RPCS3RecoverEarlyLoaderLog();' in host
assert 'RPCS3EarlyLoaderCapture earlyLoaderCapture;' in host
assert 'RTLD_NOW | RTLD_LOCAL' in host

assert 'dispatch_async(queue' in diag
assert 'synchronizeFile' not in diag
assert '@synchronized' not in diag

assert 'pendingLogs < 32' in helper
assert 'if event == "log"' in helper
assert 'String(message.prefix(4096))' in helper
assert 'Timed out writing control state to NeoStation.' in helper
assert 'jit_helper_' in jit
assert '_mutableLogs.count > 64' in jit

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

print('PASS: Build 280 RPCS3 loader is nonblocking, recoverable, and VPN 279 is frozen')
