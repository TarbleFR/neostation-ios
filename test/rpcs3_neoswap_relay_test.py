#!/usr/bin/env python3
"""Execute the canonical utils::shm implementation with a real mmap test relay.

The host vtable is a controlled fixture; all shm constructors/map/map_self/
unmap_critical/destructor code and the relay client are the production sources.
This is an alias/lifecycle test, not proof of iPhone residency or donor handoff.
"""
import argparse
import os
import re
from pathlib import Path
import shlex
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('source', type=Path)
args = parser.parse_args()
source = args.source.resolve()
here = Path(__file__).resolve().parent
with tempfile.TemporaryDirectory(prefix='rpcs3-relay-') as temporary:
    out = Path(temporary)
    (out / 'util').mkdir()
    (out / 'util/vm.hpp').write_bytes((source / 'rpcs3/util/vm.hpp').read_bytes())
    (out / 'util/types.hpp').write_text('''#pragma once
#include <cstdint>
#include <cstddef>
#include <limits>
using u8=std::uint8_t; using u32=std::uint32_t; using u64=std::uint64_t;
using usz=std::size_t; using uptr=std::uintptr_t;
constexpr uptr umax=std::numeric_limits<uptr>::max();
namespace utils { template<class T, class A> T align(T value,A alignment) { return (value+alignment-1)&~(T(alignment)-1); } }
''')
    (out / 'util/atomic.hpp').write_text('''#pragma once
#include <atomic>
template<class T> struct atomic_t {
 std::atomic<T> value;
 constexpr atomic_t(T initial):value(initial){}
 operator T()const{return value.load();}
 bool compare_exchange(T& expected,T desired){return value.compare_exchange_strong(expected,desired);}
 T exchange(T desired){return value.exchange(desired);}
};
''')
    production = (source / 'rpcs3/util/vm_native.cpp').read_text()
    production = production[production.index('\tshm::shm('):production.index('} // namespace utils')]
    (out / 'ShmProduction.inc').write_text(production)
    compiler = shlex.split(os.environ.get('CXX', 'c++'))
    if sdk := os.environ.get('HOST_MACOS_SDK'):
        compiler += ['-isysroot', sdk]
    environment = dict(os.environ)
    environment.pop('SDKROOT', None)
    executable = out / 'relay-client-test'
    subprocess.run([*compiler, '-std=c++20', '-O2', '-Wall', '-Wextra', '-Werror',
                    '-pthread', '-DRPCS3_IOS=1', '-I', str(out), '-I', str(source / 'rpcs3'),
                    str(here / 'native/rpcs3_neoswap_relay_test.cpp'), '-o', str(executable)], check=True, env=environment)
    subprocess.run([str(executable)], check=True, timeout=60)
    # Compile the actual exported setter separately: installing the borrowed
    # vtable must not introduce constructors or link another host broker.
    core_source = (source / 'rpcs3/ios/RPCS3IOS.cpp').read_text()
    setter = re.search(r'extern "C" RPCS3_IOS_EXPORT int32_t rpcs3_ios_set_neoswap_relay_api\([^\n]+\) noexcept\n\{.*?\n\}', core_source, re.S)
    assert setter, 'missing production relay setter'
    assert '_rpcs3_ios_set_neoswap_relay_api' in (source / 'rpcs3/ios/RPCS3IOS.exports').read_text().splitlines()
    setter_source = out / 'relay-setter.cpp'
    setter_source.write_text('#define RPCS3_IOS_CORE_BUILD 1\n#include "ios/RPCS3IOS.h"\n#include "ios/NeoSwapRelayClient.h"\n' + setter[0] + '\n')
    setter_object = out / 'relay-setter.o'
    subprocess.run([*compiler, '-std=c++20', '-O2', '-Wall', '-Wextra', '-Werror',
                    '-fvisibility=hidden', '-fvisibility-inlines-hidden', '-I', str(source / 'rpcs3'),
                    '-c', str(setter_source), '-o', str(setter_object)], check=True, env=environment)
    symbols = subprocess.check_output(['nm', str(setter_object)], text=True)
    assert not re.search(r'_GLOBAL__sub_I|__cxx_global_var_init|__cxa_guard|NeoSwap_GetRelayAPI', symbols), 'relay setter adds initialization or a broker dependency'
print('PASS: actual RPCS3 shared-memory adapter, coherent aliases, protection, fallback and retirement')
