#!/usr/bin/env python3
"""Apply reviewed boot fixes to NeoStation's pinned, embedded RPCS3 Core."""
from pathlib import Path
import sys


def replace_once(text: str, old: str, new: str) -> str:
    if new in text:
        return text
    if text.count(old) != 1:
        raise ValueError(f"Pinned source mismatch: {old[:100]!r}")
    return text.replace(old, new, 1)


def replace_function(text: str, signature: str, replacement: str, marker: str) -> str:
    """Replace one complete C++ function while rejecting pinned-source drift."""
    if marker in text:
        return text
    if text.count(signature) != 1:
        raise ValueError(f"Pinned function mismatch: {signature!r}")
    start = text.index(signature)
    opening = text.index('{', start)
    depth = 1
    index = opening + 1
    while depth and index < len(text):
        depth += (text[index] == '{') - (text[index] == '}')
        index += 1
    if depth:
        raise ValueError(f"Unterminated pinned function: {signature!r}")
    replacement = replacement.replace(r'\t', '\t')
    return text[:start] + replacement + text[index:]


def patch(root: Path) -> None:
    edits = {}
    spu = root / 'rpcs3/Emu/Cell/SPUCommonRecompiler.cpp'
    text = spu.read_text()
    text = replace_once(text, '\t// Read cache\n\tauto func_list = cache.get();', '''\t// NEOSTATION_EMBEDDED_SPU_ON_DEMAND
\t// LLVM Precompilation previously disabled only *new* SPU precompilation.
\t// Existing raw SPU caches were still recompiled in full on every launch.
\t// ARM64 cannot reuse their machine objects across processes (host pointers),
\t// so honour the mobile on-demand policy for warm launches as well.
\t// Leave the cache on disk. Do not append duplicates to an unread cache.
#ifdef RPCS3_IOS
\tconst bool defer_existing_spu_cache = !g_cfg.core.llvm_precompilation;
#else
\tconstexpr bool defer_existing_spu_cache = false;
#endif
\tauto func_list = defer_existing_spu_cache ? std::deque<spu_program>{} : cache.get();
\tif (defer_existing_spu_cache)
\t{
\t\tspu_log.notice("NeoStation: SPU cache warmup deferred; LLVM compiles blocks on demand; disk cache retained.");
\t}''')
    text = replace_once(text,
        '\tif (g_cfg.core.spu_cache && !spu_precompilation_enabled && cache)',
        '\tif (g_cfg.core.spu_cache && !spu_precompilation_enabled && cache && !defer_existing_spu_cache)')
    edits[spu] = text

    ppu = root / 'rpcs3/Emu/Cell/PPUThread.cpp'
    text = ppu.read_text()
    text = replace_once(text,
        '\t\t\tfmt::append(obj_name, "v8-kusa-%s-%s-%s.obj", fmt::base57(output, 16), fmt::base57(settings), jit_compiler::cpu(g_cfg.core.llvm_cpu.to_string()));',
        '''#ifdef RPCS3_IOS
\t\t\t// Separate this source-built Core's LLVM objects from earlier IPA cores.
\t\t\t// Preserve old files; only recompile incompatible objects once.
\t\t\tfmt::append(obj_name, "v8-neostation-embedded1-%s-%s-%s.obj", fmt::base57(output, 16), fmt::base57(settings), jit_compiler::cpu(g_cfg.core.llvm_cpu.to_string()));
#else
\t\t\tfmt::append(obj_name, "v8-kusa-%s-%s-%s.obj", fmt::base57(output, 16), fmt::base57(settings), jit_compiler::cpu(g_cfg.core.llvm_cpu.to_string()));
#endif''')
    text = replace_once(text,
        '\t\t\tif (!failed_to_load && !jits[mod_index / c_modules_per_jit]->add(cache_path + obj_name))',
        '''#ifdef RPCS3_IOS
\t\t\tppu_log.notice("NeoStation PPU link begin: %s", obj_name);
#endif
\t\t\tif (!failed_to_load && !jits[mod_index / c_modules_per_jit]->add(cache_path + obj_name))''')
    text = replace_once(text,
        '\t\t\tjit->fin();',
        '''#ifdef RPCS3_IOS
\t\t\tppu_log.notice("NeoStation PPU relocation begin");
#endif
\t\t\tjit->fin();
#ifdef RPCS3_IOS
\t\t\tppu_log.notice("NeoStation PPU relocation complete");
#endif''')
    edits[ppu] = text

    jit = root / 'Utilities/JITIOS.cpp'
    text = jit.read_text()
    text = replace_function(text, 'bool prepare_arena(bool expanded) noexcept', r'''bool prepare_arena(bool expanded) noexcept
{
\tstd::lock_guard lock(g_arena_mutex);
\tif (g_arena.prepared)
\t{
\t\tif (g_arena.expanded != expanded)
\t\t{
\t\t\tset_error("JIT arena capacity policy changed after the arena was prepared; relaunch is required");
\t\t\treturn false;
\t\t}
\t\treturn true;
\t}

\tconst arena_backend backend = current_backend();
\tif (backend == arena_backend::legacy_debugger && !legacy_debugger_is_ready())
\t{
\t\treturn false;
\t}

\tconst usz capacity = choose_arena_capacity(physical_memory_size(), expanded);
\tif (!capacity || capacity > std::numeric_limits<usz>::max() / 2)
\t{
\t\tset_error("Invalid JIT arena capacity");
\t\treturn false;
\t}

\t// NEOSTATION_UNIVERSAL_DEBUGSERVER_RX
\t// On TXM/SPTM devices the RX mapping must be accepted by the Universal
\t// debugger protocol itself. The previous embedded path mmap'ed one large RX
\t// mapping in the Flutter host and merely prepared 16 MiB subranges. The
\t// script returned the requested address even when prepare_memory_region did
\t// not make that host mapping executable, so initialization looked healthy
\t// but the first LLVM call faulted at the arena base (0x7000000000).
\t// Requesting the RX mapping with x0 == nullptr makes universal.js allocate it
\t// through debugserver (_M<size>,rx) and prepare that exact VM region. We then
\t// create the ordinary shared RW alias, preserving W^X for all code writes.
\tif (backend == arena_backend::universal_mirrored)
\t{
\t\tconst u64 prepared_address = protocol_call(command_prepare_region, nullptr, capacity);
\t\tif (!prepared_address || (prepared_address & (page_size() - 1)) != 0)
\t\t{
\t\t\tset_error("Universal JIT did not return a valid debugserver-allocated RX arena");
\t\t\treturn false;
\t\t}

\t\tauto* const code = reinterpret_cast<u8*>(static_cast<uptr>(prepared_address));
\t\tvoid* const data_mapping = ::mmap(nullptr, capacity, PROT_READ | PROT_WRITE,
\t\t\tMAP_PRIVATE | MAP_ANON, jit_vm_tag, 0);
\t\tif (data_mapping == MAP_FAILED)
\t\t{
\t\t\tconst std::string detail = std::strerror(errno);
\t\t\t::vm_deallocate(mach_task_self(), static_cast<vm_address_t>(prepared_address),
\t\t\t\tstatic_cast<vm_size_t>(capacity));
\t\t\tset_error("Unable to map the Universal JIT data arena: " + detail);
\t\t\treturn false;
\t\t}
\t\tauto* const data = static_cast<u8*>(data_mapping);

\t\tvm_address_t alias = 0;
\t\tvm_prot_t current_protection = VM_PROT_NONE;
\t\tvm_prot_t maximum_protection = VM_PROT_NONE;
\t\tconst kern_return_t remap_result = ::vm_remap(
\t\t\tmach_task_self(),
\t\t\t&alias,
\t\t\tstatic_cast<vm_size_t>(capacity),
\t\t\t0,
\t\t\tVM_FLAGS_ANYWHERE,
\t\t\tmach_task_self(),
\t\t\tstatic_cast<vm_address_t>(prepared_address),
\t\t\tfalse,
\t\t\t&current_protection,
\t\t\t&maximum_protection,
\t\t\tVM_INHERIT_DEFAULT);
\t\tif (remap_result != KERN_SUCCESS)
\t\t{
\t\t\t::munmap(data, capacity);
\t\t\t::vm_deallocate(mach_task_self(), static_cast<vm_address_t>(prepared_address),
\t\t\t\tstatic_cast<vm_size_t>(capacity));
\t\t\tset_error("mach_vm_remap failed while creating the Universal JIT writable alias");
\t\t\treturn false;
\t\t}

\t\tif (::vm_protect(mach_task_self(), alias, static_cast<vm_size_t>(capacity), false,
\t\t\tVM_PROT_READ | VM_PROT_WRITE) != KERN_SUCCESS)
\t\t{
\t\t\t::vm_deallocate(mach_task_self(), alias, static_cast<vm_size_t>(capacity));
\t\t\t::munmap(data, capacity);
\t\t\t::vm_deallocate(mach_task_self(), static_cast<vm_address_t>(prepared_address),
\t\t\t\tstatic_cast<vm_size_t>(capacity));
\t\t\tset_error("mach_vm_protect failed for the Universal JIT writable alias");
\t\t\treturn false;
\t\t}

\t\tg_arena.code_allocator.reset(capacity);
\t\tg_arena.data_allocator.reset(capacity);
\t\tg_arena.code = code;
\t\tg_arena.writable_code = reinterpret_cast<u8*>(alias);
\t\tg_arena.data = data;
\t\tg_arena.capacity = capacity;
\t\t// One command-1 transaction allocates and prepares the complete RX VM
\t\t// region. Keep this counter useful in existing diagnostics.
\t\tg_arena.preparation_chunks = 1;
\t\tg_arena.backend = backend;
\t\tg_arena.expanded = expanded;
\t\tg_arena.prepared = true;
\t\treturn true;
\t}

\t// Pre-iOS-26 legacy debugger path: keep the established contiguous layout
\t// and ordinary W-to-X transition unchanged.
\tconst usz total_size = capacity * 2;
\tauto* const layout = static_cast<u8*>(::mmap(nullptr, total_size, PROT_NONE,
\t\tMAP_PRIVATE | MAP_ANON, jit_vm_tag, 0));
\tif (layout == MAP_FAILED)
\t{
\t\tset_error("Unable to reserve the JIT arena layout: " + std::string{std::strerror(errno)});
\t\treturn false;
\t}

\tvoid* const code = ::mmap(layout, capacity, PROT_READ | PROT_WRITE,
\t\tMAP_FIXED | MAP_PRIVATE | MAP_ANON, jit_vm_tag, 0);
\tif (code != layout)
\t{
\t\tconst std::string detail = std::strerror(errno);
\t\tdiscard_layout(layout, total_size, 0, capacity);
\t\tset_error("Unable to map the JIT code arena: " + detail);
\t\treturn false;
\t}

\tvoid* const data = ::mmap(layout + capacity, capacity, PROT_READ | PROT_WRITE,
\t\tMAP_FIXED | MAP_PRIVATE | MAP_ANON, jit_vm_tag, 0);
\tif (data != layout + capacity)
\t{
\t\tconst std::string detail = std::strerror(errno);
\t\tdiscard_layout(layout, total_size, 0, capacity);
\t\tset_error("Unable to map the JIT data arena: " + detail);
\t\treturn false;
\t}

\tvm_address_t alias = 0;
\tvm_prot_t current_protection = VM_PROT_NONE;
\tvm_prot_t maximum_protection = VM_PROT_NONE;
\tconst kern_return_t remap_result = ::vm_remap(
\t\tmach_task_self(),
\t\t&alias,
\t\tstatic_cast<vm_size_t>(capacity),
\t\t0,
\t\tVM_FLAGS_ANYWHERE,
\t\tmach_task_self(),
\t\tstatic_cast<vm_address_t>(reinterpret_cast<uptr>(layout)),
\t\tfalse,
\t\t&current_protection,
\t\t&maximum_protection,
\t\tVM_INHERIT_SHARE);
\tif (remap_result != KERN_SUCCESS)
\t{
\t\tdiscard_layout(layout, total_size, 0, capacity);
\t\tset_error("mach_vm_remap failed while creating the arena's writable alias");
\t\treturn false;
\t}

\tif (::vm_protect(mach_task_self(), alias, static_cast<vm_size_t>(capacity), false,
\t\tVM_PROT_READ | VM_PROT_WRITE) != KERN_SUCCESS)
\t{
\t\tdiscard_layout(layout, total_size, alias, capacity);
\t\tset_error("mach_vm_protect failed for the arena's writable alias");
\t\treturn false;
\t}

\tif (::mprotect(layout, capacity, PROT_READ | PROT_EXEC) != 0)
\t{
\t\tconst std::string detail = std::strerror(errno);
\t\tdiscard_layout(layout, total_size, alias, capacity);
\t\tset_error("Unable to transition the legacy JIT arena from writable to executable: " + detail);
\t\treturn false;
\t}

\tg_arena.code_allocator.reset(capacity);
\tg_arena.data_allocator.reset(capacity);
\tg_arena.code = layout;
\tg_arena.writable_code = reinterpret_cast<u8*>(alias);
\tg_arena.data = layout + capacity;
\tg_arena.capacity = capacity;
\tg_arena.preparation_chunks = 0;
\tg_arena.backend = backend;
\tg_arena.expanded = expanded;
\tg_arena.prepared = true;
\treturn true;
}''', 'NEOSTATION_UNIVERSAL_DEBUGSERVER_RX')
    edits[jit] = text

    api = root / 'rpcs3/ios/RPCS3IOS.cpp'
    text = api.read_text()
    text = replace_once(text,
        '''\tboot_progress_snapshot snapshot = read();
\tfor (;;)
\t{
\t\tboot_progress_snapshot next = read();
\t\tif (next == snapshot)
\t\t{
\t\t\treturn snapshot;
\t\t}
\t\tsnapshot = std::move(next);
\t}''',
        '''\tboot_progress_snapshot snapshot = read();
\t// A diagnostic reader must not spin indefinitely while workers advance.
\tfor (u32 attempt = 0; attempt < 8; ++attempt)
\t{
\t\tboot_progress_snapshot next = read();
\t\tif (next == snapshot)
\t\t{
\t\t\treturn snapshot;
\t\t}
\t\tsnapshot = std::move(next);
\t}
\treturn snapshot;''')
    text = replace_once(text,
        '''\t\tconst auto function_address = compiler.get("rpcs3_ios_test_function");
\t\tif (!function_address)''',
        '''\t\tconst auto function_address = compiler.get("rpcs3_ios_test_function");
\t\temit_log(4, fmt::format("RPCS3 LLVM JIT self-test entry=%p", function_address));
\t\tif (!function_address)''')
    edits[api] = text

    # Validate every replacement before modifying the checkout.
    for path, text in edits.items():
        path.write_text(text)
        print(f'Patched {path.relative_to(root)}')


if __name__ == '__main__':
    if len(sys.argv) != 2:
        raise SystemExit('usage: patch_rpcs3_embedded_boot.py <pinned-rpcs3-source>')
    patch(Path(sys.argv[1]))
