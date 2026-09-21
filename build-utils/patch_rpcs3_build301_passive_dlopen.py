#!/usr/bin/env python3
"""Make the embedded iOS RPCS3 Core passive at dlopen and initialize JIT explicitly.

Build 300 proved that dyld ran PPU/SPU and HLE registration constructors which
allocated the AsmJIT global runtime before rpcs3_ios_initialize. A failed arena
allocation then reached ensure()/abort() and killed NeoStation. This patch makes
every JIT-owning global passive, prepares one arena from the iOS API, builds the
AsmJIT/PPU/HLE/SPU trampolines exactly once, and propagates failures as API errors.
"""
from __future__ import annotations

import sys
from pathlib import Path

MARKER = "NEOSTATION_BUILD301_PASSIVE_DLOPEN_V1"


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"{label}: expected one anchor, found {count}")
    return text.replace(old, new, 1)


def find_statement(text: str, start_marker: str, start_at: int = 0) -> tuple[int, int, str]:
    start = text.find(start_marker, start_at)
    if start < 0:
        raise RuntimeError(f"missing statement anchor: {start_marker}")
    paren = brace = bracket = angle = 0
    quote: str | None = None
    escape = False
    line_comment = False
    block_comment = False
    i = start
    while i < len(text):
        ch = text[i]
        nxt = text[i + 1] if i + 1 < len(text) else ""
        if line_comment:
            if ch == "\n":
                line_comment = False
            i += 1
            continue
        if block_comment:
            if ch == "*" and nxt == "/":
                block_comment = False
                i += 2
            else:
                i += 1
            continue
        if quote:
            if escape:
                escape = False
            elif ch == "\\":
                escape = True
            elif ch == quote:
                quote = None
            i += 1
            continue
        if ch == "/" and nxt == "/":
            line_comment = True
            i += 2
            continue
        if ch == "/" and nxt == "*":
            block_comment = True
            i += 2
            continue
        if ch in ('"', "'"):
            quote = ch
            i += 1
            continue
        if ch == "(":
            paren += 1
        elif ch == ")":
            paren -= 1
        elif ch == "{":
            brace += 1
        elif ch == "}":
            brace -= 1
        elif ch == "[":
            bracket += 1
        elif ch == "]":
            bracket -= 1
        elif ch == ";" and paren == 0 and brace == 0 and bracket == 0:
            return start, i + 1, text[start : i + 1]
        i += 1
    raise RuntimeError(f"unterminated statement: {start_marker}")


def rhs_of(statement: str) -> str:
    pos = statement.find("=")
    if pos < 0 or not statement.rstrip().endswith(";"):
        raise RuntimeError("invalid initializer statement")
    return statement[pos + 1 : statement.rfind(";")].strip()


def function_from_rhs(return_type: str, name: str, rhs: str, args: str = "") -> str:
    return f"static {return_type} {name}({args})\n{{\n\treturn {rhs};\n}}"


def patch_jit_header(root: Path) -> None:
    path = root / "Utilities/JIT.h"
    text = path.read_text()
    if MARKER in text:
        return
    text = replace_once(
        text,
        """\t// Should only be used to build global functions
\tjit_runtime_base& get_global_runtime();
""",
        f"""\t// {MARKER}: the iOS global AsmJIT runtime is inert during dyld load.
\t// It is allocated only by rpcs3_ios_initialize after the arena is ready.
\tjit_runtime_base& get_global_runtime();
\tbool initialize_global_runtime() noexcept;
\tbool global_runtime_ready() noexcept;
""",
        "AsmJIT declarations",
    )
    text = replace_once(
        text,
        """\tconst auto result = rt._add(&code, reduced_size ? 16 : 64);
\tjit_announce(result, code.codeSize(), name);
\treturn reinterpret_cast<FT>(uptr(result));
""",
        """\tconst auto result = rt._add(&code, reduced_size ? 16 : 64);
\tif (!result)
\t{
\t\treturn nullptr;
\t}
\tjit_announce(result, code.codeSize(), name);
\treturn reinterpret_cast<FT>(uptr(result));
""",
        "build_function_asm failure propagation",
    )
    path.write_text(text)


def patch_jit_asm(root: Path) -> None:
    path = root / "Utilities/JITASM.cpp"
    text = path.read_text()
    if MARKER in text:
        return
    text = replace_once(
        text,
        """\t// Select subrange
\tu8* pointer = ensure(get_jit_memory(Executable));
#ifdef RPCS3_IOS
\tconst u64 capacity = rpcs3::ios::jit::arena_capacity(Executable);
\tensure(capacity);
#else
""",
        """\t// Select subrange. iOS startup failures are normal API failures, not
\t// process invariants: never route a missing arena through ensure()/abort().
\tu8* pointer = get_jit_memory(Executable);
\tif (!pointer)
\t{
\t\treturn nullptr;
\t}
#ifdef RPCS3_IOS
\tconst u64 capacity = rpcs3::ios::jit::arena_capacity(Executable);
\tif (!capacity)
\t{
\t\treturn nullptr;
\t}
#else
""",
        "runtime arena lookup",
    )
    text = replace_once(
        text,
        """\tauto p = ensure(this->_alloc(codeSize, align));
\tensure(!code->relocateToBase(uptr(p)));
""",
        """\tauto* p = this->_alloc(codeSize, align);
\tif (!p)
\t{
\t\treturn nullptr;
\t}
\tensure(!code->relocateToBase(uptr(p)));
""",
        "AsmJIT allocation propagation",
    )
    text = replace_once(
        text,
        """#ifdef RPCS3_IOS
\t\twritable = ensure(static_cast<uchar*>(rpcs3::ios::jit::writable(p, codeSize)));
#endif
""",
        """#ifdef RPCS3_IOS
\t\twritable = static_cast<uchar*>(rpcs3::ios::jit::writable(p, codeSize));
\t\tif (!writable)
\t\t{
\t\t\treturn nullptr;
\t\t}
#endif
""",
        "AsmJIT writable alias propagation",
    )
    start = text.index("jit_runtime_base& asmjit::get_global_runtime()")
    end = text.index("\nasmjit::inline_runtime::inline_runtime", start)
    old = text[start:end]
    new = f'''namespace
{{
// {MARKER}
constexpr u64 global_asmjit_runtime_size = 1024 * 1024 * 16;

class passive_global_runtime final : public jit_runtime_base
{{
public:
\tpassive_global_runtime() noexcept
\t{{
#ifndef RPCS3_IOS
\t\tinitialize();
#endif
\t}}

\tbool initialize() noexcept
\t{{
\t\tstd::lock_guard lock(m_init_mutex);
\t\tif (m_ready)
\t\t{{
\t\t\treturn true;
\t\t}}

#ifdef RPCS3_IOS
\t\tauto* const memory = static_cast<uchar*>(rpcs3::ios::jit::allocate(
\t\t\ttrue, global_asmjit_runtime_size, 64));
#else
\t\tauto* const memory = static_cast<uchar*>(
\t\t\tutils::memory_reserve(global_asmjit_runtime_size, true));
#endif
\t\tif (!memory)
\t\t{{
\t\t\treturn false;
\t\t}}

\t\tm_pos.raw() = memory;
\t\tm_max = memory + global_asmjit_runtime_size;
#ifndef RPCS3_IOS
\t\tutils::memory_commit(memory, global_asmjit_runtime_size, utils::protection::wx);
#endif
\t\tm_ready = true;
\t\treturn true;
\t}}

\tbool ready() const noexcept
\t{{
\t\tstd::lock_guard lock(m_init_mutex);
\t\treturn m_ready;
\t}}

\tuchar* _alloc(usz size, usz align) noexcept override
\t{{
\t\tif (!m_ready)
\t\t{{
\t\t\treturn nullptr;
\t\t}}
\t\treturn m_pos.atomic_op([&](uchar*& pos) -> uchar*
\t\t{{
\t\t\tconst auto result = reinterpret_cast<uchar*>(utils::align(uptr(pos), align));
\t\t\tif (result >= pos && result + size > pos && result + size <= m_max)
\t\t\t{{
\t\t\t\tpos = result + size;
\t\t\t\treturn result;
\t\t\t}}
\t\t\treturn nullptr;
\t\t}});
\t}}

private:
\tmutable std::mutex m_init_mutex;
\tatomic_t<uchar*> m_pos{{}};
\tuchar* m_max{{}};
\tbool m_ready = false;
}};

passive_global_runtime& global_runtime_instance() noexcept
{{
\t// Magic static construction is passive on iOS; no arena access occurs here.
\tstatic passive_global_runtime runtime;
\treturn runtime;
}}
}}

jit_runtime_base& asmjit::get_global_runtime()
{{
\treturn global_runtime_instance();
}}

bool asmjit::initialize_global_runtime() noexcept
{{
\treturn global_runtime_instance().initialize();
}}

bool asmjit::global_runtime_ready() noexcept
{{
\treturn global_runtime_instance().ready();
}}
'''
    text = text[:start] + new + text[end:]
    path.write_text(text)


