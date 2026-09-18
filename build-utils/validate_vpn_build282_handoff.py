#!/usr/bin/env python3
"""Verify Build 282's VPN handoff manager is unchanged in the final IPA."""
from __future__ import annotations
import argparse, json, plistlib, subprocess, tempfile, zipfile
from pathlib import Path

def one_ipa(folder: Path) -> Path:
    items = sorted(folder.rglob('*.ipa'))
    if len(items) != 1:
        raise SystemExit(f'Expected one IPA in {folder}, found {len(items)}')
    return items[0]

def manager_bytes(ipa: Path) -> bytes:
    with zipfile.ZipFile(ipa) as z:
        infos=[n for n in z.namelist() if n.startswith('Payload/') and n.endswith('.app/Info.plist')]
        if len(infos)!=1: raise SystemExit('Expected one app Info.plist')
        app=infos[0][:-len('Info.plist')]
        return z.read(app+'Frameworks/stikjit_bridge.framework/stikjit_bridge')

def disassembly(data: bytes) -> str:
    with tempfile.NamedTemporaryFile(suffix='.macho') as f:
        f.write(data); f.flush()
        tool=subprocess.check_output(['xcrun','--find','llvm-objdump'],text=True).strip()
        output=subprocess.check_output([tool,'--macho','--disassemble',f.name],text=True,stderr=subprocess.STDOUT)
    return '\n'.join(output.splitlines()[1:])

def main():
    ap=argparse.ArgumentParser()
    ap.add_argument('--reference-dir',type=Path,required=True)
    ap.add_argument('--candidate',type=Path,required=True)
    ap.add_argument('--report',type=Path,required=True)
    args=ap.parse_args()
    ref=manager_bytes(one_ipa(args.reference_dir))
    cur=manager_bytes(args.candidate)
    if disassembly(ref)!=disassembly(cur):
        raise SystemExit('Final IPA changed Build 282 VPN handoff manager machine code')
    # Exact machine-code equality with the device-improved Build 282 is the
    # authoritative handoff invariant. Private Swift function names are not an
    # ABI and can legitimately disappear from a release binary.
    report={'managerMachineCodeMatches282':True}
    args.report.write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report,indent=2))
    print('PASS: final VPN handoff manager matches device-improved Build 282')

if __name__=='__main__':
    main()
