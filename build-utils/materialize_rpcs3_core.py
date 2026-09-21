#!/usr/bin/env python3
"""Materialize one hash-locked canonical Core delta, not a historical patch chain."""
import hashlib, json, subprocess, sys
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
source=Path(sys.argv[1]).resolve()
manifest=json.loads((ROOT/'build-utils/rpcs3/canonical-source.json').read_text())
patch=ROOT/'build-utils/rpcs3/embedded-core.patch'
assert hashlib.sha256(patch.read_bytes()).hexdigest()==manifest['patch_sha256'], 'Canonical delta checksum mismatch'
head=subprocess.check_output(['git','-C',str(source),'rev-parse','HEAD'],text=True).strip()
assert head==manifest['upstream_commit'], 'RPCS3 source revision mismatch'
subprocess.run(['git','-C',str(source),'apply','--check',str(patch)],check=True)
subprocess.run(['git','-C',str(source),'apply',str(patch)],check=True)
for relative,expected in manifest['files_sha256'].items():
    assert hashlib.sha256((source/relative).read_bytes()).hexdigest()==expected, f'Canonical source mismatch: {relative}'
print('PASS: single canonical RPCS3 delta, all postimage hashes verified')

import re
host=(ROOT/'packages/rpcs3_internal_bridge/ios/Classes/Rpcs3InternalBridgePlugin.mm').read_text()
needed={'_'+name for name in re.findall(r'LOAD\("([^"]+)"', host)}
needed.add('_rpcs3_ios_run_llvm_self_test')
exports=set((source/'rpcs3/ios/RPCS3IOS.exports').read_text().splitlines())
assert needed <= exports, 'Core link exports missing: '+str(sorted(needed-exports))
print('PASS static link contract: all host-loaded Core functions are exported')
