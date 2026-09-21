"""JIT arena/runtime part of the deferred RPCS3 iOS initialization patch."""
from __future__ import annotations
from pathlib import Path
from .common import MARKER, PatchError, replace_once

def patch_jit_header(root: Path) -> None:
    path = root / "Utilities/JIT.h"
    text = path.read_text(encoding="utf-8")
    if f"bool initialize_global_runtime(std::string& error) noexcept; // {MARKER}" in text:
        return
    anchor = "\tjit_runtime_base& get_global_runtime();\n"
    addition = anchor + f"\n#ifdef RPCS3_IOS\n\tbool initialize_global_runtime(std::string& error) noexcept; // {MARKER}\n#endif\n"
    path.write_text(replace_once(text, anchor, addition, "JIT global-runtime declaration"), encoding="utf-8")


def patch_jit_asm(root: Path) -> None:
    path = root / "Utilities/JITASM.cpp"
    text = path.read_text(encoding="utf-8")
    if MARKER in text:
        validate_jit_asm(text)
        return

    text = replace_once(
        text,
        "\t// Select subrange\n\tu8* pointer = ensure(get_jit_memory(Executable));\n#ifdef RPCS3_IOS\n\tconst u64 capacity = rpcs3::ios::jit::arena_capacity(Executable);\n\tensure(capacity);\n#else\n",
        f"""\t// Select subrange. {MARKER}: a normal iOS mapping/allocation failure
\t// is returned to rpcs3_ios_initialize instead of aborting NeoStation.
#ifdef RPCS3_IOS
\tu8* pointer = get_jit_memory(Executable);
\tconst u64 capacity = rpcs3::ios::jit::arena_capacity(Executable);
\tif (!pointer || !capacity)
\t{{
\t\tjit_log.error(\"iOS JIT %s arena is unavailable: %s\", Executable ? \"code\" : \"data\", rpcs3::ios::jit::last_error());
\t\treturn nullptr;
\t}}
#else
\tu8* pointer = ensure(get_jit_memory(Executable));
""",
        "recoverable add_jit_memory prologue",
    )

    text = replace_once(
        text,
        "\tauto p = ensure(this->_alloc(codeSize, align));\n\tensure(!code->relocateToBase(uptr(p)));\n",
        f"""\tauto p = this->_alloc(codeSize, align);
#ifdef RPCS3_IOS
\tif (!p) [[unlikely]]
\t{{
\t\treturn nullptr; // {MARKER}
\t}}
#else
\tp = ensure(p);
#endif
\tensure(!code->relocateToBase(uptr(p)));
""",
        "recoverable AsmJIT allocation",
    )

    text = replace_once(
        text,
        "#ifdef RPCS3_IOS\n\t\twritable = ensure(static_cast<uchar*>(rpcs3::ios::jit::writable(p, codeSize)));\n#endif\n",
        f"""#ifdef RPCS3_IOS
\t\twritable = static_cast<uchar*>(rpcs3::ios::jit::writable(p, codeSize));
\t\tif (!writable) [[unlikely]]
\t\t{{
\t\t\treturn nullptr; // {MARKER}
\t\t}}
#endif
""",
        "recoverable writable alias",
    )

    text = replace_once(
        text,
        "jit_runtime_base& asmjit::get_global_runtime()\n{\n",
        f"""#ifdef RPCS3_IOS
static bool s_ios_global_runtime_ready = false; // {MARKER}
#endif

jit_runtime_base& asmjit::get_global_runtime()
{{
""",
        "global-runtime readiness state",
    )

    text = replace_once(
        text,
        "#ifdef RPCS3_IOS\n\t\t\tensure(m_pos.raw() = static_cast<uchar*>(rpcs3::ios::jit::allocate(true, size, 64)));\n#else\n\t\t\tensure(m_pos.raw() = static_cast<uchar*>(utils::memory_reserve(size, true)));\n#endif\n\n\t\t\t// Initialize \"end\" pointer\n\t\t\tm_max = m_pos + size;\n",
        f"""#ifdef RPCS3_IOS
\t\t\tm_pos.raw() = static_cast<uchar*>(rpcs3::ios::jit::allocate(true, size, 64));
\t\t\tif (!m_pos.raw())
\t\t\t{{
\t\t\t\treturn; // {MARKER}: caller receives an initialization error.
\t\t\t}}
\t\t\ts_ios_global_runtime_ready = true;
#else
\t\t\tensure(m_pos.raw() = static_cast<uchar*>(utils::memory_reserve(size, true)));
#endif

\t\t\t// Initialize \"end\" pointer only after the allocation succeeded.
\t\t\tm_max = m_pos + size;
""",
        "non-fatal global-runtime constructor",
    )

    text = replace_once(
        text,
        "\t\tuchar* _alloc(usz size, usz align) noexcept override\n\t\t{\n\t\t\treturn m_pos.atomic_op([&](uchar*& pos) -> uchar*\n",
        f"""\t\tuchar* _alloc(usz size, usz align) noexcept override
\t\t{{
#ifdef RPCS3_IOS
\t\t\tif (!m_max) [[unlikely]]
\t\t\t{{
\t\t\t\treturn nullptr; // {MARKER}
\t\t\t}}
#endif
\t\t\treturn m_pos.atomic_op([&](uchar*& pos) -> uchar*
""",
        "global-runtime null guard",
    )

    insertion = f"""
#ifdef RPCS3_IOS
bool asmjit::initialize_global_runtime(std::string& error) noexcept
{{
\tstatic bool attempted = false;
\tstatic bool initialized = false;
\tif (initialized)
\t{{
\t\treturn true;
\t}}
\tif (attempted)
\t{{
\t\terror = \"AsmJIT global runtime initialization already failed; relaunch NeoStation\";
\t\treturn false;
\t}}
\tattempted = true;
\tstatic_cast<void>(get_global_runtime());
\tif (!s_ios_global_runtime_ready)
\t{{
\t\tconst char* detail = rpcs3::ios::jit::last_error();
\t\terror = \"Unable to allocate the 16 MiB AsmJIT global runtime\";
\t\tif (detail && detail[0])
\t\t{{
\t\t\terror += \": \";
\t\t\terror += detail;
\t\t}}
\t\treturn false;
\t}}
\tinitialized = true;
\treturn true;
}}
#endif

"""
    anchor = "asmjit::inline_runtime::inline_runtime(uchar* data, usz size)\n"
    text = replace_once(text, anchor, insertion + anchor, "explicit global-runtime initializer")
    validate_jit_asm(text)
    path.write_text(text, encoding="utf-8")


