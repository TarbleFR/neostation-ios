#!/usr/bin/env python3
"""Actual Store/archive files plus deterministic host scheduler ordering."""
from pathlib import Path
import os
import platform
import shutil
import subprocess
import tempfile
ROOT=Path(__file__).resolve().parents[1]
HERE=ROOT/'native/neoswap-storage'
compiler=shutil.which('clang++') or shutil.which('c++')
assert compiler,'A real C++ compiler is required'
version=subprocess.check_output([compiler,'--version'],text=True)
common=[compiler,'-std=c++20','-pthread','-Wall','-Wextra','-Werror','-O1','-g',
    '-fsanitize=address,undefined','-fno-omit-frame-pointer','-I',str(HERE)]
libraries=['-lcompression','-lz'] if platform.system()=='Darwin' else ['-llz4','-lz']
if platform.system()!='Darwin':
    include=os.environ.get('NEOSWAP_TEST_LZ4_INCLUDE')
    if include:common+=['-I',include]
    library=os.environ.get('NEOSWAP_TEST_LZ4_LIBRARY')
    if library:libraries=[library,'-lz']
legacy=[] if 'clang' in version.lower() else ['-Wno-error=misleading-indentation','-Wno-error=unused-result']
with tempfile.TemporaryDirectory(prefix='neoswap-source-work-') as temp:
    work=Path(temp);cache=work/'cache';cache.mkdir();store=work/'store.o';binary=work/'source-work'
    subprocess.run(common+legacy+['-c',str(HERE/'Store.cpp'),'-o',str(store)],check=True)
    subprocess.run(common+[str(HERE/p) for p in ('Metrics.cpp','ManagedSwap.cpp','SourceArchive.cpp')]+
        [str(store),str(HERE/'tests/source_work_test.cpp')]+libraries+['-o',str(binary)],check=True)
    subprocess.run([str(binary),str(cache)],check=True)
