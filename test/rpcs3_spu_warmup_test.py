#!/usr/bin/env python3
"""Execute SPU warmup policy, counters and production LLVM reuse/claim paths."""
import argparse
import os
from pathlib import Path
import shlex
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('source', type=Path)
parser.add_argument('--sanitize', action='store_true')
args = parser.parse_args()
core = args.source.resolve()
llvm = (core / 'rpcs3/Emu/Cell/SPULLVMRecompiler.cpp').read_text()
common = (core / 'rpcs3/Emu/Cell/SPUCommonRecompiler.cpp').read_text()
config = (core / 'Utilities/Config.h').read_text()
# Compile the real call site with cfg::_bool's real explicit conversion/get
# accessors. Testing the policy with plain bools misses the iOS integration ABI.
policy_start = common.index('const bool spu_precompilation_enabled = rpcs3::spu::precompile_discovered(')
policy_end = common.index(';', policy_start) + 1
config_bool = config.index('class _bool final : public _base')
access_start = config.index('\t\texplicit operator bool() const', config_bool)
access_end = config.index('\n\t\tvoid from_default()', access_start)
# The fixture executes the actual production preamble, including the complete
# duplicate/failed-claim wait handling, stopping only where LLVM IR begins.
start = llvm.index('\t\tconst u32 start0 = _func.entry_point;', llvm.index('virtual spu_function_t compile('))
end = llvm.index('\n\t\tstruct compile_claim_guard', start)
claim = llvm[start:end]
retry_start = common.index('static spu_function_t compile_spu_llvm_with_retry(')
retry_end = common.index('\n\tif (context.llvm_error.empty())', retry_start)
retry_first_attempt = common[retry_start:retry_end] + '\n\treturn nullptr;\n}\n'
compiler = shlex.split(os.environ.get('CXX', 'clang++'))
if sdk := os.environ.get('HOST_MACOS_SDK'):
    compiler += ['-isysroot', sdk]
env = dict(os.environ)
env.pop('SDKROOT', None)
with tempfile.TemporaryDirectory(prefix='rpcs3-spu-warmup-') as temporary:
    out = Path(temporary)
    (out / 'SPUCompileClaim.inc').write_text(claim)
    (out / 'SPURetryFirstAttempt.inc').write_text(retry_first_attempt)
    (out / 'SPUPrecompilePolicyCall.inc').write_text(common[policy_start:policy_end])
    (out / 'SPUConfigBoolAccessors.inc').write_text(config[access_start:access_end])
    exe = out / 'warmup'
    command = [*compiler, '-std=c++20', '-O1', '-g', '-Wall', '-Wextra', '-Werror',
               '-pthread', '-DRPCS3_IOS', '-I', str(core), '-I', str(out),
               str(ROOT / 'test/native/rpcs3_spu_warmup_test.cpp'), '-o', str(exe)]
    if args.sanitize:
        command += ['-fsanitize=address,undefined', '-fno-omit-frame-pointer']
    subprocess.run(command, check=True, env=env, timeout=120)
    subprocess.run([str(exe)], check=True, timeout=30)
# Wiring and safety guards supplement, rather than replace, executable tests.
assert 'clear_warmup_local_store(std::span{ls.data() + start / 4, size0})' in common
assert '4 * (size0 - 1)' not in common
assert 'rpcs3::spu::precompile_discovered(' in common
assert 'targeted_warmup && build_existing_cache);' in common
assert 'rpcs3::spu::warmup_scope phase;' in common
assert 'rpcs3::spu::warmup_worker_count(' in common
assert 'warmup_barrier_guard metadata_phase{metadata_replayed};' in common
assert 'metadata_phase.wait();' in common
assert 'metadata_replay_scope metadata_record;' in common
assert 'add_loc->cached = 1;' in llvm
replay_start = common.index('void spu_cache::initialize(')
replay_end = common.index('bool spu_program::operator==', replay_start)
assert '.add_empty(' not in common[replay_start:replay_end]
assert 'SPUWARMUP begin' in common and 'SPUWARMUP end' in common
# Preprocess just the ARM64 persistence branch with the C preprocessor, avoiding
# LLVM headers, and ensure neither debug mode nor interpreter can cache objects.
block = llvm[llvm.index('#ifdef ARCH_ARM64\n\t\t\tconst bool recoverable'):]
block = block[:block.index('\n\t\t// Register function pointer')]
interp = llvm[llvm.index('spu_function_t compile_interpreter()'):]
interp = interp[interp.index('#ifdef ARCH_ARM64\n\t\t// The generated interpreter'):]
interp = interp[:interp.index('\n\n\t\tm_jit.fin();')]
expanded = subprocess.check_output([*compiler, '-E', '-P', '-x', 'c++', '-DARCH_ARM64', '-'],
                                   input=block + '\n' + interp, text=True, env=env)
assert 'get_cache_path()' not in expanded and 'get_obj_cache_path()' not in expanded
assert 'm_jit.try_add(std::move(_module), llvm_error)' in expanded
assert expanded.count('m_jit.add(std::move(_module));') == 2
print('PASS: production SPU reuse, startup policy, scratch LS isolation, phase counters and ARM64 cache safety')
