#!/usr/bin/env python3
"""Compare the final VPN artifact against device-validated Build 279."""

from __future__ import annotations

import argparse
import json
import plistlib
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'build-utils'))
from embed_rpcs3_host_entitlements import embedded_entitlements


def one_ipa(folder: Path) -> Path:
    candidates = sorted(folder.rglob('*.ipa'))
    if len(candidates) != 1:
        raise SystemExit(f'Expected exactly one reference IPA, found {len(candidates)} in {folder}')
    return candidates[0]


def members(ipa: Path) -> dict[str, bytes]:
    with zipfile.ZipFile(ipa) as z:
        names = z.namelist()
        infos = [n for n in names if n.startswith('Payload/') and n.endswith('.app/Info.plist')]
        if len(infos) != 1:
            raise SystemExit(f'Expected one app Info.plist in {ipa}')
        app = infos[0][:-len('Info.plist')]
        info = plistlib.loads(z.read(app + 'Info.plist'))
        host = app + info['CFBundleExecutable']
        tunnel_info_name = app + 'PlugIns/NeoStationLocalTunnel.appex/Info.plist'
        tunnel_info = plistlib.loads(z.read(tunnel_info_name))
        tunnel = app + 'PlugIns/NeoStationLocalTunnel.appex/' + tunnel_info['CFBundleExecutable']
        manager = app + 'Frameworks/stikjit_bridge.framework/stikjit_bridge'
        return {
            'host': z.read(host),
            'host_info': z.read(app + 'Info.plist'),
            'tunnel': z.read(tunnel),
            'tunnel_info': z.read(tunnel_info_name),
            'manager': z.read(manager),
        }


def disassembly(binary: bytes) -> str:
    with tempfile.NamedTemporaryFile(suffix='.macho') as f:
        f.write(binary)
        f.flush()
        tool = subprocess.check_output(['xcrun', '--find', 'llvm-objdump'], text=True).strip()
        output = subprocess.check_output(
            [tool, '--macho', '--disassemble', f.name],
            text=True,
            stderr=subprocess.STDOUT,
        )
    lines = output.splitlines()
    # llvm-objdump prints the temporary path on line 1. Everything after it is
    # actual machine-code disassembly and must stay identical to Build 279.
    return '\n'.join(lines[1:])


def normalized_tunnel_info(raw: bytes) -> dict:
    info = plistlib.loads(raw)
    info.pop('CFBundleVersion', None)
    return info


def validate(reference: Path, candidate: Path) -> dict:
    ref = members(reference)
    cur = members(candidate)

    if disassembly(ref['tunnel']) != disassembly(cur['tunnel']):
        raise SystemExit('Final IPA changed NeoStationLocalTunnel machine code from validated Build 279')

    if normalized_tunnel_info(ref['tunnel_info']) != normalized_tunnel_info(cur['tunnel_info']):
        raise SystemExit('Final IPA changed NeoStationLocalTunnel Info.plist beyond CFBundleVersion')

    ref_tunnel_entitlements = embedded_entitlements(ref['tunnel'])
    cur_tunnel_entitlements = embedded_entitlements(cur['tunnel'])
    if ref_tunnel_entitlements != cur_tunnel_entitlements:
        raise SystemExit('Final IPA changed NeoStationLocalTunnel entitlements from Build 279')

    ref_host_entitlements = embedded_entitlements(ref['host'])
    cur_host_entitlements = embedded_entitlements(cur['host'])
    if ref_host_entitlements != cur_host_entitlements:
        raise SystemExit('Final IPA changed host entitlements from Build 279')

    return {
        'referenceIPA': reference.name,
        'candidateIPA': candidate.name,
        'providerMachineCodeMatches279': True,
        'providerInfoMatches279ExceptBuild': True,
        'providerEntitlementsMatch279': True,
        'hostEntitlementsMatch279': True,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--reference-dir', type=Path, required=True)
    parser.add_argument('--candidate', type=Path, required=True)
    parser.add_argument('--report', type=Path, required=True)
    args = parser.parse_args()

    result = validate(one_ipa(args.reference_dir), args.candidate)
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))
    print('PASS: final VPN artifact matches validated Build 279 provider contract')


if __name__ == '__main__':
    main()
