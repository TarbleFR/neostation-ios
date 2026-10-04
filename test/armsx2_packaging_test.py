#!/usr/bin/env python3
"""Exercise both production IPA identity guards against an actual Core artifact.

Checks stale ABI/host/hash rejection, missing resources and donor-ledger replacement.
Does not execute the iOS framework or establish physical-device compatibility.
"""
from pathlib import Path
import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import textwrap
import zipfile

ROOT=Path(__file__).resolve().parents[1]
parser=argparse.ArgumentParser(description=__doc__)
inputs=parser.add_mutually_exclusive_group(required=True)
inputs.add_argument('--archive',type=Path)
inputs.add_argument('--core-directory',type=Path)
args=parser.parse_args()
with tempfile.TemporaryDirectory(prefix='armsx2-packaging-') as directory:
    workspace=Path(directory)
    core=workspace/'dist/armsx2'
    if args.archive:
        core.mkdir(parents=True)
        with zipfile.ZipFile(args.archive) as archive:
            assert all(not Path(name).is_absolute() and '..' not in Path(name).parts for name in archive.namelist())
            archive.extractall(core)
    else:
        shutil.copytree(args.core_directory,core,symlinks=True)
    identity_path=core/'identity.json'
    identity=json.loads(identity_path.read_text())
    source=workspace/'build-utils/armsx2/source.json'
    source.parent.mkdir(parents=True)
    source.write_bytes((ROOT/'build-utils/armsx2/source.json').read_bytes())
    ledger=workspace/'build/fast-native/identity.json'
    ledger.parent.mkdir(parents=True)
    for name in ('ios-ci.yml','neoswap-ipa.yml'):
        workflow=(ROOT/'.github/workflows'/name).read_text()
        verify=workflow.split('      - name: Verify pinned ARMSX2 Core identity\n',1)[1]
        program=textwrap.dedent(verify.split("          python3 - <<'PY'\n",1)[1].split('\n          PY',1)[0])
        environment=os.environ.copy()
        environment['ARMSX2_CORE_HOST_SHA']=re.search(r'(?m)^      ARMSX2_CORE_HOST_SHA: ([0-9a-f]{40})$',workflow)[1]
        environment['ARMSX2_CORE_RUN_ID']=re.search(r"(?m)^      ARMSX2_CORE_RUN_ID: '([0-9]+)'$",workflow)[1]
        previous={'armsx2CoreSha256':'donor-bootstrap','dolphinCoreSha256':'preserve-dolphin','rpcs3CoreSha256':'preserve-rpcs3'}
        ledger.write_text(json.dumps(previous))
        def execute():
            return subprocess.run([sys.executable,'-c',program],cwd=workspace,env=environment,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        result=execute()
        assert result.returncode==0,result.stderr
        assert (core/'ARMSX2Core.framework/ARMSX2Core').stat().st_mode & 0o777 == 0o755
        final=json.loads(ledger.read_text())
        assert final['armsx2CoreSha256']==identity['sha256']
        assert final['armsx2CoreHostCommit']==identity['host_commit']
        assert final['armsx2CoreRunId']==int(environment['ARMSX2_CORE_RUN_ID'])
        for key in ('dolphinCoreSha256','rpcs3CoreSha256'):assert final[key]==previous[key]
        for field,value in [('abi_version',5),('host_commit','0'*40),('sha256','0'*64)]:
            wrong=dict(identity);wrong[field]=value
            identity_path.write_text(json.dumps(wrong))
            assert execute().returncode!=0,'Accepted mismatched '+field
        identity_path.write_text(json.dumps(identity))
        # Reproduce omission of any sealed resource during artifact transport.
        relative=next(iter(identity['bundled_shader_sha256']))
        asset=core/'ARMSX2Core.framework/shaders'/relative
        original=asset.read_bytes();asset.unlink()
        assert execute().returncode!=0,'Accepted missing shader asset'
        asset.write_bytes(original)
        assert execute().returncode==0
        print('PASS: actual artifact; stale ABI/host/hash and missing resource rejected; donor ledger replaced:',name)
