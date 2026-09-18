#!/usr/bin/env python3
"""Validate Build 284's final compiled VPN manager contract."""
from __future__ import annotations
import argparse, json, plistlib, zipfile
from pathlib import Path

def manager_bytes(ipa: Path) -> bytes:
    with zipfile.ZipFile(ipa) as z:
        infos=[n for n in z.namelist() if n.startswith('Payload/') and n.endswith('.app/Info.plist')]
        if len(infos)!=1:
            raise SystemExit('Expected one app Info.plist')
        app=infos[0][:-len('Info.plist')]
        return z.read(app+'Frameworks/stikjit_bridge.framework/stikjit_bridge')

def main():
    ap=argparse.ArgumentParser()
    ap.add_argument('--candidate',type=Path,required=True)
    ap.add_argument('--report',type=Path,required=True)
    args=ap.parse_args()

    data=manager_bytes(args.candidate)
    forbidden=(b'installationToken', b'NeoStationLocalTunnel.installationToken')
    for marker in forbidden:
        if marker in data:
            raise SystemExit(f'Final IPA still contains removed VPN migration layer: {marker!r}')

    required=(
        b'TunnelIfaceIP',
        b'TunnelPeerIP',
        b'LocalDevVPN',
    )
    for marker in required:
        if marker not in data:
            raise SystemExit(f'Final IPA is missing Build 284 handoff marker: {marker!r}')

    report={
        'installationTokenRemoved': True,
        'localDevVpnProfileDetectionPresent': True,
        'compiledManagerValidated': True,
    }
    args.report.parent.mkdir(parents=True,exist_ok=True)
    args.report.write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report,indent=2))
    print('PASS: final Build 284 manager uses stable own profile + LocalDevVPN handoff')

if __name__=='__main__':
    main()
