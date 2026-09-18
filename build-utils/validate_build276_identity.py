#!/usr/bin/env python3
"""Validate Build 276: VPN-only fix on the device-tested Build 273 RPCS3 path."""
from pathlib import Path
import argparse, hashlib, json, plistlib, zipfile

BASELINE = {
    'Frameworks/libRPCS3Core.dylib':
        'dba1bb3bf8847faf3e378c1815ffe895521d8d6404e468bb6a2eee5fa8cb4ddd',
    'Frameworks/DolphinCore.framework/DolphinCore':
        '60012e203c927d468cb6d82d21aa8f8e14299fedbf0b2f80ce0ea982d4e173ee',
    'Frameworks/StikJIT.framework/universal.js':
        '22b0146b14ac230b3e04f1cbcaadbfddd898cbe6bb96c554981bef9cff311ba1',
    'Frameworks/StikJIT.framework/legacy.js':
        '787df4678ca17fd100a1d002203bfac8771fae062175aa510da8d6af9f8167ec',
}

def verify(path):
    with zipfile.ZipFile(path) as archive:
        prefix = 'Payload/NeoStation.app/'
        info = plistlib.loads(archive.read(prefix + 'Info.plist'))
        assert str(info['CFBundleVersion']) == '276', 'Wrong application build'
        assert info.get('UIFileSharingEnabled') is True

        checked = {}
        for name, expected in BASELINE.items():
            digest = hashlib.sha256(archive.read(prefix + name)).hexdigest()
            assert digest == expected, 'Build 276 changed known-good runtime: ' + name
            checked[name] = digest

        manager = archive.read(prefix + 'Frameworks/stikjit_bridge.framework/stikjit_bridge')
        for marker in (
            b'NEOSTATION_VPN_MANUAL_ONLY_273: endpoint reachable; VPN unchanged',
            b'NEOSTATION_VPN_MANUAL_ONLY_273: endpoint unavailable; VPN unchanged',
            b'NEOSTATION_VPN_FINAL_276: system tunnel accepted independently of RemotePairing',
            b'Diagnostic-VPN-RPCS3.txt',
        ):
            assert marker in manager, 'Missing compiled VPN marker: ' + repr(marker)
        assert b'NEOSTATION_VPN_STABLE_PREFLIGHT_274' not in manager, \
            'Build 274 RPCS3/VPN experiment must not be in Build 276'

        provider = archive.read(prefix + 'PlugIns/NeoStationLocalTunnel.appex/NeoStationLocalTunnel')
        assert b'neostation.vpn271.packets' in provider
        assert b'network settings callback missing after 10s' not in provider
        assert b'packet write failed after bounded retries' not in provider
        assert b'heartbeat expired' not in provider

        dart = archive.read(prefix + 'Frameworks/App.framework/App')
        assert b'RPCS3 JIT did not remain active after StikJIT detached.' in dart, \
            'Build 273 RPCS3/JIT host path was not preserved'
        assert b'RPCS3 JIT did not remain active after the initial StikJIT attach.' not in dart, \
            'Build 274 RPCS3 launch changes leaked into Build 276'

        dolphin = archive.read(prefix + 'Frameworks/dolphin_internal_bridge.framework/dolphin_internal_bridge')
        assert b'DolphinRetroAchievementsAccount' in dolphin

        dynamic_helper = prefix + 'Frameworks/rpcs3_jit_helper.framework/rpcs3_jit_helper'
        assert dynamic_helper not in archive.namelist()
        helper = archive.read(prefix + 'PlugIns/RPCS3JITHelper.appex/RPCS3JITHelper')
        assert b'NEOSTATION_RPCS3_STOP_REPLY_270' not in helper

        return {
            'build': 276,
            'referenceBaseline': 273,
            'referenceCommit': '8558dc782b98b114f944514e27722fe1a5faff48',
            'unchangedBaselineSHA256': checked,
            'vpnPolicy': (
                'manual VPN lifecycle independent of RemotePairing/RPCS3; '
                'read-only JIT route proof; /32 point-to-point provider; '
                'no provider self-cancel'
            ),
            'rpcS3HostPath': 'Build 273 reference',
            'onDemand': False,
            'dolphinAccountPreserved': True,
            'deviceTested': False,
            'ipaSHA256': hashlib.sha256(path.read_bytes()).hexdigest(),
        }

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('ipa', type=Path)
    parser.add_argument('--report', type=Path, required=True)
    args = parser.parse_args()
    result = verify(args.ipa)
    args.report.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))
