#!/usr/bin/env python3
"""Run selected v0.10.1 regressions against the materialized production Core.

The SPU/VK fixtures originate in XITRIX/rpcs3 (GPL-2.0). The SPU tests execute
the actual analyzer and extract both backend guards. Synthetic BID loop cases
cover the reported GoW III demo pattern; an optional 256 KiB reconstruction
can exercise the exact guest block without bundling copyrighted guest code.
"""
import argparse
import os
from pathlib import Path
import platform
import re
import shlex
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('source', type=Path, help='hash-verified materialized RPCS3 source root')
parser.add_argument('--guest', type=Path, help='optional 256 KiB GoW III demo local-store reconstruction')
parser.add_argument('--sanitize', action='store_true')
args = parser.parse_args()
root = args.source.resolve()
compiler = shlex.split(os.environ.get('CXX', 'clang++'))
if sdk := os.environ.get('HOST_MACOS_SDK'):
    compiler += ['-isysroot', sdk]
environment = dict(os.environ)
environment.pop('SDKROOT', None)  # Native host fixtures must not inherit the iPhoneOS SDK.


def compile_run(command, executable, *arguments):
    if args.sanitize:
        command[len(compiler):len(compiler)] = ['-fsanitize=address,undefined', '-fno-omit-frame-pointer']
    subprocess.run(command, check=True, env=environment, timeout=180)
    subprocess.run([str(executable), *map(str, arguments)], check=True, timeout=60)


