"""Collect only production fixtures explicitly emitted by this XCTest run."""
from pathlib import Path
import hashlib
import json
import os
import shutil

root = Path('build/neoplay-native')
log = (root / 'build.log').read_text(encoding='utf-8')
prefix = 'NEOPLAY_FIXTURE_PATH:'
directories = {Path(line.split(prefix, 1)[1].strip()).resolve() for line in log.splitlines() if prefix in line}
allowed = (Path.home() / 'Library/Developer/CoreSimulator/Devices').resolve()
output = root / 'fixtures'
output.mkdir(parents=True, exist_ok=True)
manifest = {'commit': os.environ['GITHUB_SHA'], 'files': {}}
for directory in directories:
    if not directory.is_relative_to(allowed) or directory.name != 'NeoPlayFixtures':
        raise ValueError('Unexpected fixture path')
    for name in ('windows.json', 'windows.mp4', 'chromecast.json', 'chromecast.mp4', 'frames.json', 'frames-manifest.json'):
        source = directory / name
        if not source.is_file():
            continue
        digest = hashlib.sha256(source.read_bytes()).hexdigest()
        if name in manifest['files'] and manifest['files'][name] != digest:
            raise ValueError('Conflicting fixtures for ' + name)
        shutil.copyfile(source, output / name)
        manifest['files'][name] = digest
assert {'windows.json', 'windows.mp4', 'chromecast.json', 'chromecast.mp4', 'frames.json', 'frames-manifest.json'} <= set(manifest['files']), manifest
frames_manifest = json.loads((output / 'frames-manifest.json').read_text(encoding='utf-8'))
assert frames_manifest == {'schema': 1, 'noFrameReordering': True, 'fixtureSha256': manifest['files']['frames.json']}, frames_manifest
(output / 'manifest.json').write_text(json.dumps(manifest, indent=2), encoding='utf-8')
print(json.dumps(manifest))