def patch_jit_ios_header(root: Path) -> None:
    path = root / "Utilities/JITIOS.h"
    text = path.read_text()
    if MARKER in text:
        return
    text = replace_once(
        text,
        """bool is_ready() noexcept;
bool prepare_arena() noexcept;
bool prepare_arena(u32 expanded_capacity_mib) noexcept;
""",
        f"""// {MARKER}: only the explicit iOS API may prepare the arena.
using diagnostic_callback = void(*)(const char* message) noexcept;
void set_diagnostic_callback(diagnostic_callback callback) noexcept;
bool is_ready() noexcept;
bool prepare_arena(u32 expanded_capacity_mib) noexcept;
""",
        "explicit JIT API",
    )
    path.write_text(text)


def patch_jit_ios(root: Path) -> None:
    path = root / "Utilities/JITIOS.cpp"
    text = path.read_text()
    if MARKER in text:
        return
    text = replace_once(text, "#include <algorithm>\n", "#include <algorithm>\n#include <atomic>\n", "atomic include")
    text = text.replace('constexpr char expanded_jit_arena_environment[] = "RPCS3_IOS_EXPANDED_JIT_ARENA";\n', '')
    text = text.replace(
        """u32 process_expanded_jit_arena_capacity() noexcept
{
\tconst char* const value = std::getenv(expanded_jit_arena_environment);
\treturn value ? rpcs3::ios::jit::parse_expanded_arena_capacity(value) : 0;
}

""",
        "",
    )
    text = replace_once(
        text,
        """std::mutex g_error_mutex;
arena_state g_arena;
std::string g_last_error;
""",
        f"""std::mutex g_error_mutex;
arena_state g_arena;
std::string g_last_error;
std::atomic<rpcs3::ios::jit::diagnostic_callback> g_diagnostic_callback{{nullptr}};
void emit_diagnostic(std::string message) noexcept;
// {MARKER}
""",
        "JIT diagnostics state",
    )
    text = replace_once(
        text,
        """void set_error(std::string message) noexcept
{
\tstd::lock_guard lock(g_error_mutex);
\tg_last_error = std::move(message);
}
""",
        """void emit_diagnostic(std::string message) noexcept
{
\tif (const auto callback = g_diagnostic_callback.load())
\t{
\t\tcallback(message.c_str());
\t}
}

void set_error(std::string message) noexcept
{
\temit_diagnostic("jit_initialize_failed detail=" + message);
\tstd::lock_guard lock(g_error_mutex);
\tg_last_error = std::move(message);
}
""",
        "JIT diagnostic emitter",
    )
    # Reservation summary without flooding every rejected candidate.
    text = replace_once(
        text,
        """\tbegin = (begin + arena_address_step - 1) & ~(arena_address_step - 1);
\tfor (vm_address_t candidate = begin; candidate <= end - size; candidate += arena_address_step)
\t{
""",
        """\tbegin = (begin + arena_address_step - 1) & ~(arena_address_step - 1);
\tvm_address_t last_candidate = 0;
\tkern_return_t last_result = KERN_INVALID_ADDRESS;
\tfor (vm_address_t candidate = begin; candidate <= end - size; candidate += arena_address_step)
\t{
\t\tlast_candidate = candidate;
""",
        "reservation trace variables",
    )
    text = replace_once(
        text,
        """\t\tconst kern_return_t result = ::vm_allocate(
""",
        """\t\tconst kern_return_t result = ::vm_allocate(
""",
        "reservation call anchor",
    )
    text = replace_once(
        text,
        """\t\t\tVM_FLAGS_FIXED | jit_vm_tag);
\t\tif (result != KERN_SUCCESS || address != candidate)
""",
        """\t\t\tVM_FLAGS_FIXED | jit_vm_tag);
\t\tlast_result = result;
\t\tif (result != KERN_SUCCESS || address != candidate)
""",
        "reservation result capture",
    )
    text = replace_once(
        text,
        """\t\tif (::vm_protect(mach_task_self(), candidate, static_cast<vm_size_t>(size),
\t\t\tfalse, VM_PROT_NONE) == KERN_SUCCESS)
\t\t{
\t\t\treturn reinterpret_cast<u8*>(candidate);
\t\t}
""",
        """\t\tconst kern_return_t protect_result = ::vm_protect(
\t\t\tmach_task_self(), candidate, static_cast<vm_size_t>(size), false, VM_PROT_NONE);
\t\tif (protect_result == KERN_SUCCESS)
\t\t{
\t\t\temit_diagnostic("reservation_result candidate=" + std::to_string(candidate) +
\t\t\t\t" size=" + std::to_string(size) + " kern_return_t=0");
\t\t\treturn reinterpret_cast<u8*>(candidate);
\t\t}
\t\tlast_result = protect_result;
""",
        "reservation success trace",
    )
    text = replace_once(
        text,
        """\t}
\treturn nullptr;
}

u8* reserve_code_data_layout""",
        """\t}
\temit_diagnostic("reservation_result candidate=" + std::to_string(last_candidate) +
\t\t" size=" + std::to_string(size) + " kern_return_t=" + std::to_string(last_result));
\treturn nullptr;
}

u8* reserve_code_data_layout""",
        "reservation failure trace",
    )
    text = text.replace(
        """bool prepare_arena() noexcept
{
\treturn prepare_arena(process_expanded_jit_arena_capacity());
}

""",
        "",
    )
    text = replace_once(
        text,
        """bool prepare_arena(u32 expanded_capacity_mib) noexcept
{
\tstd::lock_guard lock(g_arena_mutex);
""",
        """bool prepare_arena(u32 expanded_capacity_mib) noexcept
{
\temit_diagnostic("jit_initialize_begin requested_expanded_capacity_mib=" +
\t\tstd::to_string(expanded_capacity_mib));
\tstd::lock_guard lock(g_arena_mutex);
""",
        "prepare diagnostics begin",
    )
    text = replace_once(
        text,
        """\tconst usz capacity = choose_arena_capacity(physical_memory_size(), expanded_capacity_mib);
\tusz data_capacity = 0;
""",
        """\tconst usz capacity = choose_arena_capacity(physical_memory_size(), expanded_capacity_mib);
\temit_diagnostic("requested_code_capacity=" + std::to_string(capacity) +
\t\t" requested_data_capacity=" + std::to_string(capacity));
\tusz data_capacity = 0;
""",
        "capacity diagnostics",
    )
    text = replace_once(
        text,
        """\tif (!map_arena_region(layout, capacity, initial_code_protection))
""",
        """\temit_diagnostic("map_code_begin address=" +
\t\tstd::to_string(reinterpret_cast<uptr>(layout)) + " size=" + std::to_string(capacity));
\tif (!map_arena_region(layout, capacity, initial_code_protection))
""",
        "code map begin",
    )
    text = replace_once(
        text,
        """\tif (!map_arena_region(data, data_capacity, PROT_READ | PROT_WRITE))
""",
        """\temit_diagnostic("map_code_result success=1 errno=0");
\temit_diagnostic("map_data_begin address=" +
\t\tstd::to_string(reinterpret_cast<uptr>(data)) + " size=" + std::to_string(data_capacity));
\tif (!map_arena_region(data, data_capacity, PROT_READ | PROT_WRITE))
""",
        "data map begin",
    )
    text = replace_once(
        text,
        """\tu32 preparation_chunks = 0;
\tif (backend == arena_backend::universal_mirrored)
""",
        """\temit_diagnostic("map_data_result success=1 errno=0");
\tu32 preparation_chunks = 0;
\tif (backend == arena_backend::universal_mirrored)
""",
        "data map result",
    )
    text = replace_once(
        text,
        """\t\tpreparation_chunks = arena_prepare_chunk_count(capacity);
\t\tfor (u32 chunk_index = 0; chunk_index < preparation_chunks; ++chunk_index)
""",
        """\t\tpreparation_chunks = arena_prepare_chunk_count(capacity);
\t\temit_diagnostic("universal_prepare_begin chunks=" + std::to_string(preparation_chunks));
\t\tfor (u32 chunk_index = 0; chunk_index < preparation_chunks; ++chunk_index)
""",
        "universal prepare begin",
    )
    text = replace_once(
        text,
        """\t\t\tconst u64 response = chunk_length ? protocol_call(command_prepare_region, chunk, chunk_length) : 0;
\t\t\tif (!chunk_length || response != reinterpret_cast<uptr>(chunk))
""",
        """\t\t\tconst u64 response = chunk_length ? protocol_call(command_prepare_region, chunk, chunk_length) : 0;
\t\t\temit_diagnostic("universal_prepare_chunk index=" + std::to_string(chunk_index) +
\t\t\t\t" address=" + std::to_string(reinterpret_cast<uptr>(chunk)) +
\t\t\t\t" size=" + std::to_string(chunk_length) + " response=" + std::to_string(response));
\t\t\tif (!chunk_length || response != reinterpret_cast<uptr>(chunk))
""",
        "universal chunk diagnostics",
    )
    text = replace_once(
        text,
        """\tvm_address_t alias = 0;
""",
        """\tif (backend == arena_backend::universal_mirrored)
\t{
\t\temit_diagnostic("universal_prepare_result success=1");
\t}
\tvm_address_t alias = 0;
""",
        "universal result",
    )
    text = replace_once(
        text,
        """\tif (remap_result != KERN_SUCCESS)
""",
        """\temit_diagnostic("writable_alias_result address=" + std::to_string(alias) +
\t\t" kern_return_t=" + std::to_string(remap_result));
\tif (remap_result != KERN_SUCCESS)
""",
        "alias diagnostics",
    )
    text = replace_once(
        text,
        """\tg_arena.prepared = true;
\treturn true;
}
""",
        """\tg_arena.prepared = true;
\temit_diagnostic("arena_prepare_success code_address=" +
\t\tstd::to_string(reinterpret_cast<uptr>(g_arena.code)) +
\t\t" data_address=" + std::to_string(reinterpret_cast<uptr>(g_arena.data)));
\treturn true;
}
""",
        "arena success diagnostics",
    )
    text = replace_once(
        text,
        """bool seal_arena() noexcept
{
\tif (!prepare_arena())
\t{
\t\treturn false;
\t}

\tarena_backend backend = arena_backend::legacy_debugger;
""",
        """bool seal_arena() noexcept
{
\tarena_backend backend = arena_backend::legacy_debugger;
""",
        "explicit seal",
    )
    text = replace_once(
        text,
        """\t\tif (g_arena.sealed)
\t\t{
\t\t\treturn true;
\t\t}
""",
        """\t\tif (!g_arena.prepared)
\t\t{
\t\t\tset_error("seal_arena called before explicit JIT preparation");
\t\t\treturn false;
\t\t}
\t\tif (g_arena.sealed)
\t\t{
\t\t\treturn true;
\t\t}
""",
        "seal prepared guard",
    )
    # Replace implicit preparation in all allocation accessors.
    text = replace_once(
        text,
        """void* runtime_memory(bool executable) noexcept
{
\tif (!prepare_arena())
\t{
\t\treturn nullptr;
\t}

\tstd::lock_guard lock(g_arena_mutex);
\treturn executable ? static_cast<void*>(g_arena.code) : static_cast<void*>(g_arena.data);
}
""",
        """void* runtime_memory(bool executable) noexcept
{
\tstd::lock_guard lock(g_arena_mutex);
\tif (!g_arena.prepared)
\t{
\t\tset_error("runtime_memory requested before explicit JIT initialization");
\t\treturn nullptr;
\t}
\treturn executable ? static_cast<void*>(g_arena.code) : static_cast<void*>(g_arena.data);
}
""",
        "runtime_memory explicit guard",
    )
    text = replace_once(
        text,
        """usz arena_capacity(bool executable) noexcept
{
\tif (!prepare_arena())
\t{
\t\treturn 0;
\t}

\tstd::lock_guard lock(g_arena_mutex);
\treturn executable ? g_arena.capacity : g_arena.data_capacity;
}
""",
        """usz arena_capacity(bool executable) noexcept
{
\tstd::lock_guard lock(g_arena_mutex);
\tif (!g_arena.prepared)
\t{
\t\tset_error("arena_capacity requested before explicit JIT initialization");
\t\treturn 0;
\t}
\treturn executable ? g_arena.capacity : g_arena.data_capacity;
}
""",
        "arena capacity explicit guard",
    )
    text = replace_once(
        text,
        """\tif (!prepare_arena())
\t{
\t\treturn false;
\t}

\tstd::lock_guard lock(g_arena_mutex);
\tarena_allocator& allocator = executable ? g_arena.code_allocator : g_arena.data_allocator;
""",
        """\tstd::lock_guard lock(g_arena_mutex);
\tif (!g_arena.prepared)
\t{
\t\tset_error("claim_runtime requested before explicit JIT initialization");
\t\treturn false;
\t}
\tarena_allocator& allocator = executable ? g_arena.code_allocator : g_arena.data_allocator;
""",
        "claim runtime explicit guard",
    )
    text = replace_once(
        text,
        """void* allocate(bool executable, usz size, usz alignment) noexcept
{
\tif (!prepare_arena())
\t{
\t\treturn nullptr;
\t}

\tstd::lock_guard lock(g_arena_mutex);
\tarena_allocator& allocator = executable ? g_arena.code_allocator : g_arena.data_allocator;
""",
        """void* allocate(bool executable, usz size, usz alignment) noexcept
{
\tstd::lock_guard lock(g_arena_mutex);
\tif (!g_arena.prepared)
\t{
\t\tset_error("allocate requested before explicit JIT initialization");
\t\treturn nullptr;
\t}
\tarena_allocator& allocator = executable ? g_arena.code_allocator : g_arena.data_allocator;
""",
        "allocate explicit guard",
    )
    # Public setter at namespace entry.
    namespace_anchor = "namespace rpcs3::ios::jit\n{\n"
    text = replace_once(
        text,
        namespace_anchor,
        namespace_anchor + "void set_diagnostic_callback(diagnostic_callback callback) noexcept\n{\n\tg_diagnostic_callback.store(callback);\n}\n\n",
        "diagnostic callback API",
    )
    path.write_text(text)


