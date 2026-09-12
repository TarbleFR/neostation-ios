#!/usr/bin/env python3
"""Compile and execute actual patched serialization methods with portable adapters.

The production queue/thread/file wrappers are replaced for portability. Real ZSTD
from the pinned submodule is compiled on both macOS and Linux, with no dependency
on a system ZSTD package. Full RPCS3/iOS compilation remains a separate CI gate.
"""
from pathlib import Path
import os
import re
import subprocess
import sys
import tempfile

repo = Path(__file__).resolve().parents[1]
core = Path(sys.argv[1]).resolve()
cpp = (core / 'rpcs3/util/serialization_ext.cpp').read_text()
hpp = (core / 'rpcs3/util/serialization_ext.hpp').read_text()
assert 'NEOSTATION_SAVESTATE_IO_V1' in cpp
start = hpp.index('struct compressed_zstd_serialization_file_handler :')
declaration = hpp[start:hpp.index('\n};', start) + 3]
start = cpp.index('struct compressed_zstd_stream_data :')
methods = cpp[start:cpp.index('\nbool null_serialization_file_handler::', start)]
harness = (repo / 'test/native/rpcs3_savestate_harness.cpp').read_text()
source = harness.replace('// INSERT_PRODUCTION_SERIALIZATION',
                         'struct compressed_zstd_stream_data;\n' + declaration + '\n' + methods)
zstd = core / '3rdparty/zstd/zstd/lib'
assert (zstd / 'zstd.h').is_file(), 'Initialize pinned zstd submodule first'
with tempfile.TemporaryDirectory(prefix='neostation-savestate-test-') as tmp:
    tmp = Path(tmp)
    (tmp / 'harness.cpp').write_text(source)
    objects = []
    for file in sorted(zstd.glob('*/*.c')):
        if file.parent.name not in ('common', 'compress', 'decompress'):
            continue
        obj = tmp / (file.stem + '.o')
        subprocess.run([os.environ.get('HOST_CC', 'cc'), '-O2', '-DZSTD_DISABLE_ASM',
                        '-I' + str(zstd), '-c', str(file), '-o', str(obj)], check=True)
        objects.append(str(obj))
    subprocess.run([os.environ.get('HOST_CXX', 'c++'), '-std=c++20', '-O2', '-pthread',
                    '-DRPCS3_IOS', '-I' + str(zstd), '-I' + str(repo / 'build-utils/rpcs3'),
                    str(tmp / 'harness.cpp'), *objects, '-o', str(tmp / 'test')], check=True)
    # A worker-drain deadlock is a failure, never an indefinite CI wait.
    subprocess.run([str(tmp / 'test')], check=True, timeout=45)

api = (core / 'rpcs3/ios/RPCS3IOS.cpp').read_text()
system = (core / 'rpcs3/Emu/System.cpp').read_text()
assert api.count('NEOSTATION_SAVE_EXCLUSIVE') == 3
assert 'if (!neostation::savestate::current.read().committed)' in api
assert 'if (owns_operation)' in api
assert 'std::make_shared<std::atomic_bool>(false)' in system
assert system.index('ar.m_file_handler->finalize(ar);') < system.index('if (!file.commit()')
assert system.index('if (!ar.m_file_handler->is_valid())') < system.index('if (!file.commit()')
assert 'savestate = false; // Joined before' in system
assert 'NEOSTATION_SAVE_RECOVERABLE_IO_V1' in cpp
assert system.index('if (!file.commit()') < system.index('current.record_write(savestate)')
assert 'current.finish(false,' in system
assert '_neostation_rpcs3_ios_get_savestate_status' in (core / 'rpcs3/ios/RPCS3IOS.exports').read_text()
print('PASS: savestate transaction integration contracts')
