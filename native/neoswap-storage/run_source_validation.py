#!/usr/bin/env python3
"""Execute owned source admission, verified eviction, exact restoration and failures."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tempfile
from run_validation import execute
HERE=Path(__file__).resolve().parent;ROOT=HERE.parents[1]
sys.path.insert(0,str(ROOT/'build-utils'))
from validate_source_archive_evidence import REQUIRED_INPUTS,validate
def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--output',required=True,type=Path)
    args=parser.parse_args();out=args.output.resolve()
    if out==HERE or HERE in out.parents:raise SystemExit('Evidence must be outside canonical sources')
    out.mkdir(parents=True,exist_ok=True)
    compiler=shutil.which('clang++') or shutil.which('c++');cc=shutil.which('clang') or shutil.which('cc')
    if not compiler or not cc:raise SystemExit('Real C/C++ compilers required')
    apple=platform.system()=='Darwin';libraries=['-lcompression','-lz'] if apple else ['-llz4','-lz']
    version=subprocess.check_output([compiler,'--version'],text=True).splitlines()[0]
    common=[compiler,'-std=c++20','-pthread','-Wall','-Wextra','-Werror','-I',str(HERE),'-O1','-g',
            '-fsanitize=address,undefined','-fno-omit-frame-pointer','-DNEOSWAP_STORAGE_TESTING']
    legacy=[] if 'clang' in version.lower() else ['-Wno-error=misleading-indentation','-Wno-error=unused-result']
    report={'schema':1,'sourceCommit':os.environ.get('GITHUB_SHA'),'platform':platform.system(),'compiler':version,
            'physicalIPhoneValidated':False,'realRPCS3GameplayValidated':False,'kernelSwapPorted':False,
            'automaticGuestPagingActivated':False,'sanitizers':{'address':True,'undefined':True},
            'faultsAreInjected':True,'syntheticByteWorkloadNotRealGameplay':True}
    with tempfile.TemporaryDirectory(prefix='neoswap-source-proof-') as temp:
        work=Path(temp);cache=work/'cache';cache.mkdir();probe=work/'probe.c'
        probe.write_text('#include "SourceABI.h"\n_Static_assert(NEOSWAP_SOURCE_ABI==1,"source ABI");\nint main(void){return NS_SOURCE_OK;}\n')
        execute([cc,'-std=c11','-Wall','-Wextra','-Werror','-fsyntax-only','-I',str(HERE),str(probe)],out,'source-c11')
        report['c11HeaderVerified']=True
        store=work/'store.o'
        execute(common+legacy+['-c',str(HERE/'Store.cpp'),'-o',str(store)],out,'source-retained-store-build')
        exe=work/'source-test'
        execute(common+[str(HERE/name) for name in ('Metrics.cpp','ManagedSwap.cpp','SourceArchive.cpp','SourceClient.cpp')]+
                [str(store),str(HERE/'tests/source_archive_test.cpp')]+libraries+['-o',str(exe)],out,'source-archive-build')
        result=execute([str(exe),str(cache)],out,'source-archive-run')
        report['core']=json.loads(next(line for line in reversed(result.splitlines()) if line.startswith('{')))
        frames=work/'frame-test'
        execute(common+[str(HERE/name) for name in ('Metrics.cpp','ManagedSwap.cpp','SourceArchive.cpp','SourceClient.cpp')]+
                [str(store),str(HERE/'tests/frame_archive_test.cpp')]+libraries+['-o',str(frames)],out,'frame-archive-build')
        result=execute([str(frames),str(cache)],out,'frame-archive-run')
        report['frames']=json.loads(next(line for line in reversed(result.splitlines()) if line.startswith('{')))
        # Parse the actual sanitized real-file/scheduler executable output.
        # Hashing its sources alone is not evidence that the work was executed.
        result=execute([sys.executable,str(ROOT/'test/neoswap_source_work_test.py')],out,'source-work-run')
        report['sourceWork']=json.loads(next(line for line in reversed(result.splitlines()) if line.startswith('{')))
    report['inputSHA256']={path:hashlib.sha256((ROOT/path).read_bytes()).hexdigest() for path in sorted(REQUIRED_INPUTS)}
    report['passed']=True;validate(report,report['sourceCommit'],require_apple=apple)
    (out/'source-archive.json').write_text(json.dumps(report,indent=2)+'\n')
    print('PASS 64MiB owned GLSL and 63MiB synthetic pixel cycles, exact bytes and resumed throttled progress; no device/gameplay inference')
if __name__=='__main__':main()