def validate_jit_asm(text: str) -> None:
    required = (
        MARKER,
        "bool asmjit::initialize_global_runtime(std::string& error) noexcept",
        "if (!p) [[unlikely]]",
        "if (!writable) [[unlikely]]",
        "s_ios_global_runtime_ready",
    )
    for token in required:
        if token not in text:
            raise PatchError(f"JITASM validation missing {token!r}")
    forbidden = (
        "u8* pointer = ensure(get_jit_memory(Executable));\n#ifdef RPCS3_IOS",
        "ensure(m_pos.raw() = static_cast<uchar*>(rpcs3::ios::jit::allocate",
        "writable = ensure(static_cast<uchar*>(rpcs3::ios::jit::writable",
    )
    for token in forbidden:
        if token in text:
            raise PatchError(f"JITASM retained fatal iOS allocation path {token!r}")


def patch_jit_ios_header(root: Path) -> None:
    path = root / "Utilities/JITIOS.h"
    text = path.read_text(encoding="utf-8")
    token = f"using diagnostic_callback = void (*)(void*, const char*) noexcept; // {MARKER}"
    if token in text:
        return
    anchor = "struct arena_statistics\n"
    addition = f"""using diagnostic_callback = void (*)(void*, const char*) noexcept; // {MARKER}
void set_diagnostic_callback(diagnostic_callback callback, void* context) noexcept;

{anchor}"""
    path.write_text(replace_once(text, anchor, addition, "JIT diagnostic callback declaration"), encoding="utf-8")


