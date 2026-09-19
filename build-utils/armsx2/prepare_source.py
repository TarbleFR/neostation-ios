#!/usr/bin/env python3
"""Prepare one pinned upstream checkout, without changing NeoStation sources."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

HERE = Path(__file__).resolve().parent

def validate_files(source: Path) -> None:
    for relative, expected in json.loads((HERE / 'upstream-files.json').read_text()).items():
        path = source / relative
        if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != expected:
            raise RuntimeError(f'Upstream API changed: {relative}; rebase and test the adapter before building.')

def prepare(source: Path) -> None:
    pin = json.loads((HERE / 'source.json').read_text())
    actual = subprocess.check_output(['git', '-C', str(source), 'rev-parse', 'HEAD'], text=True).strip()
    if actual != pin['revision']:
        raise RuntimeError(f'Expected {pin["revision"]}, got {actual}')
    subprocess.run(['git', '-C', str(source), 'diff', '--exit-code'], check=True)
    validate_files(source)
    patch = str(HERE / 'neostation-core.patch')
    subprocess.run(['git', 'apply', '--check', patch], cwd=source, check=True)
    subprocess.run(['git', 'apply', patch], cwd=source, check=True)

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('source', type=Path)
    prepare(parser.parse_args().source.resolve())
