#!/usr/bin/env python3
"""Inspect delivered bytes; never equate packaging with iPhone validation."""
from pathlib import Path
import argparse
import hashlib
import json
import plistlib
import zipfile

BASELINE = {
    'Frameworks/libRPCS3Core.dylib': 'dba1bb3bf8847faf3e378c1815ffe895521d8d6404e468bb6a2eee5fa8cb4ddd',
    'Frameworks/DolphinCore.framework/DolphinCore': '60012e203c927d468cb6d82d21aa8f8e14299fedbf0b2f80ce0ea982d4e173ee',
    'Frameworks/StikJIT.framework/universal.js': '22b0146b14ac230b3e04f1cbcaadbfddd898cbe6bb96c554981bef9cff311ba1',
    'Frameworks/StikJIT.framework/legacy.js': '787df4678ca17fd100a1d002203bfac8771fae062175aa510da8d6af9f8167ec',
}


def verify(path):
    with zipfile.ZipFile(path) as archive:
        prefix = 'Payload/NeoStation.app/'
        info = plistlib.loads(archive.read(prefix + 'Info.plist'))
        assert str(info['CFBundleVersion']) == '272', 'Wrong build number'
        assert info.get('UIFileSharingEnabled') is True, 'Diagnostic must be available in Files'
        for name, expected in BASELINE.items():
            assert hashlib.sha256(archive.read(prefix + name)).hexdigest() == expected, 'Known-good baseline changed: ' + name
        assert prefix + 'Frameworks/StikJIT.framework/rpcs3-universal.js' not in archive.namelist()
        manager = archive.read(prefix + 'Frameworks/stikjit_bridge.framework/stikjit_bridge')
        # Do not search for fragments of interpolated Swift values: the linker
        # may split/encode them. Check actual, long executable policy literals.
        for marker in (
            b'NEOSTATION_VPN_USER_CHOICE_272: endpoint reachable; VPN unchanged',
            b'NEOSTATION_VPN_USER_CHOICE_272: endpoint unavailable; VPN unchanged',
            b'Diagnostic-VPN-RPCS3.txt', b'Diagnostic-VPN-RPCS3-precedent.txt',
        ):
            assert marker in manager, 'Missing compiled policy/report marker: ' + repr(marker)
        assert b'nativeDebuggerLease270=active' not in manager
        provider = archive.read(prefix + 'PlugIns/NeoStationLocalTunnel.appex/NeoStationLocalTunnel')
        assert b'neostation.vpn271.packets' in provider, 'Missing retained packet transport'
        assert b'network settings callback missing after 10s' in provider, 'Missing bounded manual startup'
        assert b'heartbeat expired' not in provider, 'Host heartbeat must not stop the tunnel'
        bridge = archive.read(prefix + 'Frameworks/rpcs3_internal_bridge.framework/rpcs3_internal_bridge')
        assert b'neostation.rpcs3.diagnostics.async272' in bridge, 'Missing asynchronous RPCS3 logger'
        dolphin = archive.read(prefix + 'Frameworks/dolphin_internal_bridge.framework/dolphin_internal_bridge')
        assert b'DolphinRetroAchievementsAccount' in dolphin
        helper = archive.read(prefix + 'Frameworks/rpcs3_jit_helper.framework/rpcs3_jit_helper')
        assert b'NEOSTATION_RPCS3_STOP_REPLY_270' not in helper
        dart = archive.read(prefix + 'Frameworks/App.framework/App')
        assert b'Diagnostic-VPN-RPCS3.txt' in dart
        return {
            'build': 272, 'baselineBuild': 267, 'unchangedBaselineSHA256': BASELINE,
            'manualOnlyVPN': True, 'backgroundOrLaunchVPNMutation': False,
            'rpcS3OptionalHelperLogs': 'suppressed; mandatory handshake retained',
            'nativeDiagnostics': 'bounded asynchronous milestones; no synchronous flush',
            'shaderCache': 'baseline cache restoration retained; no new whole-title precompile',
            'diagnosticFile': 'Documents/Diagnostic-VPN-RPCS3.txt',
            'diagnosticPreviousFile': 'Documents/Diagnostic-VPN-RPCS3-precedent.txt',
            'ipaSHA256': hashlib.sha256(path.read_bytes()).hexdigest(),
            'deviceTested': False,
        }


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('ipa', type=Path)
    parser.add_argument('--report', type=Path, required=True)
    args = parser.parse_args()
    result = verify(args.ipa)
    args.report.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))