def patch_jit_ios(root: Path) -> None:
    path = root / "Utilities/JITIOS.cpp"
    text = path.read_text(encoding="utf-8")
    if MARKER in text:
        validate_jit_ios(text)
        return

    text = replace_once(
        text,
        "std::mutex g_protocol_mutex;\nstd::mutex g_arena_mutex;\nstd::mutex g_error_mutex;\n",
        f"""std::mutex g_protocol_mutex;
std::mutex g_arena_mutex;
std::mutex g_error_mutex;
std::mutex g_diagnostic_mutex; // {MARKER}
rpcs3::ios::jit::diagnostic_callback g_diagnostic_callback = nullptr;
void* g_diagnostic_context = nullptr;
""",
        "JIT diagnostic state",
    )

    set_error_anchor = "void set_error(std::string message) noexcept\n{\n"
    diagnostic_helper = f"""void emit_jit_diagnostic(std::string message) noexcept
{{
\trpcs3::ios::jit::diagnostic_callback callback = nullptr;
\tvoid* context = nullptr;
\t{{
\t\tstd::lock_guard lock(g_diagnostic_mutex);
\t\tcallback = g_diagnostic_callback;
\t\tcontext = g_diagnostic_context;
\t}}
\tif (callback)
\t{{
\t\tcallback(context, message.c_str());
\t}}
}}

// {MARKER}
{set_error_anchor}"""
    text = replace_once(text, set_error_anchor, diagnostic_helper, "JIT diagnostic emitter")

    text = replace_once(
        text,
        "\tstd::lock_guard lock(g_error_mutex);\n\tg_last_error = std::move(message);\n}",
        "\temit_jit_diagnostic(\"jit_error message=\" + message);\n\tstd::lock_guard lock(g_error_mutex);\n\tg_last_error = std::move(message);\n}",
        "JIT error diagnostic",
    )

    text = replace_once(
        text,
        "\t\tvm_address_t address = candidate;\n\t\tconst kern_return_t result = ::vm_allocate(\n",
        "\t\temit_jit_diagnostic(\"reservation_candidate address=\" + std::to_string(candidate) +\n\t\t\t\" size=\" + std::to_string(size));\n\t\tvm_address_t address = candidate;\n\t\tconst kern_return_t result = ::vm_allocate(\n",
        "reservation candidate diagnostic",
    )
    text = replace_once(
        text,
        "\t\t\tVM_FLAGS_FIXED | jit_vm_tag);\n\t\tif (result != KERN_SUCCESS || address != candidate)\n",
        "\t\t\tVM_FLAGS_FIXED | jit_vm_tag);\n\t\temit_jit_diagnostic(\"reservation_result address=\" + std::to_string(address) +\n\t\t\t\" size=\" + std::to_string(size) + \" kern_return_t=\" + std::to_string(result));\n\t\tif (result != KERN_SUCCESS || address != candidate)\n",
        "reservation result diagnostic",
    )

    text = replace_once(
        text,
        "\tconst usz capacity = choose_arena_capacity(physical_memory_size(), expanded_capacity_mib);\n\tusz data_capacity = 0;\n",
        "\tconst usz capacity = choose_arena_capacity(physical_memory_size(), expanded_capacity_mib);\n\temit_jit_diagnostic(\"requested_code_capacity=\" + std::to_string(capacity) +\n\t\t\" requested_data_capacity=\" + std::to_string(capacity));\n\tusz data_capacity = 0;\n",
        "requested capacity diagnostic",
    )
    text = replace_once(
        text,
        "\tu8* const layout = reserve_code_data_layout(capacity, data, data_capacity);\n\tif (!layout)\n",
        "\tu8* const layout = reserve_code_data_layout(capacity, data, data_capacity);\n\temit_jit_diagnostic(\"reservation_result code_address=\" +\n\t\tstd::to_string(reinterpret_cast<uptr>(layout)) + \" data_address=\" +\n\t\tstd::to_string(reinterpret_cast<uptr>(data)) + \" data_capacity=\" +\n\t\tstd::to_string(data_capacity));\n\tif (!layout)\n",
        "arena layout result diagnostic",
    )

    text = replace_once(
        text,
        "\tif (!map_arena_region(layout, capacity, initial_code_protection))\n\t{\n\t\tconst std::string detail = std::strerror(errno);\n",
        "\terrno = 0;\n\tconst bool map_code_ok = map_arena_region(layout, capacity, initial_code_protection);\n\tconst int map_code_errno = errno;\n\temit_jit_diagnostic(\"map_code_result success=\" + std::to_string(map_code_ok) +\n\t\t\" errno=\" + std::to_string(map_code_errno) + \" address=\" +\n\t\tstd::to_string(reinterpret_cast<uptr>(layout)) + \" size=\" + std::to_string(capacity));\n\tif (!map_code_ok)\n\t{\n\t\tconst std::string detail = std::strerror(map_code_errno);\n",
        "code mapping diagnostic",
    )
    text = replace_once(
        text,
        "\tif (!map_arena_region(data, data_capacity, PROT_READ | PROT_WRITE))\n\t{\n\t\tconst std::string detail = std::strerror(errno);\n",
        "\terrno = 0;\n\tconst bool map_data_ok = map_arena_region(data, data_capacity, PROT_READ | PROT_WRITE);\n\tconst int map_data_errno = errno;\n\temit_jit_diagnostic(\"map_data_result success=\" + std::to_string(map_data_ok) +\n\t\t\" errno=\" + std::to_string(map_data_errno) + \" address=\" +\n\t\tstd::to_string(reinterpret_cast<uptr>(data)) + \" size=\" + std::to_string(data_capacity));\n\tif (!map_data_ok)\n\t{\n\t\tconst std::string detail = std::strerror(map_data_errno);\n",
        "data mapping diagnostic",
    )

    text = replace_once(
        text,
        "\t\tpreparation_chunks = arena_prepare_chunk_count(capacity);\n\t\tfor (u32 chunk_index = 0; chunk_index < preparation_chunks; ++chunk_index)\n",
        "\t\tpreparation_chunks = arena_prepare_chunk_count(capacity);\n\t\temit_jit_diagnostic(\"universal_prepare_begin chunks=\" + std::to_string(preparation_chunks));\n\t\tfor (u32 chunk_index = 0; chunk_index < preparation_chunks; ++chunk_index)\n",
        "Universal preparation begin diagnostic",
    )
    text = replace_once(
        text,
        "\t\t\tu8* const chunk = layout + offset;\n\t\t\tconst u64 response = chunk_length ? protocol_call(command_prepare_region, chunk, chunk_length) : 0;\n",
        "\t\t\tu8* const chunk = layout + offset;\n\t\t\temit_jit_diagnostic(\"universal_prepare_chunk index=\" + std::to_string(chunk_index) +\n\t\t\t\t\" address=\" + std::to_string(reinterpret_cast<uptr>(chunk)) +\n\t\t\t\t\" size=\" + std::to_string(chunk_length));\n\t\t\tconst u64 response = chunk_length ? protocol_call(command_prepare_region, chunk, chunk_length) : 0;\n\t\t\temit_jit_diagnostic(\"universal_prepare_result index=\" + std::to_string(chunk_index) +\n\t\t\t\t\" response=\" + std::to_string(response));\n",
        "Universal preparation chunk diagnostic",
    )

    text = replace_once(
        text,
        "\t\tVM_INHERIT_SHARE);\n\tif (remap_result != KERN_SUCCESS)\n",
        "\t\tVM_INHERIT_SHARE);\n\temit_jit_diagnostic(\"writable_alias_result stage=remap kern_return_t=\" +\n\t\tstd::to_string(remap_result) + \" address=\" + std::to_string(alias) +\n\t\t\" size=\" + std::to_string(capacity));\n\tif (remap_result != KERN_SUCCESS)\n",
        "writable alias remap diagnostic",
    )
    text = replace_once(
        text,
        "\tif (::vm_protect(mach_task_self(), alias, static_cast<vm_size_t>(capacity), false,\n\t\tVM_PROT_READ | VM_PROT_WRITE) != KERN_SUCCESS)\n\t{\n",
        "\tconst kern_return_t alias_protect_result = ::vm_protect(\n\t\tmach_task_self(), alias, static_cast<vm_size_t>(capacity), false,\n\t\tVM_PROT_READ | VM_PROT_WRITE);\n\temit_jit_diagnostic(\"writable_alias_result stage=protect kern_return_t=\" +\n\t\tstd::to_string(alias_protect_result) + \" address=\" + std::to_string(alias) +\n\t\t\" size=\" + std::to_string(capacity));\n\tif (alias_protect_result != KERN_SUCCESS)\n\t{\n",
        "writable alias protection diagnostic",
    )

    namespace_anchor = "namespace rpcs3::ios::jit\n{\nbool is_ready() noexcept\n"
    namespace_replacement = f"""namespace rpcs3::ios::jit
{{
void set_diagnostic_callback(diagnostic_callback callback, void* context) noexcept
{{
\tstd::lock_guard lock(g_diagnostic_mutex);
\tg_diagnostic_callback = callback;
\tg_diagnostic_context = context;
}}

// {MARKER}
bool is_ready() noexcept
"""
    text = replace_once(text, namespace_anchor, namespace_replacement, "JIT diagnostic callback setter")
    validate_jit_ios(text)
    path.write_text(text, encoding="utf-8")


def validate_jit_ios(text: str) -> None:
    for token in (
        MARKER,
        "requested_code_capacity=",
        "reservation_candidate address=",
        "map_code_result success=",
        "map_data_result success=",
        "universal_prepare_begin chunks=",
        "universal_prepare_chunk index=",
        "universal_prepare_result index=",
        "writable_alias_result stage=remap",
        "writable_alias_result stage=protect",
        "void set_diagnostic_callback(diagnostic_callback callback, void* context) noexcept",
    ):
        if token not in text:
            raise PatchError(f"JITIOS validation missing {token!r}")
