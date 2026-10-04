#!/usr/bin/env python3
"""Stamp a generated research app; the profile is immutable until process exit."""
import argparse
from pathlib import Path
import plistlib
import subprocess

MODES = ('baseline', 'relay', 'integrated')


def configure(path: Path, mode: str, source: str) -> None:
    if mode not in MODES:
        raise ValueError('Unknown NeoSwap research profile')
    if len(source) != 40 or any(c not in '0123456789abcdef' for c in source):
        raise ValueError('Exact source commit required')
    value = plistlib.loads(path.read_bytes())
    value['NeoSwapResearchMode'] = mode
    value['NeoSwapResearchSource'] = source
    path.write_bytes(plistlib.dumps(value, sort_keys=False))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--mode', choices=MODES, required=True)
    parser.add_argument('--plist', type=Path, default=Path('ios/Runner/Info.plist'))
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    branch = subprocess.check_output(['git', 'branch', '--show-current'], cwd=root, text=True).strip()
    if branch != 'swap':
        raise SystemExit('Research packaging is restricted to branch swap')
    source = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip()
    configure(args.plist, args.mode, source)
    print(f'NeoSwap research profile: {args.mode}; source: {source}')
