"""Explicit rpcs3_ios_initialize ownership of iOS JIT startup."""
from __future__ import annotations
from pathlib import Path
from .common import MARKER, PatchError, replace_once


def patch_ios_api(root: Path) -> None:
    path = root / "rpcs3/ios/RPCS3IOS.cpp"
    text = path.read_text(encoding="utf-8")
    if f"jit_initialize_begin marker={MARKER}" in text:
        validate_ios_api(text)
        return

    include_anchor = "#include <vector>\n\nnamespace\n{\n"
    declarations = f"""#include <vector>

bool neostation_initialize_ppu_jit(std::string& error) noexcept;
bool neostation_initialize_spu_jit(std::string& error) noexcept;

namespace
{{
"""
    text = replace_once(text, include_anchor, declarations, "deferred JIT forward declarations")

    json_anchor = r'\"jit\":'
    if text.count(json_anchor) != 1:
        raise PatchError(f"build-info JIT field: expected one anchor, found {text.count(json_anchor)}")
    text = text.replace(json_anchor, rf'\"deferred_jit\":\"{MARKER}\",' + json_anchor, 1)

    old = """\tif (!rpcs3::ios::jit::is_ready())
\t{
\t\tset_error(rpcs3::ios::jit::last_error());
\t\tg_lifecycle.finish_initialize(false);
\t\treturn RPCS3_IOS_JIT_UNAVAILABLE;
\t}
\tif (!rpcs3::ios::jit::prepare_arena(config->expanded_jit_arena) ||
\t\t!rpcs3::ios::jit::seal_arena())
\t{
\t\tset_error(rpcs3::ios::jit::last_error());
\t\tg_lifecycle.finish_initialize(false);
\t\treturn RPCS3_IOS_JIT_MAPPING_FAILED;
\t}

\ttry
\t{
\t\tg_application_support_path = config->application_support_path;
\t\trpcs3::ios::initialize_graphics_lifecycle();
\t\tg_cache_path = config->cache_path;
\t\tg_config = *config;
\t\tg_config.application_support_path = g_application_support_path.c_str();
\t\tg_config.cache_path = g_cache_path.c_str();
\t\tg_rpcn_config_loaded = false;
\t\tg_rpcn_client.reset();

\t\tif (!fs::set_config_dir(g_config.application_support_path) || !fs::set_cache_dir(g_config.cache_path))
\t\t{
\t\t\tset_error(\"Unable to configure writable RPCS3 sandbox directories\");
\t\t\tg_lifecycle.finish_initialize(false);
\t\t\treturn RPCS3_IOS_INVALID_ARGUMENT;
\t\t}

\t\tg_log_listener = std::make_unique<callback_log_listener>();
\t\tlogs::listener::add(g_log_listener.get());
"""
    new = f"""\ttry
\t{{
\t\t// {MARKER}: install the callback and sandbox paths before any JIT work,
\t\t// then make this function the sole owner of arena/trampoline creation.
\t\tg_application_support_path = config->application_support_path;
\t\trpcs3::ios::initialize_graphics_lifecycle();
\t\tg_cache_path = config->cache_path;
\t\tg_config = *config;
\t\tg_config.application_support_path = g_application_support_path.c_str();
\t\tg_config.cache_path = g_cache_path.c_str();
\t\tg_rpcn_config_loaded = false;
\t\tg_rpcn_client.reset();

\t\tif (!fs::set_config_dir(g_config.application_support_path) || !fs::set_cache_dir(g_config.cache_path))
\t\t{{
\t\t\tset_error(\"Unable to configure writable RPCS3 sandbox directories\");
\t\t\tg_lifecycle.finish_initialize(false);
\t\t\treturn RPCS3_IOS_INVALID_ARGUMENT;
\t\t}}

\t\tif (!g_log_listener)
\t\t{{
\t\t\tg_log_listener = std::make_unique<callback_log_listener>();
\t\t\tlogs::listener::add(g_log_listener.get());
\t\t}}
\t\trpcs3::ios::jit::set_diagnostic_callback(+[](void*, const char* message) noexcept
\t\t{{
\t\t\tif (message && message[0])
\t\t\t{{
\t\t\t\temit_log(4, message);
\t\t\t}}
\t\t}}, nullptr);

\t\tauto fail_jit = [&](rpcs3_ios_status status, std::string_view stage, std::string detail = {{}}) -> rpcs3_ios_status
\t\t{{
\t\t\tif (const char* native = rpcs3::ios::jit::last_error(); native && native[0])
\t\t\t{{
\t\t\t\tif (!detail.empty())
\t\t\t\t{{
\t\t\t\t\tdetail += \"; native=\";
\t\t\t\t}}
\t\t\t\tdetail += native;
\t\t\t}}
\t\t\tstd::string message = \"jit_initialize_failed stage=\" + std::string(stage);
\t\t\tif (!detail.empty())
\t\t\t{{
\t\t\t\tmessage += \" detail=\";
\t\t\t\tmessage += detail;
\t\t\t}}
\t\t\temit_log(1, message);
\t\t\tset_error(message);
\t\t\tg_lifecycle.finish_initialize(false);
\t\t\treturn status;
\t\t}};

\t\temit_log(4, \"jit_initialize_begin marker={MARKER}\");
\t\tif (!rpcs3::ios::jit::is_ready())
\t\t{{
\t\t\treturn fail_jit(RPCS3_IOS_JIT_UNAVAILABLE, \"readiness\");
\t\t}}
\t\tif (!rpcs3::ios::jit::prepare_arena(config->expanded_jit_arena))
\t\t{{
\t\t\treturn fail_jit(RPCS3_IOS_JIT_MAPPING_FAILED, \"arena_prepare\");
\t\t}}
\t\tconst auto prepared_stats = rpcs3::ios::jit::get_statistics();
\t\temit_log(4, fmt::format(
\t\t\t\"requested_code_capacity=%u requested_data_capacity=%u\",
\t\t\tprepared_stats.capacity, prepared_stats.data_capacity));

\t\tstd::string initialization_error;
\t\temit_log(4, \"asmjit_global_runtime_begin\");
\t\tif (!asmjit::initialize_global_runtime(initialization_error))
\t\t{{
\t\t\treturn fail_jit(RPCS3_IOS_JIT_MAPPING_FAILED, \"asmjit_global_runtime\", initialization_error);
\t\t}}
\t\temit_log(4, \"asmjit_global_runtime_end\");

\t\temit_log(4, \"ppu_trampoline_init_begin\");
\t\tif (!neostation_initialize_ppu_jit(initialization_error))
\t\t{{
\t\t\treturn fail_jit(RPCS3_IOS_JIT_MAPPING_FAILED, \"ppu_trampolines\", initialization_error);
\t\t}}
\t\temit_log(4, \"ppu_trampoline_init_end\");

\t\temit_log(4, \"spu_trampoline_init_begin\");
\t\tif (!neostation_initialize_spu_jit(initialization_error))
\t\t{{
\t\t\treturn fail_jit(RPCS3_IOS_JIT_MAPPING_FAILED, \"spu_trampolines\", initialization_error);
\t\t}}
\t\temit_log(4, \"spu_trampoline_init_end\");

\t\tif (!rpcs3::ios::jit::seal_arena())
\t\t{{
\t\t\treturn fail_jit(RPCS3_IOS_JIT_MAPPING_FAILED, \"arena_seal\");
\t\t}}
\t\temit_log(4, \"jit_initialize_success\");
"""
    text = replace_once(text, old, new, "explicit iOS JIT initialization sequence")
    validate_ios_api(text)
    path.write_text(text, encoding="utf-8")


