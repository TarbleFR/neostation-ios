#!/usr/bin/env python3
"""Contract tests for Build 301 passive dlopen and explicit JIT initialization."""
from __future__ import annotations

import importlib.util
import shutil
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PATCH = ROOT / 'build-utils/patch_rpcs3_build301_passive_dlopen.py'
PATCH_TEXT = PATCH.read_text()
compile(PATCH_TEXT, str(PATCH), 'exec')

assert 'NEOSTATION_BUILD301_PASSIVE_DLOPEN_V1' in PATCH_TEXT
assert 'passive_global_runtime' in PATCH_TEXT
assert 'no implicit retry is allowed' in PATCH_TEXT
assert 'runtime_memory requested before explicit JIT initialization' in PATCH_TEXT
assert 'allocate requested before explicit JIT initialization' in PATCH_TEXT
assert 'jit_initialize_failed stage=' in PATCH_TEXT
assert 'ppu_trampoline_init_begin' in PATCH_TEXT
assert 'initialize_ghc_trampolines' in PATCH_TEXT
assert 'spu_trampoline_init_begin' in PATCH_TEXT
assert 'jit_initialize_success' in PATCH_TEXT

spec = importlib.util.spec_from_file_location('patch301', PATCH)
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)


def function_body(text: str, signature: str) -> str:
    start = text.index(signature)
    brace = text.index('{', start)
    depth = 1
    index = brace + 1
    while depth:
        depth += (text[index] == '{') - (text[index] == '}')
        index += 1
    return text[start:index]


