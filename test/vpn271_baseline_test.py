#!/usr/bin/env python3
"""Verify actual compiled sources, not labels or unpatched repository files.

Build 267 also applied host patches before compiling. Reconstruct that exact
baseline independently; never compare a generated source to raw git content.
"""
from pathlib import Path
import difflib
import hashlib
import io
import json
import subprocess
import sys
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[1]
BASE = 'e653c5711d5fc139b066bb8c120e4874e4cf61c5'
FILES = [
    'lib/services/rpcs3_internal_service.dart',
    'packages/rpcs3_internal_bridge/ios/Classes/Rpcs3JitBridgePlugin.mm',
    'packages/rpcs3_internal_bridge/ios/Classes/Rpcs3Diagnostics.h',
    'packages/rpcs3_jit_helper/ios/Classes/Rpcs3JITRequestHandlerBase.swift',
    'packages/rpcs3_internal_bridge/ios/Classes/Rpcs3InternalBridgePlugin.mm',
    'packages/rpcs3_internal_bridge/ios/Classes/Rpcs3CoreABI.h',
    'build-utils/patch_stikjit_rpcs3.py',
    'build-utils/patch_stikjit_remote_pairing.py',
]
DIFF_PATCHES = [
    'rpcs3_build243_host.patch',
    'rpcs3_build243_menu_transition.patch',
    'rpcs3_build246_safe_controls.patch',
    'rpcs3_build247_localization.patch',
    'rpcs3_build251_upscale.patch',
    'grid_title_build243.patch',
]
PY_PATCHES = [
    'patch_rpcs3_savestate_ui.py',
    'patch_rpcs3_performance_telemetry.py',
    'patch_rpcs3_build256_host.py',
    'patch_rpcs3_build260_modern_menu.py',
    'patch_rpcs3_build265_host.py',
    'patch_dolphin_build267_account.py',
]


def compare_effective_baseline():
    archive = subprocess.check_output(['git', 'archive', '--format=tar', BASE], cwd=ROOT)
    result = {}
    with tempfile.TemporaryDirectory(prefix='rpcs3-267-effective-') as temporary:
        baseline_root = Path(temporary)
        with tarfile.open(fileobj=io.BytesIO(archive), mode='r:') as source:
            source.extractall(baseline_root, filter='data')
        for patch in DIFF_PATCHES:
            subprocess.run(['git', 'apply', 'build-utils/patches/' + patch],
                           cwd=baseline_root, check=True, timeout=15)
        for patch in PY_PATCHES:
            subprocess.run([sys.executable, str(baseline_root / 'build-utils' / patch)],
                           cwd=baseline_root, check=True, timeout=30)
        for name in FILES:
            baseline = (baseline_root / name).read_bytes()
            actual = (ROOT / name).read_bytes()
            if actual != baseline:
                difference = ''.join(difflib.unified_diff(
                    baseline.decode().splitlines(True), actual.decode().splitlines(True),
                    fromfile='effective267/' + name, tofile='build271/' + name))
                raise AssertionError('RPCS3 compiled 267 baseline changed:\n' + difference[:12000])
            result[name] = hashlib.sha256(actual).hexdigest()
    return result


def main():
    result = compare_effective_baseline()
    workflow = (ROOT / '.github/workflows/release-ipa.yml').read_text()
    assert 'patch_rpcs3_build270_transport.py' not in workflow
    assert 'patch_rpcs3_stop_reply270.py' not in workflow
    helper = (ROOT / 'packages/rpcs3_jit_helper/ios/Classes/Rpcs3JITRequestHandlerBase.swift').read_text()
    assert 'script: .universal' in helper and 'selectedScript' not in helper
    ui = (ROOT / 'lib/screens/settings_screen/new_settings_options/tools_settings_content.dart').read_text()
    toggle = ui.split('Future<void> _toggleTunnel()', 1)[1].split('Future<void> _refreshPairingState()', 1)[0]
    assert 'await LocalJitTunnelService.status()' not in toggle
    assert 'request != _tunnelRequestId' in toggle
    assert 'request == _tunnelRequestId' in toggle
    assert 'final disable = _isUpdatingTunnel ||' in toggle
    manager = (ROOT / 'packages/stikjit_bridge/ios/Classes/NeoStationLocalTunnelManager.swift').read_text()
    provider = (ROOT / 'native/local_jit_tunnel/PacketTunnelProvider.swift').read_text()
    assert 'beginDebuggerLease' not in manager and 'startHeartbeat' not in manager
    assert 'expireHeartbeat' not in provider and 'jitLeaseBegin' not in provider
    assert 'seconds: 30' in manager and 'seconds: 10' in manager
    assert 'limit=4s' in manager and 'no native callback' in manager
    journal = (ROOT / 'packages/stikjit_bridge/ios/Classes/NeoStationVPNDiagnostics.swift').read_text()
    assert 'Diagnostic-VPN-RPCS3.txt' in journal and 'snapshotRPCS3' in journal
    assert 'NeoStationVPNDiagnostics.initialize()' in (ROOT / 'packages/stikjit_bridge/ios/Classes/StikjitBridgePlugin.swift').read_text()
    report = {
        'referenceBuild': 267, 'referenceCommit': BASE,
        'referenceReconstructedFromGitArchive': True,
        'referenceDiffPatches': DIFF_PATCHES, 'referencePythonPatches': PY_PATCHES,
        'sourceSHA256': result, 'newJITProtocol': False, 'deviceTested': False,
    }
    output = ROOT / 'build/rpcs3-ci/build271-source-baseline.json'
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, indent=2) + '\n')
    print('PASS: exact effective Build 267 RPCS3 launch/loader/helper/JIT sources; bounded VPN-only changes and TXT diagnostics')


if __name__ == '__main__':
    main()
