#!/usr/bin/env python3
"""One-time Build302 consolidation. Not part of any runtime/build pipeline.

The reviewed host/Core deltas are losslessly packed for connector transfer.
Verify both the transfer SHA and each git preimage before applying them. CI
exports the decoded diffs for review and deletes this migration after commit.
"""
import base64
import hashlib
import json
import lzma
import os
import subprocess
import tarfile
from pathlib import Path

root = Path(__file__).resolve().parents[2]
parts = root / 'build-utils/migrations/build302'
packed = base64.b64decode(''.join((parts / f'part{i}.b64').read_text().strip() for i in range(4)), validate=True)
assert hashlib.sha256(packed).hexdigest() == '9cc4a8634ee3a37e06d8a991e89aea38b1d46bd9728581ebd844eb64e064b41e', 'Transfer checksum mismatch'
raw = lzma.decompress(packed)
assert hashlib.sha256(raw).hexdigest() == '130c0b98e08ff865297b5efaab9e291c8c2a619dc49e2bed7a06d2b66531cf41', 'Decoded source checksum mismatch'
payload = json.loads(raw)
out = Path(os.environ['RUNNER_TEMP']) / 'build302-review'
out.mkdir(parents=True, exist_ok=True)
for name, content in payload.items():
    (out / f'{name}.patch').write_text(content)

source = Path(os.environ['RUNNER_TEMP']) / 'build302-core-source'
upstream = '22f1152783cef1f7e04af7b1c895173e28fd5b03'
def run(*args, cwd=root):
    subprocess.run(list(args), cwd=cwd, check=True)
run('git', 'init', '-q', str(source))
run('git', 'remote', 'add', 'origin', 'https://github.com/XITRIX/rpcs3.git', cwd=source)
run('git', 'fetch', '--depth', '1', 'origin', upstream, cwd=source)
run('git', 'checkout', '-q', '--detach', 'FETCH_HEAD', cwd=source)
assert subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=source, text=True).strip() == upstream
# Exact Build301 postimage produced by successful snapshot run35636317891.
snapshot = root / 'build/source-snapshot'
assert (snapshot / 'HOST_SHA.txt').read_text().strip() == '37d226ae9e8f222f91631fff5e49015922d71e1d'
with tarfile.open(snapshot / 'core.tar.gz', 'r:gz') as archive:
    archive.extractall(source, filter='data')
run('git', 'apply', '--check', str(out / 'core.patch'), cwd=source)
run('git', 'apply', str(out / 'core.patch'), cwd=source)
run('git', 'apply', '--check', str(out / 'host.patch'))
run('git', 'apply', str(out / 'host.patch'))

# Include historically untracked added files, not only the tracked git diff.
run('git', 'add', '-A', cwd=source)
canonical = subprocess.check_output(['git', 'diff', '--cached', '--binary', upstream], cwd=source)
path = root / 'build-utils/rpcs3/embedded-core.patch'
path.write_bytes(canonical)
names = subprocess.check_output(['git', 'diff', '--cached', '--name-only', '--diff-filter=ACMRT', upstream], cwd=source, text=True).splitlines()
manifest = {
    'schema_version': 1,
    'upstream_repository': 'XITRIX/rpcs3',
    'upstream_commit': upstream,
    'historical_host_postimage': 'b2ecb702a426664236b51e4d0556d4e428e6425a',
    'patch_sha256': hashlib.sha256(canonical).hexdigest(),
    'files_sha256': {name: hashlib.sha256((source / name).read_bytes()).hexdigest() for name in names},
    'memory_policy': {'code_bytes': 469762048, 'data_bytes': 603979776, 'budget_bytes': 1073741824},
    'device_runtime_tested': False,
}
(root / 'build-utils/rpcs3/canonical-source.json').write_text(json.dumps(manifest, indent=2, sort_keys=True) + '\n')
(out / 'canonical-source.json').write_text(json.dumps(manifest, indent=2, sort_keys=True) + '\n')
print('Canonical source delta:', len(canonical), 'bytes;', len(names), 'changed/added files')
run('python3', 'test/rpcs3_reserved_startup_core_test.py', str(source))
# Prove the new single-delta materializer reproduces the same source hashes.
run('git', 'reset', '--hard', upstream, cwd=source)
run('git', 'clean', '-fd', cwd=source)
run('python3', 'build-utils/materialize_rpcs3_core.py', str(source))
run('python3', 'test/rpcs3_reserved_startup_core_test.py', str(source))
run('git', 'diff', '--check')
print('PASS: exact transfer, checked preimages, canonical reconstruction and actual lifecycle behavior')
