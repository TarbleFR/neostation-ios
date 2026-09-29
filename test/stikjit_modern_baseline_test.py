#!/usr/bin/env python3
"""Keep modern RPCS3 protocol exactly baseline-identical, including known failures.

The historical stop-reply stress suite already fails on reordered/sparse replies.
Do not silently fix or weaken that modern protocol during an iOS 18-only patch.
"""
from pathlib import Path
import hashlib
import json
import subprocess
import tempfile

ROOT=Path(__file__).resolve().parents[1]
BASE='beed82be2a851d19c8cdada8d48b04da7f5f106c'
SCRIPT='packages/rpcs3_jit_helper/ios/Resources/rpcs3-universal.js'
TEST='test/rpcs3_stop_reply_behavior_test.js'

def original(file):
    return subprocess.check_output(['git','show',BASE+':'+file],cwd=ROOT)

assert original(SCRIPT).replace(b'\r\n',b'\n')==(ROOT/SCRIPT).read_bytes().replace(b'\r\n',b'\n')
assert original(TEST).replace(b'\r\n',b'\n')==(ROOT/TEST).read_bytes().replace(b'\r\n',b'\n')
with tempfile.TemporaryDirectory() as tmp:
    prior=Path(tmp)/'baseline.js'; prior.write_bytes(original(SCRIPT))
    before=subprocess.run(['node',TEST,str(prior)],cwd=ROOT,text=True,capture_output=True)
    after=subprocess.run(['node',TEST,SCRIPT],cwd=ROOT,text=True,capture_output=True)
    assert (before.returncode,before.stdout,before.stderr)==(after.returncode,after.stdout,after.stderr)
    report={'baseline':BASE,'identicalModernScript':True,
            'scriptSha256':hashlib.sha256(original(SCRIPT)).hexdigest(),
            'baselineExitCode':before.returncode,'candidateExitCode':after.returncode,
            'knownBaselineStressFailure':before.returncode!=0,
            'stdout':after.stdout,'stderr':after.stderr}
    out=ROOT/'build/stikjit-tests/modern-baseline.json'; out.parent.mkdir(parents=True,exist_ok=True)
    out.write_text(json.dumps(report,indent=2)+'\n')
    print('PASS: exact modern script and identical baseline/candidate stress outcomes')
    if before.returncode:
        print('::warning::Historical modern stop-reply stress failures remain unchanged; they are NOT counted as passing device or stress tests.')