with tempfile.TemporaryDirectory(prefix='rpcs3-v0101-') as directory:
    out = Path(directory)
    source = (root / 'rpcs3/Emu/Cell/SPUCommonRecompiler.cpp').read_text()
    analyzer = source[source.index('using reg_state_t ='):source.index('void spu_recompiler_base::dump(')]
    analyzer += source[source.index('std::array<reg_state_t, s_reg_max>& block_reg_info::evaluate_start_state'):source.index('void spu_recompiler_base::add_pattern(')]
    analyzer += source[source.index('void spu_recompiler_base::add_pattern('):source.index('extern std::string format_spu_func_info')]
    (out / 'SPUMailboxAnalyzer.inc').write_text(analyzer)
    source = (root / 'rpcs3/Emu/Cell/SPUThread.cpp').read_text()
    (out / 'SPUMailboxBranchTargets.inc').write_text(source[source.index('std::array<u32, 2> op_branch_targets(u32 pc, spu_opcode_t op)'):source.index('std::tuple<u32, std::array<u32, 3>, u32> op_register_targets')])
    (out / 'SPUMailboxTestSupport.inc').write_text((HERE / 'native/rpcs3_spu_analyzer_support.h').read_text())
    guards = []
    for backend, filename in [('llvm', 'SPULLVMRecompiler.cpp'), ('asmjit', 'SPUASMJITRecompiler.cpp')]:
        source = (root / 'rpcs3/Emu/Cell' / filename).read_text()
        match = re.search(r'(?:else )?if \((op\.d && [^\n]+)\)\n\s*\{\n\s*// Interrupts-disable pattern', source)
        assert match, f'missing production {backend} BID guard'
        lookup = 'tfound' if backend == 'llvm' else 'found'
        guards.append(f'''template <class Targets>
bool {backend}_fallthrough(const Targets& m_targets, u32 m_pos, spu_opcode_t op)
{{
    const auto {lookup} = m_targets.find(m_pos);
    if ({lookup} == m_targets.end()) return false;
    return {match[1]};
}}
''')
    (out / 'SPUBranchGuards.inc').write_text('\n'.join(guards))
    executable = out / 'spu-branch-tests'
    # libstdc++ exposes its production uint128 bit helpers in GNU mode.
    standard = '-std=c++23' if platform.system() == 'Darwin' else '-std=gnu++23'
    command = [*compiler, standard, '-O2', '-g', '-Wno-invalid-constexpr',
               '-I' + str(root), '-I' + str(root / 'rpcs3'),
               '-I' + str(root / '3rdparty/asmjit/asmjit/src'), '-iquote', str(out),
               HERE / 'native/rpcs3_spu_branch_analyzer_test.cpp', root / 'rpcs3/Crypto/sha1.cpp',
               '-o', executable]
    command += ['-Wl,-dead_strip'] if platform.system() == 'Darwin' else ['-ffunction-sections', '-fdata-sections', '-Wl,--gc-sections']
    compile_run(command, executable, *([args.guest.resolve(), 'gow3-demo'] if args.guest else []))

    source = (root / 'rpcs3/Emu/RSX/VK/VKGSRender.cpp').read_text()
    start = source.index('bool VKGSRender::on_vram_exhausted(')
    start = source.index('\t\t\tstd::set<u32> exclusion_list;', start)
    end = source.index('\n\t\t\t// Hold the secondary lock guard', start)
    (out / 'VKMemoryPressureScan.inc').write_text(source[start:end])
    executable = out / 'vk-pressure-tests'
    compile_run([*compiler, '-std=c++20', '-O2', '-Wall', '-Wextra', '-Werror',
                 '-I', out, HERE / 'native/rpcs3_vk_memory_pressure_test.cpp', '-o', executable], executable)

    # Execute the full production renderer initialization prefix, including
    # vendor assignment, and the actual backend conditional-render policy.
    source = (root / 'rpcs3/Emu/RSX/VK/VKHelpers.cpp').read_text()
    start = source.index('void set_current_renderer(')
    start = source.index('{', start) + 1
    end = source.index('\n\t\tswitch (g_driver_vendor)', start)
    (out / 'VKConditionalInitialization.inc').write_text(source[start:end])
    source = (root / 'rpcs3/Emu/RSX/VK/VKGSRender.cpp').read_text()
    match = re.search(r'backend_config\.supports_hw_conditional_render = ([^\n]+);', source)
    assert match, 'missing backend conditional-render capability'
    (out / 'VKConditionalBackend.inc').write_text('return ' + match[1] + ';\n')
    executable = out / 'vk-conditional-tests'
    compile_run([*compiler, '-std=c++20', '-O2', '-Wall', '-Wextra', '-Werror',
                 '-I', out, HERE / 'native/rpcs3_vk_conditional_render_test.cpp', '-o', executable], executable)

    # Old persistent objects encode the omitted continuation; use a new cache
    # namespace even though the public main Core ABI remains version 30.
    source = (root / 'rpcs3/Emu/Cell/SPUCommonRecompiler.cpp').read_text()
    version = int(re.search(r'constexpr u32 cache_version = (\d+);', source)[1])
    assert version >= 5 and 'fold(cache_version);' in source
    assert '#define RPCS3_IOS_ABI_VERSION 30u' in (root / 'rpcs3/ios/RPCS3IOS.h').read_text()

    source = (root / 'rpcs3/ios/RPCS3IOS.cpp').read_text()
    getter = re.search(r'extern "C" RPCS3_IOS_EXPORT int32_t rpcs3_ios_get_neoswap_client_stats\([^\n]+\) noexcept\n\{.*?\n\}', source, re.S)
    assert getter, 'missing optional production NeoSwap statistics getter'
    exports = (root / 'rpcs3/ios/RPCS3IOS.exports').read_text().splitlines()
    assert '_rpcs3_ios_get_neoswap_client_stats' in exports
    getter_source = out / 'stats-getter.cpp'
    getter_source.write_text('#define RPCS3_IOS_CORE_BUILD 1\n#include "rpcs3/ios/RPCS3IOS.h"\n#include "rpcs3/ios/NeoSwapClient.h"\n' + getter[0] + '\n')
    getter_object = out / 'stats-getter.o'
    flags = ['-std=c++20', '-O2', '-Wall', '-Wextra', '-Werror',
             '-fvisibility=hidden', '-fvisibility-inlines-hidden', '-I', str(root)]
    subprocess.run([*compiler, *flags, '-c', getter_source, '-o', getter_object], check=True, env=environment, timeout=60)
    symbols = subprocess.check_output(['nm', str(getter_object)], text=True)
    assert not re.search(r'_GLOBAL__sub_I|__cxx_global_var_init|__cxa_guard|NeoSwap_GetAPI|NeoSwap_Snapshot', symbols), 'getter adds a constructor or broker dependency'
    executable = out / 'stats-getter-tests'
    compile_run([*compiler, *flags, HERE / 'native/rpcs3_neoswap_stats_getter_test.cpp', getter_object,
                 '-o', executable], executable)

print('PASS: v0.10.1 SPU/Vulkan regressions, cache retirement and optional passive NeoSwap statistics getter')
