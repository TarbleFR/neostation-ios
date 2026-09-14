#!/usr/bin/env python3
"""Apply Build 265 after the pinned Build 264 patches; fail closed on drift."""
from pathlib import Path
import subprocess
import sys


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit('usage: patch_rpcs3_build265_core.py <rpcs3-source-root>')
    source = Path(sys.argv[1]).resolve()
    patch = Path(__file__).resolve().parent / 'patches/rpcs3_build265_core.patch'
    def run(*args: str) -> subprocess.CompletedProcess:
        return subprocess.run(['git', '-C', str(source), 'apply', *args, str(patch)],
                              capture_output=True, text=True)
    if run('--reverse', '--check').returncode == 0:
        print('RPCS3 Build 265 core patch already applied')
        return
    check = run('--check')
    if check.returncode:
        raise SystemExit('Build 265 refuses an unexpected/partial source tree:\n' + check.stderr)
    applied = run()
    if applied.returncode:
        raise SystemExit(applied.stderr)
    print('RPCS3 Build 265 RSX/SPU/video patch applied')

if __name__ == '__main__':
    main()
