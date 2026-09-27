#!/usr/bin/env python3
"""Apply the pinned AArch64 GHC spill fix to the pinned LLVM submodule."""
import argparse
import hashlib
import json
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
manifest = json.loads((ROOT / 'build-utils/rpcs3/canonical-source.json').read_text())
patch = ROOT / 'build-utils/rpcs3/llvm-aarch64-ghc-emergency-spill.patch'


def git(source: Path, *args: str) -> str:
    return subprocess.check_output(['git', '-C', str(source), *args], text=True).strip()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument('source', type=Path, help='materialized RPCS3 checkout')
    parser.add_argument('--verify-only', action='store_true')
    args = parser.parse_args()
    source = args.source.resolve()
    llvm = source / '3rdparty/llvm/llvm'
    target = llvm / 'llvm/lib/Target/AArch64/AArch64FrameLowering.cpp'
    expected = manifest['llvm_aarch64_ghc_patch']
    assert hashlib.sha256(patch.read_bytes()).hexdigest() == expected['patch_sha256']
    assert git(source, 'rev-parse', 'HEAD') == manifest['upstream_commit']
    assert git(llvm, 'rev-parse', 'HEAD') == expected['llvm_commit']
    assert hashlib.sha256(target.read_bytes()).hexdigest() == expected['preimage_sha256']
    subprocess.run(['git', '-C', str(llvm), 'apply', '--unidiff-zero', '--check', str(patch)], check=True)
    if not args.verify_only:
        subprocess.run(['git', '-C', str(llvm), 'apply', '--unidiff-zero', str(patch)], check=True)
        assert hashlib.sha256(target.read_bytes()).hexdigest() == expected['postimage_sha256']
    print('PASS: pinned LLVM AArch64 GHC spill fix ' + ('verified' if args.verify_only else 'applied'))


if __name__ == '__main__':
    main()
