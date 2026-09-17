#!/usr/bin/env python3
"""Verify retained core fixes, Dolphin account flow and Build 268 JIT transport.

This supplements validate_rpcs3_ipa.py's Mach-O, dependency, entitlement and
package checks. Binary identity checks are not on-device execution tests.
"""
from __future__ import annotations
import argparse
import hashlib
import json
import plistlib
import zipfile
from pathlib import Path

CORE_MARKERS = (
    b'NEOSTATION_BUILD266_JIT_V09_SHADER_V1', b'NEOSTATION_DYNAMIC_JIT_V5',
    b'NEOSTATION_BUILD266_SHADER_CHECKPOINT_V1',
    b'505a85e5a8f2cdff1cd63168bd2c56b0f92282bf',
)
PROVIDER_MARKER = b'Local tunnel startup was cancelled by a newer stop.'
MANAGER_MARKERS = (b'iOS supplied no disconnect error', b'localtunnel.heartbeat')
DOLPHIN_ACCOUNT_MARKERS = (b'DolphinRetroAchievementsAccount', b'loginRequestForUsername:password:',
                           b'emulator-player', b'raRestartRequired')
LEASE_PROVIDER_MARKERS = (b'jitLeaseBegin', b'jitLeaseEnd',
                          b'RPCS3 debugger lease armed; watchdog remains bounded.')
LEASE_MANAGER_MARKERS = (b'beginDebuggerLease', b'endDebuggerLease',
                         b'RPCS3 debugger lease acknowledgement timed out.')


def validate(path: Path, build_number: str = '266') -> dict:
    def require(value: bool, detail: str) -> None:
        if not value:
            raise ValueError(detail)
    with zipfile.ZipFile(path) as archive:
        names = archive.namelist()
        hosts = [n for n in names if n.startswith('Payload/') and n.count('/') == 2
                 and n.endswith('.app/Info.plist')]
        require(len(hosts) == 1, 'Expected one app plist')
        info = plistlib.loads(archive.read(hosts[0]))
        require(str(info.get('CFBundleVersion')) == str(build_number), f'Wrong Build {build_number} version')
        app = hosts[0][:-len('Info.plist')]
        core = archive.read(app + 'Frameworks/libRPCS3Core.dylib')
        require(all(marker in core for marker in CORE_MARKERS), 'Final core lacks Build 266 backport/shader markers')
        tunnel = app + 'PlugIns/NeoStationLocalTunnel.appex/'
        tunnel_info = plistlib.loads(archive.read(tunnel + 'Info.plist'))
        provider = archive.read(tunnel + tunnel_info['CFBundleExecutable'])
        require(PROVIDER_MARKER in provider, 'Final extension lacks stop-generation fix')
        host_binaries = [app + info['CFBundleExecutable']]
        host_binaries += [n for n in names if n.startswith(app + 'Frameworks/') and
                          '.framework/' in n and n.rsplit('/', 1)[1] == n.split('.framework/')[0].rsplit('/', 1)[1]]
        owner = None
        account_owner = None
        lease_owner = None
        for name in host_binaries:
            data = archive.read(name)
            if all(marker in data for marker in MANAGER_MARKERS):
                owner = name
            if all(marker in data for marker in DOLPHIN_ACCOUNT_MARKERS):
                account_owner = name
            if all(marker in data for marker in LEASE_MANAGER_MARKERS):
                lease_owner = name
        require(owner is not None, 'Final host lacks bounded disconnect diagnostics/dedicated heartbeat')
        if str(build_number) in ('267', '268'):
            require(account_owner is not None, 'Final Dolphin bridge lacks the Build 267 account flow')
        if str(build_number) == '268':
            require(all(marker in provider for marker in LEASE_PROVIDER_MARKERS),
                    'Final provider lacks the Build 268 debugger lease')
            require(lease_owner is not None, 'Final host lacks the Build 268 lease handshake')
        return {
            'build': str(build_number), 'coreMarkersVerified': [m.decode() for m in CORE_MARKERS],
            'coreSHA256': hashlib.sha256(core).hexdigest(),
            'providerSHA256': hashlib.sha256(provider).hexdigest(),
            'managerBinary': owner, 'dolphinAccountBinary': account_owner,
            'debuggerLeaseBinary': lease_owner, 'deviceTested': False,
        }


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('ipa', type=Path)
    parser.add_argument('--build-number', default='266')
    parser.add_argument('--report', type=Path, required=True)
    args = parser.parse_args()
    report = validate(args.ipa, args.build_number)
    args.report.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))