def patch_ppu_function_header(root: Path) -> None:
    path = root / "rpcs3/Emu/Cell/PPUFunction.h"
    text = path.read_text()
    if MARKER in text:
        return
    text = replace_once(
        text,
        '#include "util/v128.hpp"\n',
        '#include "util/v128.hpp"\n#include <string>\n',
        "PPU function string include",
    )
    text = replace_once(
        text,
        """\t// Read all registered functions
\tstatic inline const auto& get(bool llvm = false)
""",
        f"""\t// {MARKER}: global HLE registration records raw handlers only. The
\t// GHC trampolines are built explicitly after the iOS JIT arena is ready.
\tstatic bool initialize_ghc_trampolines(std::string& error) noexcept;

\t// Read all registered functions
\tstatic inline const auto& get(bool llvm = false)
""",
        "PPU HLE initializer declaration",
    )
    path.write_text(text)


def patch_ppu_function(root: Path) -> None:
    path = root / "rpcs3/Emu/Cell/PPUFunction.cpp"
    text = path.read_text()
    if MARKER in text:
        return
    if "#include <mutex>" not in text:
        text = replace_once(
            text,
            '#include "PPUInterpreter.h"\n',
            '#include "PPUInterpreter.h"\n\n#include <mutex>\n',
            "PPU function mutex include",
        )

    old_access = r'''std::vector<ppu_intrp_func_t>& ppu_function_manager::access(bool ghc)
{
	static std::vector<ppu_intrp_func_t> list
	{
		[](ppu_thread& ppu, ppu_opcode_t, be_t<u32>* this_op, ppu_intrp_func*)
		{
			ppu.cia = vm::get_addr(this_op);
			ppu_log.error("Unregistered function called (LR=0x%x)", ppu.lr);
			ppu.gpr[3] = 0;
			ppu.cia = static_cast<u32>(ppu.lr) & ~3;
		},
		[](ppu_thread& ppu, ppu_opcode_t, be_t<u32>* this_op, ppu_intrp_func*)
		{
			ppu.state += cpu_flag::ret;
			ppu.cia = vm::get_addr(this_op) + 4;
		},
	};

	static std::vector<ppu_intrp_func_t> list_ghc
	{
		build_function_asm<ppu_intrp_func_t>("ppu_unregistered", gen_ghc_cpp_trampoline(list[0])),
		build_function_asm<ppu_intrp_func_t>("ppu_return", gen_ghc_cpp_trampoline(list[1])),
	};

	return ghc ? list_ghc : list;
}

u32 ppu_function_manager::add_function(ppu_intrp_func_t function)
{
	auto& list = access();
	auto& list2 = access(true);

	list.push_back(function);

	list2.push_back(build_function_asm<ppu_intrp_func_t>("", gen_ghc_cpp_trampoline(function)));

	return ::size32(list) - 1;
}
'''
    new_access = f'''std::vector<ppu_intrp_func_t>& ppu_function_manager::access(bool ghc)
{{
	static std::vector<ppu_intrp_func_t> list
	{{
		[](ppu_thread& ppu, ppu_opcode_t, be_t<u32>* this_op, ppu_intrp_func*)
		{{
			ppu.cia = vm::get_addr(this_op);
			ppu_log.error("Unregistered function called (LR=0x%x)", ppu.lr);
			ppu.gpr[3] = 0;
			ppu.cia = static_cast<u32>(ppu.lr) & ~3;
		}},
		[](ppu_thread& ppu, ppu_opcode_t, be_t<u32>* this_op, ppu_intrp_func*)
		{{
			ppu.state += cpu_flag::ret;
			ppu.cia = vm::get_addr(this_op) + 4;
		}},
	}};

	// {MARKER}: placeholders preserve stable HLE indexes during dyld global
	// registration without allocating executable memory.
	static std::vector<ppu_intrp_func_t> list_ghc{{nullptr, nullptr}};
	return ghc ? list_ghc : list;
}}

u32 ppu_function_manager::add_function(ppu_intrp_func_t function)
{{
	auto& list = access();
	auto& list_ghc = access(true);
	list.push_back(function);
	list_ghc.push_back(nullptr);
	return ::size32(list) - 1;
}}

bool ppu_function_manager::initialize_ghc_trampolines(std::string& error) noexcept
{{
	static std::mutex mutex;
	static u32 state = 0; // 0 untouched, 1 failed/in progress, 2 ready
	std::lock_guard lock(mutex);
	if (state == 2)
	{{
		return true;
	}}
	if (state == 1)
	{{
		error = "PPU HLE trampoline initialization was already attempted; no implicit retry is allowed";
		return false;
	}}
	state = 1;

		const auto& raw = access();
		std::vector<ppu_intrp_func_t> compiled;
		compiled.reserve(raw.size());
		for (usz index = 0; index < raw.size(); ++index)
		{{
			const std::string_view name = index == 0 ? "ppu_unregistered" :
				(index == 1 ? "ppu_return" : "");
			auto* const trampoline = build_function_asm<ppu_intrp_func_t>(
				name, gen_ghc_cpp_trampoline(raw[index]));
			if (!trampoline)
			{{
				error = fmt::format("PPU HLE trampoline allocation failed at index %u", index);
				return false;
			}}
			compiled.push_back(trampoline);
		}}
		access(true) = std::move(compiled);
		state = 2;
		return true;
}}
'''
    text = replace_once(text, old_access, new_access, "PPU HLE deferred trampoline registry")
    path.write_text(text)