def validate_ios_api(text: str) -> None:
    sequence = (
        "jit_initialize_begin",
        "asmjit_global_runtime_begin",
        "asmjit_global_runtime_end",
        "ppu_trampoline_init_begin",
        "ppu_trampoline_init_end",
        "spu_trampoline_init_begin",
        "spu_trampoline_init_end",
        "jit_initialize_success",
        "Emu.Init();",
    )
    positions = [text.find(token) for token in sequence]
    if any(position < 0 for position in positions):
        missing = [token for token, position in zip(sequence, positions) if position < 0]
        raise PatchError(f"iOS API validation missing sequence entries: {missing}")
    if positions != sorted(positions):
        raise PatchError("iOS JIT initialization sequence is out of order")
    if text.count("neostation_initialize_ppu_jit(initialization_error)") != 1:
        raise PatchError("PPU explicit initializer must be called exactly once")
    if text.count("neostation_initialize_spu_jit(initialization_error)") != 1:
        raise PatchError("SPU explicit initializer must be called exactly once")
    if text.count("asmjit::initialize_global_runtime(initialization_error)") != 1:
        raise PatchError("AsmJIT explicit initializer must be called exactly once")
    if "prepare_arena(config->expanded_jit_arena) ||" in text:
        raise PatchError("old combined prepare/seal path remains")
    if MARKER not in text:
        raise PatchError("iOS API build marker is missing")
