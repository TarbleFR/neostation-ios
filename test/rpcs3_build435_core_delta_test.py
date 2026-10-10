#!/usr/bin/env python3
"""Execute the Build 435 Core policies on the host and verify their wiring.

The native test runs the memory envelope and deferred SPU compile policies
with the real headers from the materialized source. The wiring checks prove
that the production call sites use them: dispatcher hand-off, worker pool
start, interpreter exit, writer-lock precheck before the lock and telemetry.
"""
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


def read(relative: str) -> str:
    return (core / relative).read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


compiler = shlex.split(os.environ.get('CXX', 'clang++'))
if sdk := os.environ.get('HOST_MACOS_SDK'):
    compiler += ['-isysroot', sdk]
env = dict(os.environ)
env.pop('SDKROOT', None)
with tempfile.TemporaryDirectory(prefix='rpcs3-build435-') as temporary:
    out = Path(temporary)
    for name, source in (('policies', ROOT / 'test/native/rpcs3_build435_core_delta_test.cpp'),
                         ('pressure', core / 'rpcs3/ios/tests/IOSMemoryPressurePolicyTests.cpp')):
        exe = out / name
        command = [*compiler, '-std=c++20', '-O1', '-g', '-Wall', '-Wextra', '-Werror',
                   '-I', str(core), str(source), '-o', str(exe)]
        if args.sanitize:
            command += ['-fsanitize=address,undefined', '-fno-omit-frame-pointer']
        subprocess.run(command, check=True, env=env, timeout=120)
        subprocess.run([str(exe)], check=True, timeout=30)

policy = read('rpcs3/ios/IOSMemoryPressurePolicy.h')
manager = read('rpcs3/Emu/RSX/VK/VKResourceManager.cpp')
performance = read('rpcs3/ios/RPCS3IOSPerformance.cpp')
common = read('rpcs3/Emu/Cell/SPUCommonRecompiler.cpp')
spu = read('rpcs3/Emu/Cell/SPUThread.cpp')
ppu = read('rpcs3/Emu/Cell/PPUThread.cpp')

# Delta A: the allowance is measured once per evaluation and drives the stage.
require('high_footprint_headroom_moderate_enter = 2560 * process_memory_mib' in policy,
        'the Build 352 constant no longer caps the relative stage')
require('u64 process_memory_limit_estimate() noexcept' in performance and
        '::sysctlbyname("hw.memsize"' in performance and 'limit_mib=%llu' in performance,
        'the allowance estimate or its COREPROF field is missing')
evaluation = manager[manager.index('rsx::problem_severity vmm_determine_memory_load_severity()'):
                     manager.index('bool vmm_handle_memory_pressure(')]
require('rpcs3::ios::process_memory_limit_estimate()' in evaluation and
        evaluation.index('process_limit);') > evaluation.index('get_process_memory_pressure('),
        'the pressure evaluation does not pass the measured allowance')
require('next_moderate_reclaim_delay_ms(' in manager and 'moderate_reclaim_was_effective(' in manager and
        'headroom_at_last_reclaim = headroom_now;' in manager,
        'the adaptive cooldown is not wired')

# Delta B: hand-off happens only in dispatch(), the pool starts once per boot and
# the interpreter leaves only at a taken branch through the policy.
dispatch = common[common.index('void spu_recompiler_base::dispatch('):common.index('void spu_recompiler_base::branch(')]
require('if (spu_deferred_dispatch(spu, program))' in dispatch and
        dispatch.index('spu_deferred_dispatch(spu, program)') < dispatch.index('compile_spu_llvm_with_retry(spu.jit, program)'),
        'the dispatcher does not defer before compiling inline')
require('g_fxo->init<spu_deferred_compiler>()' in common and 'SPUDEFERRED pool started' in common,
        'the deferred pool is not started per boot')
worker = common[common.index('void spu_deferred_worker::operator()()'):common.index('static bool spu_deferred_dispatch(')]
require('compile_spu_llvm_with_retry(compiler, func2)' in worker and
        'clear_warmup_local_store(std::span{ls.data() + start / 4, size0})' in worker and
        'item->deferred_inline.release(1);' in worker,
        'the worker does not compile through the retrying production path')
interpreter = common[common.index('void spu_recompiler_base::old_interpreter('):common.index('std::vector<u32> spu_thread::discover_functions(')]
require('rpcs3::spu::interpreter_should_exit(' in interpreter and
        interpreter.index('spu.pc += 4;') < interpreter.index('else if (spu.interp_fallback_item)'),
        'the interpreter hand-off is not restricted to taken branches')
require('deferred_published=%llu' in performance and 'interp_handoffs=%llu' in performance,
        'SPUPROF lacks the deferred compile fields')

# Delta C: the unlocked snapshot comparison precedes the exclusive lock on both paths.
putllc = spu[spu.index('NEOSTATION_BUILD435_WRITER_LOCK_PRECHECK_V1'):]
require(putllc.index('record_writer_lock_avoided(static_cast<u32>(vm::writer_lock_source::spu_putllc))') <
        putllc.index('vm::writer_lock lock(addr, range_lock);'),
        'PUTLLC takes the writer lock before comparing the snapshot')
require('if (!cmp_rdata(rdata, super_data))' in putllc[:putllc.index('vm::writer_lock lock(addr, range_lock);')],
        'PUTLLC precheck does not compare the reservation snapshot')
stcx = ppu[ppu.index('NEOSTATION_BUILD435_WRITER_LOCK_PRECHECK_V1'):]
require(stcx.index('record_writer_lock_avoided(static_cast<u32>(vm::writer_lock_source::ppu_stcx))') <
        stcx.index('vm::writer_lock lock(addr, range_lock);'),
        'PPU stcx takes the writer lock before comparing the snapshot')
require('wl_putllc_avoided=%llu wl_ppu_stcx_avoided=%llu' in performance,
        'RANGELOCKPROF lacks the avoided-lock counters')
print('PASS: Build 435 Core policies executed on the host; dispatcher, pool, interpreter, writer-lock precheck and telemetry wired')