def patch_ppu_header(root: Path) -> None:
    path = root / "rpcs3/Emu/Cell/PPUThread.h"
    text = path.read_text()
    if MARKER in text:
        return
    text = replace_once(text, '#include "util/v128.hpp"\n', '#include "util/v128.hpp"\n#include <string>\n', "PPU string include")
    anchor = """struct ppu_thread_params
{
"""
    text = replace_once(
        text,
        anchor,
        f"""// {MARKER}: creates the formerly global JIT trampolines only after the
// iOS arena and global AsmJIT runtime are ready.
bool ppu_initialize_static_trampolines(std::string& error) noexcept;

{anchor}""",
        "PPU initializer declaration",
    )
    path.write_text(text)


def patch_ppu(root: Path) -> None:
    path = root / "rpcs3/Emu/Cell/PPUThread.cpp"
    text = path.read_text()
    if MARKER in text:
        return
    if "#include <mutex>" not in text:
        text = replace_once(text, "#include <optional>\n", "#include <optional>\n#include <mutex>\n", "PPU mutex include")

    gs, ge, gateway_stmt = find_statement(text, "const auto ppu_gateway = build_function_asm")
    gateway_rhs = rhs_of(gateway_stmt)
    es, ee, escape_stmt = find_statement(text, "const extern auto ppu_escape = build_function_asm", ge)
    escape_rhs = rhs_of(escape_stmt)
    fs1, fe1, fallback_x86_stmt = find_statement(text, "const auto ppu_recompiler_fallback_ghc = build_function_asm", ee)
    fs2, fe2, fallback_arm_stmt = find_statement(text, "const auto ppu_recompiler_fallback_ghc = build_function_asm", fe1)
    fallback_x86_rhs = rhs_of(fallback_x86_stmt)
    fallback_arm_rhs = rhs_of(fallback_arm_stmt).replace("reinterpret_cast<u64>(ppu_escape)", "reinterpret_cast<u64>(escape)")

    declarations = f'''// {MARKER}
using ppu_trampoline_t = void(*)(ppu_thread*);
using ppu_fallback_trampoline_t = void(*)(ppu_thread&);

static ppu_trampoline_t ppu_gateway = nullptr;
ppu_trampoline_t ppu_escape = nullptr;
static ppu_fallback_trampoline_t ppu_recompiler_fallback_ghc = nullptr;

'''
    gateway_fn = function_from_rhs("ppu_trampoline_t", "build_ppu_gateway", gateway_rhs)
    escape_fn = function_from_rhs("ppu_trampoline_t", "build_ppu_escape", escape_rhs)
    fallback_x86_fn = function_from_rhs(
        "ppu_fallback_trampoline_t", "build_ppu_recompiler_fallback", fallback_x86_rhs,
        "ppu_trampoline_t escape"
    ).replace("{\n\treturn", "{\n\t(void)escape;\n\treturn", 1)
    fallback_arm_fn = function_from_rhs(
        "ppu_fallback_trampoline_t", "build_ppu_recompiler_fallback", fallback_arm_rhs,
        "ppu_trampoline_t escape"
    ).replace("[](native_asm& c, auto& args)", "[escape](native_asm& c, auto& args)", 1)

    # Replace from the end to preserve indexes.
    text = text[:fs2] + fallback_arm_fn + text[fe2:]
    text = text[:fs1] + fallback_x86_fn + text[fe1:]
    # escape/gateway indexes precede fallback and remain valid after reverse replacements.
    text = text[:es] + escape_fn + text[ee:]
    text = text[:gs] + declarations + gateway_fn + text[ge:]

    # Locate the #endif after the two fallback builders in transformed text.
    arm_pos = text.index("static ppu_fallback_trampoline_t build_ppu_recompiler_fallback", text.index("#elif defined(ARCH_ARM64)"))
    endif = text.index("#endif", arm_pos) + len("#endif")
    initializer = r'''

bool ppu_initialize_static_trampolines(std::string& error) noexcept
{
	static std::mutex mutex;
	static u32 state = 0; // 0 untouched, 1 failed/in progress, 2 ready
	std::lock_guard lock(mutex);
	if (state == 2)
	{
		return true;
	}
	if (state == 1)
	{
		error = "PPU trampoline initialization was already attempted; no implicit retry is allowed";
		return false;
	}
	state = 1;

		const auto gateway = build_ppu_gateway();
		if (!gateway)
		{
			error = "PPU gateway allocation failed";
			return false;
		}
		const auto escape = build_ppu_escape();
		if (!escape)
		{
			error = "PPU escape allocation failed";
			return false;
		}
		const auto fallback = build_ppu_recompiler_fallback(escape);
		if (!fallback)
		{
			error = "PPU fallback trampoline allocation failed";
			return false;
		}

		ppu_gateway = gateway;
		ppu_escape = escape;
		ppu_recompiler_fallback_ghc = fallback;
		state = 2;
		return true;
}
'''
    text = text[:endif] + initializer + text[endif:]
    path.write_text(text)


