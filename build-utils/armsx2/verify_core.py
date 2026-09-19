#!/usr/bin/env python3
"""Validate the compiled framework; never mistake an app executable for a core."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

root = Path(__file__).resolve().parents[2]
build, output = map(Path, sys.argv[1:3])
candidates = [p for p in build.rglob('ARMSX2Core.framework')
              if (p / 'ARMSX2Core').is_file() and 'Release-iphoneos' in str(p)]
if len(candidates) != 1:
    raise SystemExit(f'Expected one device framework, found: {candidates}')
framework = candidates[0]
binary = framework / 'ARMSX2Core'
binary_bytes = binary.read_bytes()
for forbidden in (b'/Users/runner/', b'/Users/builder/'):
    if forbidden in binary_bytes:
        raise SystemExit(f'Absolute CI path leaked into ARMSX2 Core: {forbidden!r}')
def run(*args):
    return subprocess.check_output(args, text=True)
if run('lipo', '-archs', str(binary)).strip() != 'arm64':
    raise SystemExit('Core architecture is not exactly arm64')
if 'DYLIB' not in run('otool', '-hv', str(binary)):
    raise SystemExit('Core is not MH_DYLIB')
exports = set(run('nm', '-gUj', str(binary)).splitlines())
if exports != {'_NeoARMSX2_GetAPI'}:
    raise SystemExit(f'Unexpected exported ABI: {sorted(exports)}')
for line in run('otool', '-L', str(binary)).splitlines()[1:]:
    library = line.strip().split(' ', 1)[0]
    if library == '@rpath/ARMSX2Core.framework/ARMSX2Core':
        continue
    if not library.startswith(('/usr/lib/', '/System/Library/')):
        raise SystemExit(f'Non-system runtime dependency: {library}')
resources = framework
for required in ('default.metallib', 'GameIndex.yaml', 'game_controller_db.txt'):
    if not (resources / required).is_file():
        raise SystemExit(f'Missing framework resource: {required}')
subprocess.run(['codesign', '--force', '--sign', '-', str(framework)], check=True)
subprocess.run(['codesign', '--verify', '--strict', str(framework)], check=True)
output.mkdir(parents=True, exist_ok=True)
destination = output / framework.name
if destination.exists(): shutil.rmtree(destination)
subprocess.run(['ditto', str(framework), str(destination)], check=True)
identity = json.loads((root / 'build-utils/armsx2/source.json').read_text())
identity.update(host_commit=os.environ.get('GITHUB_SHA', ''),
                sha256=hashlib.sha256((destination/'ARMSX2Core').read_bytes()).hexdigest(),
                architectures=['arm64'], signature='ad-hoc; sideloading must re-sign',
                shader_chains=False, device_runtime_tested=False)
(output / 'identity.json').write_text(json.dumps(identity, indent=2)+'\n')
print(json.dumps(identity, indent=2))
