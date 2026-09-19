#!/usr/bin/env python3
"""Prove Build 285 did not change the final compiled VPN manager from Build 284."""
from __future__ import annotations
import argparse, json, subprocess, tempfile, zipfile
from pathlib import Path

def one_ipa(folder: Path) -> Path:
    items=sorted(folder.rglob('*.ipa'))
    if len(items)!=1:
        raise SystemExit(f'Expected one reference IPA in {folder}, found {len(items)}')
    return items[0]

def manager_bytes(ipa: Path) -> bytes:
    with zipfile.ZipFile(ipa) as z:
        infos=[n for n in z.namelist() if n.startswith('Payload/') and n.endswith('.app/Info.plist')]
        if len(infos)!=1:
            raise SystemExit('Expected one app Info.plist')
        app=infos[0][:-len('Info.plist')]
        return z.read(app+'Frameworks/stikjit_bridge.framework/stikjit_bridge')

def disassembly(data: bytes) -> str:
    with tempfile.NamedTemporaryFile(suffix='.macho') as f:
        f.write(data); f.flush()
        tool=subprocess.check_output(['xcrun','--find','llvm-objdump'],text=True).strip()
        out=subprocess.check_output([tool,'--macho','--disassemble',f.name],text=True,stderr=subprocess.STDOUT)
    return '\n'.join(out.splitlines()[1:])

def main():
    ap=argparse.ArgumentParser()
    ap.add_argument('--reference-dir',type=Path,required=True)
    ap.add_argument('--candidate',type=Path,required=True)
    ap.add_argument('--report',type=Path,required=True)
    args=ap.parse_args()

    ref=manager_bytes(one_ipa(args.reference_dir))
    cur=manager_bytes(args.candidate)
    if disassembly(ref)!=disassembly(cur):
        raise SystemExit('Build 285 changed VPN manager machine code from validated Build 284')

    report={'vpnManagerMachineCodeMatches284':True}
    args.report.parent.mkdir(parents=True,exist_ok=True)
    args.report.write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report,indent=2))
    print('PASS: Build 285 final VPN manager matches validated Build 284')

if __name__=='__main__':
    main()