def patch_spu_header(root: Path) -> None:
    path = root / "rpcs3/Emu/Cell/SPURecompiler.h"
    text = path.read_text()
    if MARKER in text:
        return
    for old, new in (
        ("static const spu_function_t tr_dispatch;", "static spu_function_t tr_dispatch;"),
        ("static const spu_function_t tr_branch;", "static spu_function_t tr_branch;"),
        ("static const spu_function_t tr_interpreter;", "static spu_function_t tr_interpreter;"),
        ("static const spu_function_t tr_all;", "static spu_function_t tr_all;"),
        ("static std::array<atomic_t<spu_function_t>, (1 << 20)>* const g_dispatcher;", "static std::array<atomic_t<spu_function_t>, (1 << 20)>* g_dispatcher;"),
        ("static const spu_function_t g_gateway;", "static spu_function_t g_gateway;"),
        ("static void(*const g_escape)(spu_thread*);", "static void(*g_escape)(spu_thread*);"),
        ("static void(*const g_tail_escape)(spu_thread*, spu_function_t, u8*);", "static void(*g_tail_escape)(spu_thread*, spu_function_t, u8*);"),
    ):
        text = replace_once(text, old, new, f"SPU declaration {old}")
    text = replace_once(
        text,
        """\t// Similar to g_escape, but doing tail call to the new function.
\tstatic void(*g_tail_escape)(spu_thread*, spu_function_t, u8*);

\t// Interpreter table""",
        f"""\t// Similar to g_escape, but doing tail call to the new function.
\tstatic void(*g_tail_escape)(spu_thread*, spu_function_t, u8*);

\t// {MARKER}: zero-initialized during dyld load, built explicitly once.
\tstatic bool initialize_static_trampolines(std::string& error) noexcept;

\t// Interpreter table""",
        "SPU initializer declaration",
    )
    path.write_text(text)


