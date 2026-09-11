#!/usr/bin/env python3
"""Patch only the pinned embedded Core's JIT memory and publication contract."""
from pathlib import Path
import sys

from patch_rpcs3_embedded_boot import replace_function, replace_once

PARTS = Path(__file__).resolve().parent / 'rpcs3'


def patch(root: Path) -> None:
    edits = {}
    path = root / 'Utilities/JITIOS.h'
    text = path.read_text()
    text = replace_once(text, 'bool is_ready() noexcept;',
                        (PARTS / 'jit_write_scope.h.inc').read_text() + '\nbool is_ready() noexcept;')
    edits[path] = text

    path = root / 'Utilities/JITIOS.cpp'
    text = path.read_text()
    text = replace_once(text, '#include <algorithm>', '#include <algorithm>\n#include <atomic>\n#include <dlfcn.h>')
    text = text.replace('\tu8* writable_code = nullptr;\n', '\tu8* write_view = nullptr;\n')
    text = replace_once(text, 'std::mutex g_protocol_mutex;', '''// The iOS SDK marks the direct declaration unavailable. Resolve the existing
// runtime SPI without changing host entitlements or redeclaring SDK symbols.
using write_protect_fn = void (*)(int);
write_protect_fn write_protect_function() noexcept
{
\tstatic const auto function = reinterpret_cast<write_protect_fn>(
\t\t::dlsym(RTLD_DEFAULT, "pthread_jit_write_protect_np"));
\treturn function;
}
thread_local bool g_jit_executable = true;

std::mutex g_protocol_mutex;''')
    text = replace_function(text, 'void discard_layout(', '', 'NEOSTATION_DYNAMIC_JIT_V2')
    text = replace_function(text, 'bool prepare_arena(bool expanded) noexcept',
                            (PARTS / 'jit_arena.cpp.inc').read_text().rstrip(), 'NEOSTATION_DYNAMIC_JIT_V2')
    text = replace_once(text, 'bool is_ready() noexcept\n{', '''bool write_protected() noexcept
{
\treturn g_jit_executable;
}

void write_protect(bool executable) noexcept
{
\t// Always call pthread, even if our local state agrees: the calling thread
\t// may previously have been used by another embedded runtime.
\tconst auto function = write_protect_function();
\tstd::atomic_signal_fence(std::memory_order_seq_cst);
\t// iOS uses explicit, validated RX/RW pointers; it has no pthread switch.
\t// On platforms exposing the SPI, preserve the actual per-thread switch.
\tif (function) function(executable ? 1 : 0);
\tg_jit_executable = executable;
\tstd::atomic_signal_fence(std::memory_order_seq_cst);
}

bool is_ready() noexcept
{''')
    text = replace_once(text, '''\tu8* const storage = (executable ? g_arena.writable_code : g_arena.data) + allocation.offset;
\tstd::memset(storage, 0, allocation.size);''', '''\t{
\t\twrite_guard guard;
\t\tu8* const storage = (executable ? g_arena.write_view : g_arena.data) + allocation.offset;
\t\tstd::memset(storage, 0, allocation.size);
\t}''')
    text = replace_once(text, 'static_cast<void*>(g_arena.writable_code + offset)',
                        'static_cast<void*>(g_arena.write_view + offset)')
    text = replace_once(text, '''\tvoid* const alias = writable(executable, size);
\t::sys_dcache_flush(alias ? alias : const_cast<void*>(executable), size);''',
                        '''\tvoid* const write_view = writable(executable, size);
\t::sys_dcache_flush(write_view ? write_view : const_cast<void*>(executable), size);''')
    edits[path] = text

    path = root / 'Utilities/JIT.h'
    text = path.read_text()
    text = replace_once(text, 'void jit_announce(uptr func, usz size, std::string_view name);',
                        '#ifdef RPCS3_IOS\n#include "JITIOS.h"\n#endif\n\nvoid jit_announce(uptr func, usz size, std::string_view name);')
    text = replace_once(text, '''#if defined(__APPLE__) && !defined(RPCS3_IOS)
\tpthread_jit_write_protect_np(executable);''', '''#if defined(RPCS3_IOS)
\trpcs3::ios::jit::write_protect(executable);
#elif defined(__APPLE__)
\tpthread_jit_write_protect_np(executable);''')
    text = replace_once(text, '#if defined(__APPLE__) && !defined(RPCS3_IOS)\nstruct jit_write_guard',
                        '#if defined(RPCS3_IOS)\nusing jit_write_guard = rpcs3::ios::jit::write_guard;\n#elif defined(__APPLE__)\nstruct jit_write_guard')
    text = text.replace('// shared RW alias; elsewhere the executable pointer is already writable at',
                        '// verified shared write view; elsewhere the executable pointer is already writable at')
    edits[path] = text

    path = root / 'Utilities/JITLLVM.cpp'
    text = path.read_text()
    text = replace_once(text, '''#if defined(__APPLE__) && !defined(RPCS3_IOS)
\t\t\tjit_write_protect(false);
#endif''', '''#ifdef RPCS3_IOS
\t\t\tjit_write_guard ios_worker_write_scope;
#elif defined(__APPLE__)
\t\t\tjit_write_protect(false);
#endif''')
    # A pointer lookup can trigger lazy relocation. Protect all synchronous LLVM
    # entry points as well as the separate recoverable-codegen worker above.
    for signature in (
        'void jit_compiler::add(std::unique_ptr<llvm::Module> _module, const std::string& path)',
        'void jit_compiler::add(std::unique_ptr<llvm::Module> _module)',
        'bool jit_compiler::add(const std::string& path)',
        'void jit_compiler::fin()',
        'u64 jit_compiler::get(const std::string& name)',
    ):
        text = replace_once(text, signature + '\n{', signature + '''
{
#ifdef RPCS3_IOS
\tjit_write_guard ios_llvm_write_scope;
#endif''')
    edits[path] = text

    path = root / 'Utilities/JITASM.cpp'
    text = path.read_text()
    for signature in ('void* jit_runtime_base::_add(asmjit::CodeHolder* code, usz align) noexcept',
                      'void jit_runtime::finalize() noexcept'):
        text = replace_once(text, signature + '\n{', signature + '''
{
#ifdef RPCS3_IOS
\tjit_write_guard ios_asm_write_scope;
#endif''')
    edits[path] = text

    path = root / 'rpcs3/Emu/Cell/SPUCommonRecompiler.cpp'
    text = path.read_text()
    text = replace_once(text, 'spu_function_t spu_runtime::rebuild_ubertrampoline(u32 id_inst)\n{',
                        '''spu_function_t spu_runtime::rebuild_ubertrampoline(u32 id_inst)
{
#ifdef RPCS3_IOS
\tjit_write_guard ios_dispatcher_write_scope;
#endif''')
    edits[path] = text

    path = root / 'rpcs3/Emu/System.cpp'
    text = path.read_text()
    text = replace_once(text, '''#if defined(__APPLE__) && !defined(RPCS3_IOS)
\t\t\t\t// Apple Silicon W^X: this thread invokes ppu_initialize()''',
                        '''#ifdef RPCS3_IOS
\t\t\t\tjit_write_guard ios_loader_write_scope;
#elif defined(__APPLE__)
\t\t\t\t// Apple Silicon W^X: this thread invokes ppu_initialize()''')
    edits[path] = text

    path = root / 'rpcs3/ios/RPCS3IOS.cpp'
    text = path.read_text()
    text = replace_once(text, '\t\tconst uint64_t actual = reinterpret_cast<test_function>(function_address)(input);',
                        '''\t\t// The dispatch worker may have completed initialization in write mode.
\t\tjit_write_protect(true);
\t\temit_log(4, "NEOSTATION_DYNAMIC_JIT_V2: LLVM execute mode restored");
\t\tconst uint64_t actual = reinterpret_cast<test_function>(function_address)(input);''')
    edits[path] = text

    for path, text in edits.items():
        path.write_text(text)
        print(f'Patched JIT: {path.relative_to(root)}')


if __name__ == '__main__':
    if len(sys.argv) != 2:
        raise SystemExit('usage: patch_rpcs3_jit_memory.py <pinned-rpcs3-source>')
    patch(Path(sys.argv[1]))