def validate_source(source: Path) -> None:
    module.validate(source)

    jit_header = (source / 'Utilities/JIT.h').read_text()
    jit_asm = (source / 'Utilities/JITASM.cpp').read_text()
    jit_ios = (source / 'Utilities/JITIOS.cpp').read_text()
    ppu_functions = (source / 'rpcs3/Emu/Cell/PPUFunction.cpp').read_text()
    ppu = (source / 'rpcs3/Emu/Cell/PPUThread.cpp').read_text()
    spu = (source / 'rpcs3/Emu/Cell/SPUCommonRecompiler.cpp').read_text()
    api = (source / 'rpcs3/ios/RPCS3IOS.cpp').read_text()

    # dlopen must not build HLE/PPU/SPU code or allocate the AsmJIT runtime.
    registry_start = ppu_functions.index('std::vector<ppu_intrp_func_t>& ppu_function_manager::access')
    registry_end = ppu_functions.index('bool ppu_function_manager::initialize_ghc_trampolines')
    registry = ppu_functions[registry_start:registry_end]
    assert 'build_function_asm' not in registry
    assert 'list_ghc{nullptr, nullptr}' in registry
    assert 'list_ghc.push_back(nullptr)' in registry
    assert 'initialize_ghc_trampolines' in ppu_functions

    assert 'const auto ppu_gateway = build_function_asm' not in ppu
    assert 'const extern auto ppu_escape = build_function_asm' not in ppu
    assert 'static ppu_trampoline_t ppu_gateway = nullptr' in ppu
    assert 'ppu_trampoline_t ppu_escape = nullptr' in ppu
    assert '[escape](native_asm& c, auto& args)' in ppu
    for name in ('tr_dispatch', 'tr_branch', 'tr_interpreter', 'g_dispatcher',
                 'tr_all', 'g_gateway', 'g_escape', 'g_tail_escape'):
        assert f'DECLARE(spu_runtime::{name}) = nullptr' in spu
        assert f'DECLARE(spu_runtime::{name}) = build_function_asm' not in spu
        assert f'DECLARE(spu_runtime::{name}) = []' not in spu

    global_runtime = function_body(jit_asm, 'jit_runtime_base& asmjit::get_global_runtime()')
    assert 'allocate(' not in global_runtime
    assert 'memory_reserve(' not in global_runtime
    assert 'return global_runtime_instance();' in global_runtime
    assert 'bool asmjit::initialize_global_runtime() noexcept' in jit_asm

    for signature in (
        'bool ppu_function_manager::initialize_ghc_trampolines(std::string& error) noexcept',
        'bool ppu_initialize_static_trampolines(std::string& error) noexcept',
        'bool spu_runtime::initialize_static_trampolines(std::string& error) noexcept',
    ):
        owner = ppu_functions if 'ppu_function_manager' in signature else (ppu if signature.startswith('bool ppu_') else spu)
        body = function_body(owner, signature)
        assert '\\n\\ttry\\n' not in body
        assert 'catch (' not in body

    # Normal iOS allocation failures propagate as nullptr/status, never ensure/abort.
    add = function_body(jit_asm, 'void* jit_runtime_base::_add(')
    assert 'auto* p = this->_alloc' in add
    assert 'if (!p)' in add
    assert 'ensure(this->_alloc' not in add
    assert 'if (!writable)' in add
    assert 'ensure(static_cast<uchar*>(rpcs3::ios::jit::writable' not in add
    builder_start = jit_header.index('inline FT build_function_asm')
    builder_end = jit_header.index('\n}\n', builder_start) + 2
    builder = jit_header[builder_start:builder_end]
    assert 'if (!result)' in builder
    assert 'return nullptr;' in builder

    # There is exactly one explicit preparation owner and no accessor prepares implicitly.
    assert 'bool prepare_arena() noexcept' not in jit_ios
    declaration = 'void emit_diagnostic(std::string message) noexcept;'
    assert declaration in jit_ios
    assert jit_ios.index(declaration) < jit_ios.index('u8* reserve_arena_layout(')
    assert jit_ios.index(declaration) < jit_ios.index('void emit_diagnostic(std::string message) noexcept\n{')
    assert api.count('jit::prepare_arena(') == 1
    for signature in ('void* runtime_memory(', 'usz arena_capacity(',
                      'bool claim_runtime(', 'void* allocate('):
        body = function_body(jit_ios, signature)
        assert 'prepare_arena(' not in body, signature
        assert 'before explicit JIT initialization' in body, signature

    # Explicit ordering: arena -> AsmJIT -> PPU -> SPU -> seal -> success.
    initialize = function_body(api, 'extern "C" rpcs3_ios_status rpcs3_ios_initialize(')
    ordered = (
        'jit_initialize_begin',
        'jit::prepare_arena(',
        'asmjit_global_runtime_begin',
        'asmjit::initialize_global_runtime()',
        'ppu_trampoline_init_begin',
        'ppu_initialize_static_trampolines',
        'ppu_function_manager::initialize_ghc_trampolines',
        'spu_trampoline_init_begin',
        'spu_runtime::initialize_static_trampolines',
        'jit::seal_arena()',
        'jit_initialize_success',
        'Emu.Init()',
    )
    positions = [initialize.index(token) for token in ordered]
    assert positions == sorted(positions), list(zip(ordered, positions))
    assert 'g_initialization_attempted = true' in initialize
    assert 'never retried implicitly' in initialize
    assert 'fail_initialize' in initialize
    assert 'abort(' not in initialize

    # No hidden policy from dyld or environment remains.
    assert 'RPCS3_IOS_EXPANDED_JIT_ARENA' not in jit_ios
    assert 'process_expanded_jit_arena_capacity' not in jit_ios

    # Diagnostics required to identify the actual failing stage.
    for event in (
        'requested_code_capacity', 'reservation_result', 'map_code_result',
        'map_data_result', 'universal_prepare_begin', 'universal_prepare_chunk',
        'universal_prepare_result', 'writable_alias_result',
        'asmjit_global_runtime_begin', 'asmjit_global_runtime_end',
        'ppu_trampoline_init_begin', 'ppu_trampoline_init_end',
        'spu_trampoline_init_begin', 'spu_trampoline_init_end',
        'jit_initialize_success', 'jit_initialize_failed',
    ):
        assert event in jit_ios or event in api, event


if len(sys.argv) > 1:
    validate_source(Path(sys.argv[1]).resolve())
else:
    # The build workflow exercises the patch against the full pinned postimage.
    # This standalone phase verifies the patch itself remains valid Python and
    # contains all fail-closed architecture contracts.
    assert "if any(MARKER in path.read_text() for path in files)" in PATCH_TEXT
    assert 'Build 301 partial postimage detected' in PATCH_TEXT

print('PASS: Build 301 makes RPCS3 dlopen passive and JIT initialization explicit')