def patch_spu(root: Path) -> None:
    path = root / "rpcs3/Emu/Cell/SPUCommonRecompiler.cpp"
    text = path.read_text()
    if MARKER in text:
        return

    names = ["tr_dispatch", "tr_branch", "tr_interpreter", "g_dispatcher", "tr_all", "g_gateway", "g_escape", "g_tail_escape"]
    statements: dict[str, tuple[int, int, str]] = {}
    pos = 0
    for name in names:
        marker = f"DECLARE(spu_runtime::{name}) ="
        s, e, statement = find_statement(text, marker, pos)
        statements[name] = (s, e, statement)
        pos = e

    rhs = {name: rhs_of(value[2]) for name, value in statements.items()}
    rhs["g_dispatcher"] = rhs["g_dispatcher"].replace("[]", "[dispatch]", 1)
    rhs["g_dispatcher"] = rhs["g_dispatcher"].replace("x.raw() = tr_dispatch;", "x.raw() = dispatch;")
    rhs["g_dispatcher"] = rhs["g_dispatcher"].replace(
        "const auto ptr = reinterpret_cast<std::remove_const_t<decltype(spu_runtime::g_dispatcher)>>(jit_runtime::alloc(sizeof(*g_dispatcher), 64, false));",
        "const auto ptr = reinterpret_cast<decltype(spu_runtime::g_dispatcher)>(jit_runtime::alloc(sizeof(*spu_runtime::g_dispatcher), 64, false));\n\tif (!ptr) return static_cast<decltype(spu_runtime::g_dispatcher)>(nullptr);",
    )
    rhs["tr_all"] = rhs["tr_all"].replace("[]", "[dispatcher]", 1).replace("g_dispatcher", "dispatcher")
    rhs["tr_all"] = rhs["tr_all"].replace(
        "[](native_asm& c, auto& args)",
        "[dispatcher](native_asm& c, auto& args)",
        1,
    )
    rhs["g_gateway"] = rhs["g_gateway"].replace("[]", "[dispatch_all]", 1).replace("spu_runtime::tr_all", "dispatch_all")

    definitions = f'''// {MARKER}
DECLARE(spu_runtime::tr_dispatch) = nullptr;
DECLARE(spu_runtime::tr_branch) = nullptr;
DECLARE(spu_runtime::tr_interpreter) = nullptr;
DECLARE(spu_runtime::g_dispatcher) = nullptr;
DECLARE(spu_runtime::tr_all) = nullptr;
DECLARE(spu_runtime::g_gateway) = nullptr;
DECLARE(spu_runtime::g_escape) = nullptr;
DECLARE(spu_runtime::g_tail_escape) = nullptr;

'''
    builders = [
        function_from_rhs("spu_function_t", "build_spu_tr_dispatch", rhs["tr_dispatch"]),
        function_from_rhs("spu_function_t", "build_spu_tr_branch", rhs["tr_branch"]),
        function_from_rhs("spu_function_t", "build_spu_tr_interpreter", rhs["tr_interpreter"]),
        function_from_rhs(
            "std::array<atomic_t<spu_function_t>, (1 << 20)>*",
            "build_spu_dispatcher", rhs["g_dispatcher"], "spu_function_t dispatch"
        ),
        function_from_rhs(
            "spu_function_t", "build_spu_tr_all", rhs["tr_all"],
            "std::array<atomic_t<spu_function_t>, (1 << 20)>* dispatcher"
        ),
        function_from_rhs("spu_function_t", "build_spu_gateway", rhs["g_gateway"], "spu_function_t dispatch_all"),
        function_from_rhs("auto", "build_spu_escape", rhs["g_escape"]),
        function_from_rhs(
            "auto", "build_spu_tail_escape", rhs["g_tail_escape"]
        ),
    ]
    initializer = r'''

bool spu_runtime::initialize_static_trampolines(std::string& error) noexcept
{
	static std::mutex mutex;
	static u32 state = 0; // 0 untouched, 1 failed/in progress, 2 ready
	std::lock_guard lock(mutex);
	if (state == 2)
	{
		return true;
	}
	if (state == 1)
	{
		error = "SPU trampoline initialization was already attempted; no implicit retry is allowed";
		return false;
	}
	state = 1;

		const auto dispatch = build_spu_tr_dispatch();
		if (!dispatch) { error = "SPU dispatch trampoline allocation failed"; return false; }
		const auto branch = build_spu_tr_branch();
		if (!branch) { error = "SPU branch trampoline allocation failed"; return false; }
		const auto interpreter = build_spu_tr_interpreter();
		if (!interpreter) { error = "SPU interpreter trampoline allocation failed"; return false; }
		const auto dispatcher = build_spu_dispatcher(dispatch);
		if (!dispatcher) { error = "SPU dispatcher table allocation failed"; return false; }
		const auto all = build_spu_tr_all(dispatcher);
		if (!all) { error = "SPU all-dispatch trampoline allocation failed"; return false; }
		const auto gateway = build_spu_gateway(all);
		if (!gateway) { error = "SPU gateway allocation failed"; return false; }
		const auto escape = build_spu_escape();
		if (!escape) { error = "SPU escape allocation failed"; return false; }
		const auto tail_escape = build_spu_tail_escape();
		if (!tail_escape) { error = "SPU tail-escape allocation failed"; return false; }

		tr_dispatch = dispatch;
		tr_branch = branch;
		tr_interpreter = interpreter;
		g_dispatcher = dispatcher;
		tr_all = all;
		g_gateway = gateway;
		g_escape = escape;
		g_tail_escape = tail_escape;
		state = 2;
		return true;
}
'''
    section_start = statements[names[0]][0]
    section_end = statements[names[-1]][1]
    replacement = definitions + "\n\n".join(builders) + initializer
    text = text[:section_start] + replacement + text[section_end:]
    path.write_text(text)


def patch_ios_api(root: Path) -> None:
    path = root / "rpcs3/ios/RPCS3IOS.cpp"
    text = path.read_text()
    if MARKER in text:
        return
    text = replace_once(
        text,
        '#include "Emu/System.h"\n',
        '#include "Emu/System.h"\n#include "Emu/Cell/PPUFunction.h"\n#include "Emu/Cell/PPUThread.h"\n#include "Emu/Cell/SPURecompiler.h"\n',
        "explicit trampoline headers",
    )
    text = replace_once(
        text,
        """bool g_emu_started = false;
std::atomic_bool g_accept_display_surfaces = false;
""",
        f"""bool g_emu_started = false;
bool g_initialization_attempted = false;
// {MARKER}
std::atomic_bool g_accept_display_surfaces = false;
""",
        "single initialization state",
    )
    text = replace_once(
        text,
        """void emit_log(int32_t level, std::string_view message)
{
""",
        """void emit_log(int32_t level, std::string_view message)
{
""",
        "emit log anchor",
    )
    text = replace_once(
        text,
        """\tg_config.log_callback(g_config.user_context, level, terminated.c_str());
}

void emit_jit_arena_statistics""",
        """\tg_config.log_callback(g_config.user_context, level, terminated.c_str());
}

void emit_jit_diagnostic(const char* message) noexcept
{
\temit_log(2, message ? message : "jit_initialize_failed detail=empty diagnostic");
}

void emit_jit_arena_statistics""",
        "JIT diagnostic bridge",
    )
    # Add marker to build identity.
    text = replace_once(
        text,
        '\\"build266\\":\\"NEOSTATION_BUILD266_JIT_V09_SHADER_V1\\",',
        '\\"build266\\":\\"NEOSTATION_BUILD266_JIT_V09_SHADER_V1\\",\\"build301\\":\\"NEOSTATION_BUILD301_PASSIVE_DLOPEN_V1\\",',
        "build identity marker",
    )
    start = text.index('extern "C" rpcs3_ios_status rpcs3_ios_initialize')
    end = text.index('\nextern "C" rpcs3_ios_status rpcs3_ios_update_config_database', start)
    old = text[start:end]
    new = r'''extern "C" rpcs3_ios_status rpcs3_ios_initialize(const rpcs3_ios_config* config) noexcept
{
	std::lock_guard lock(g_api_mutex);
	if (g_lifecycle.state() != RPCS3_IOS_STATE_UNINITIALIZED || g_initialization_attempted)
	{
		set_error("RPCS3Core initialization is single-instance and is never retried implicitly");
		return RPCS3_IOS_INVALID_STATE;
	}

	if (const auto result = validate_config(config); result != RPCS3_IOS_OK)
	{
		return result;
	}
	if (const auto result = g_lifecycle.begin_initialize(); result != RPCS3_IOS_OK)
	{
		set_error("RPCS3Core initialization state transition failed");
		return result;
	}
	g_initialization_attempted = true;

	g_application_support_path = config->application_support_path;
	g_cache_path = config->cache_path;
	g_config = *config;
	g_config.application_support_path = g_application_support_path.c_str();
	g_config.cache_path = g_cache_path.c_str();
	rpcs3::ios::jit::set_diagnostic_callback(&emit_jit_diagnostic);

	auto fail_initialize = [&](rpcs3_ios_status status, std::string_view stage, std::string detail)
	{
		if (detail.empty())
		{
			detail = "unknown JIT initialization failure";
		}
		set_error(detail);
		emit_log(1, "jit_initialize_failed stage=" + std::string{stage} + " detail=" + detail);
		g_lifecycle.finish_initialize(false);
		return status;
	};

	if (!fs::set_config_dir(g_config.application_support_path) || !fs::set_cache_dir(g_config.cache_path))
	{
		return fail_initialize(RPCS3_IOS_INVALID_ARGUMENT, "sandbox_paths",
			"Unable to configure writable RPCS3 sandbox directories");
	}

	g_log_listener = std::make_unique<callback_log_listener>();
	logs::listener::add(g_log_listener.get());
	emit_log(2, "jit_initialize_begin");

	if (!rpcs3::ios::jit::is_ready())
	{
		return fail_initialize(RPCS3_IOS_JIT_UNAVAILABLE, "debugger_readiness",
			rpcs3::ios::jit::last_error());
	}

	emit_log(2, fmt::format("requested_code_capacity policy=%u", config->expanded_jit_arena));
	if (!rpcs3::ios::jit::prepare_arena(config->expanded_jit_arena))
	{
		return fail_initialize(RPCS3_IOS_JIT_MAPPING_FAILED, "arena_prepare",
			rpcs3::ios::jit::last_error());
	}

	emit_log(2, "asmjit_global_runtime_begin");
	if (!asmjit::initialize_global_runtime())
	{
		return fail_initialize(RPCS3_IOS_JIT_MAPPING_FAILED, "asmjit_global_runtime",
			rpcs3::ios::jit::last_error());
	}
	emit_log(2, "asmjit_global_runtime_end");

	std::string trampoline_error;
	emit_log(2, "ppu_trampoline_init_begin");
	if (!ppu_initialize_static_trampolines(trampoline_error))
	{
		return fail_initialize(RPCS3_IOS_JIT_MAPPING_FAILED, "ppu_trampolines",
			trampoline_error + "; " + rpcs3::ios::jit::last_error());
	}
	trampoline_error.clear();
	if (!ppu_function_manager::initialize_ghc_trampolines(trampoline_error))
	{
		return fail_initialize(RPCS3_IOS_JIT_MAPPING_FAILED, "ppu_hle_trampolines",
			trampoline_error + "; " + rpcs3::ios::jit::last_error());
	}
	emit_log(2, "ppu_trampoline_init_end");

	trampoline_error.clear();
	emit_log(2, "spu_trampoline_init_begin");
	if (!spu_runtime::initialize_static_trampolines(trampoline_error))
	{
		return fail_initialize(RPCS3_IOS_JIT_MAPPING_FAILED, "spu_trampolines",
			trampoline_error + "; " + rpcs3::ios::jit::last_error());
	}
	emit_log(2, "spu_trampoline_init_end");

	if (!rpcs3::ios::jit::seal_arena())
	{
		return fail_initialize(RPCS3_IOS_JIT_MAPPING_FAILED, "arena_seal",
			rpcs3::ios::jit::last_error());
	}
	emit_log(2, "jit_initialize_success");

	try
	{
		g_rpcn_config_loaded = false;
		g_rpcn_client.reset();

		// A developer can request one bounded SPU profile through the injected
		// cache root. Consume the request so subsequent launches stay unchanged.
		const std::string profile_request = fs::get_cache_dir() + "jit-profile.once";
		if (fs::file request{profile_request, fs::read}; request && request.size() == 1)
		{
			char enabled = 0;
			if (request.read(&enabled, 1) == 1 && enabled == '1' && fs::remove_file(profile_request))
			{
				const auto timestamp = std::chrono::duration_cast<std::chrono::microseconds>(
					std::chrono::system_clock::now().time_since_epoch()).count();
				const std::string stem = fs::get_cache_dir() + "spu-jit-profile-" + std::to_string(timestamp);
				if (jit_profile::spu_writer().open(stem,
					reinterpret_cast<std::uintptr_t>(rpcs3::ios::jit::runtime_memory(true)), rpcs3::ios::jit::arena_capacity()))
				{
					emit_log(4, "SPU JIT diagnostic capture enabled: " + stem +
						".{map,bin} (v1; at most 65536 symbols, 8 MiB map and 32 MiB code; finalized snapshots, later patches not recorded)");
				}
				else
				{
					emit_log(3, "SPU JIT diagnostic capture could not create its output files; continuing without capture");
				}
			}
		}

		g_preferred_language = rpcs3::ios::preferred_language_identifier();
		rpcs3::ios::set_localization_resolver(&rpcs3::ios::localized_application_string);
		emit_log(4, "Using iOS preferred language for native overlays: " + g_preferred_language);
		const auto database_result = rpcs3::ios::shared_config_database().load_cache();
		if (database_result.error == rpcs3::ios::config_database_error::none)
		{
			emit_log(database_result.skipped_configs == 0 ? 4 : 3,
				"Loaded cached title configuration database: " + database_result.detail);
		}
		else if (database_result.error == rpcs3::ios::config_database_error::cache_missing)
		{
			emit_log(4, database_result.detail);
		}
		else
		{
			emit_log(3, "Ignoring invalid cached title configuration database: " + database_result.detail);
		}
		rpcs3::ios::shared_pad_states().clear();
		rpcs3::ios::shared_pad_feedback().clear();
		const auto jit_stats = rpcs3::ios::jit::get_statistics();
		if (jit_stats.backend == rpcs3::ios::jit::arena_backend::universal_mirrored)
		{
			emit_log(4, fmt::format(
				"Prepared and sealed a %u MiB Universal JIT arena using the %s capacity policy in %u bounded command-1 chunks; StikDebug may now disconnect",
				jit_stats.capacity / (1024 * 1024),
				jit_stats.expanded ? "expanded" : "standard",
				jit_stats.preparation_chunks));
		}
		else
		{
			emit_log(4, fmt::format(
				"Prepared and sealed a %u MiB legacy debugger-enabled JIT arena using the %s capacity policy; no Universal commands were required",
				jit_stats.capacity / (1024 * 1024),
				jit_stats.expanded ? "expanded" : "standard"));
		}
		Emu.SetCallbacks(make_callbacks());
		Emu.SetSupportedRenderers({video_renderer::vulkan});
		Emu.SetDefaultRenderer(video_renderer::vulkan);
		Emu.SetDefaultGraphicsAdapter("iOS Metal GPU");
		Emu.SetHasGui(false);
		Emu.SetHeadless(false);
		Emu.SetUsr("00000001");
		g_emu_started = true;
		Emu.Init();
		g_lifecycle.finish_initialize(true);
		g_accept_display_surfaces = true;
		g_accept_pad_state = true;
		emit_log(4, "RPCS3 Emu.Init completed with the iOS Vulkan/MoltenVK and RemoteIO frontend");
		emit_log(4, "NEOSTATION_DYNAMIC_JIT_V5: low-address debugger-prepared RX/RW arena verified");
		emit_jit_arena_statistics("after core initialization");
		return RPCS3_IOS_OK;
	}
	catch (const std::exception& error)
	{
		set_error(error.what());
	}
	catch (...)
	{
		set_error("Unknown exception during Emu.Init");
	}

	g_accept_display_surfaces = false;
	g_accept_pad_state = false;
	rpcs3::ios::shared_pad_states().clear();
	rpcs3::ios::shared_pad_feedback().clear();
	g_lifecycle.finish_initialize(false);
	return RPCS3_IOS_CORE_INIT_FAILED;
}
'''
    text = text[:start] + new + text[end:]
    path.write_text(text)


def validate(root: Path) -> None:
    required = {
        "Utilities/JIT.h": [MARKER, "initialize_global_runtime", "if (!result)"],
        "Utilities/JITASM.cpp": [MARKER, "passive_global_runtime", "if (!p)", "if (!writable)"],
        "Utilities/JITIOS.cpp": [MARKER, "set_diagnostic_callback", "called before explicit JIT"],
        "rpcs3/Emu/Cell/PPUFunction.cpp": [MARKER, "initialize_ghc_trampolines", "list_ghc{nullptr, nullptr}"],
        "rpcs3/Emu/Cell/PPUThread.cpp": [MARKER, "ppu_initialize_static_trampolines", "static ppu_trampoline_t ppu_gateway = nullptr"],
        "rpcs3/Emu/Cell/SPUCommonRecompiler.cpp": [MARKER, "initialize_static_trampolines", "DECLARE(spu_runtime::g_gateway) = nullptr"],
        "rpcs3/ios/RPCS3IOS.cpp": [MARKER, "jit_initialize_begin", "asmjit_global_runtime_begin", "ppu_trampoline_init_begin", "spu_trampoline_init_begin", "jit_initialize_success"],
    }
    for rel, markers in required.items():
        content = (root / rel).read_text()
        for marker in markers:
            if marker not in content:
                raise RuntimeError(f"{rel}: missing {marker}")

    ppu_functions = (root / "rpcs3/Emu/Cell/PPUFunction.cpp").read_text()
    ppu = (root / "rpcs3/Emu/Cell/PPUThread.cpp").read_text()
    spu = (root / "rpcs3/Emu/Cell/SPUCommonRecompiler.cpp").read_text()
    access_start = ppu_functions.index("std::vector<ppu_intrp_func_t>& ppu_function_manager::access")
    init_start = ppu_functions.index("bool ppu_function_manager::initialize_ghc_trampolines")
    global_registry = ppu_functions[access_start:init_start]
    if "build_function_asm" in global_registry:
        raise RuntimeError("PPU HLE registration still builds JIT trampolines during global initialization")
    if "const auto ppu_gateway = build_function_asm" in ppu or "const extern auto ppu_escape = build_function_asm" in ppu:
        raise RuntimeError("PPU still builds JIT trampolines in global initializers")
    for name in ("tr_dispatch", "tr_branch", "tr_interpreter", "g_dispatcher", "tr_all", "g_gateway", "g_escape", "g_tail_escape"):
        if f"DECLARE(spu_runtime::{name}) = build_function_asm" in spu or f"DECLARE(spu_runtime::{name}) = []" in spu:
            raise RuntimeError(f"SPU global initializer remains for {name}")

    jit_ios = (root / "Utilities/JITIOS.cpp").read_text()
    diagnostic_declaration = "void emit_diagnostic(std::string message) noexcept;"
    diagnostic_definition = "void emit_diagnostic(std::string message) noexcept\n{"
    if diagnostic_declaration not in jit_ios:
        raise RuntimeError("JIT diagnostic emitter has no forward declaration")
    if jit_ios.index(diagnostic_declaration) > jit_ios.index("u8* reserve_arena_layout("):
        raise RuntimeError("JIT diagnostic emitter is declared after its first use")
    if jit_ios.index(diagnostic_declaration) > jit_ios.index(diagnostic_definition):
        raise RuntimeError("JIT diagnostic emitter declaration follows its definition")
    for function in ("runtime_memory", "arena_capacity", "claim_runtime", "allocate"):
        begin = jit_ios.index(function + "(")
        body = jit_ios[begin : jit_ios.index("\n}", begin) + 2]
        if "prepare_arena(" in body:
            raise RuntimeError(f"{function} still performs implicit arena preparation")


def patch(root: Path) -> None:
    files = (
        root / "Utilities/JIT.h",
        root / "Utilities/JITASM.cpp",
        root / "Utilities/JITIOS.h",
        root / "Utilities/JITIOS.cpp",
        root / "rpcs3/Emu/Cell/PPUFunction.h",
        root / "rpcs3/Emu/Cell/PPUFunction.cpp",
        root / "rpcs3/Emu/Cell/PPUThread.h",
        root / "rpcs3/Emu/Cell/PPUThread.cpp",
        root / "rpcs3/Emu/Cell/SPURecompiler.h",
        root / "rpcs3/Emu/Cell/SPUCommonRecompiler.cpp",
        root / "rpcs3/ios/RPCS3IOS.cpp",
    )
    if all(MARKER in path.read_text() for path in files):
        validate(root)
        print("Build 301 passive dlopen architecture already applied and verified")
        return
    if any(MARKER in path.read_text() for path in files):
        raise RuntimeError("Build 301 partial postimage detected")

    patch_jit_header(root)
    patch_jit_asm(root)
    patch_jit_ios_header(root)
    patch_jit_ios(root)
    patch_ppu_function_header(root)
    patch_ppu_function(root)
    patch_ppu_header(root)
    patch_ppu(root)
    patch_spu_header(root)
    patch_spu(root)
    patch_ios_api(root)
    validate(root)
    print("Build 301 passive dlopen architecture applied")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: patch_rpcs3_build301_passive_dlopen.py <pinned-rpcs3-source>")
    patch(Path(sys.argv[1]).resolve())
