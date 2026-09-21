"""PPU/SPU trampoline deferral for the embedded RPCS3 iOS Core."""
from __future__ import annotations
from pathlib import Path
from .common import MARKER, PatchError, _all_initializers, _wrap_initializer, replace_once


def patch_ppu(root: Path) -> None:
    path = root / "rpcs3/Emu/Cell/PPUThread.cpp"
    text = path.read_text(encoding="utf-8")
    if f"bool neostation_initialize_ppu_jit(std::string& error) noexcept // {MARKER}" in text:
        validate_ppu(text)
        return

    targets = [
        (
            "const auto ppu_gateway =",
            "constinit void (*ppu_gateway)(ppu_thread*) = nullptr;",
            "neostation_build_ppu_gateway",
            "void (*)(ppu_thread*)",
            1,
        ),
        (
            "const extern auto ppu_escape =",
            "constinit void (*ppu_escape)(ppu_thread*) = nullptr;",
            "neostation_build_ppu_escape",
            "void (*)(ppu_thread*)",
            1,
        ),
    ]
    for anchor, declaration, builder, return_type, expected in targets:
        items = _all_initializers(text, anchor)
        if len(items) != expected:
            raise PatchError(f"{anchor}: expected {expected} initializer(s), found {len(items)}")
        for item in reversed(items):
            text = _wrap_initializer(text, item, declaration, builder, return_type)

    fallback_anchor = "const auto ppu_recompiler_fallback_ghc ="
    fallback_items = _all_initializers(text, fallback_anchor)
    if len(fallback_items) != 2:
        raise PatchError(f"PPU fallback: expected two architecture initializers, found {len(fallback_items)}")
    for item in reversed(fallback_items):
        text = _wrap_initializer(
            text,
            item,
            "constinit void (*ppu_recompiler_fallback_ghc)(ppu_thread&) = nullptr;",
            "neostation_build_ppu_recompiler_fallback",
            "void (*)(ppu_thread&)",
        )

    initializer = f"""

#ifdef RPCS3_IOS
bool neostation_initialize_ppu_jit(std::string& error) noexcept // {MARKER}
{{
\tstatic bool attempted = false;
\tstatic bool initialized = false;
\tif (initialized)
\t{{
\t\treturn true;
\t}}
\tif (attempted)
\t{{
\t\terror = \"PPU trampoline initialization already failed; relaunch NeoStation\";
\t\treturn false;
\t}}
\tattempted = true;
\ttry
\t{{
\t\tppu_gateway = neostation_build_ppu_gateway();
\t\tif (!ppu_gateway)
\t\t{{
\t\t\terror = \"ppu_gateway allocation failed\";
\t\t\treturn false;
\t\t}}
\t\tppu_escape = neostation_build_ppu_escape();
\t\tif (!ppu_escape)
\t\t{{
\t\t\terror = \"ppu_escape allocation failed\";
\t\t\treturn false;
\t\t}}
\t\tppu_recompiler_fallback_ghc = neostation_build_ppu_recompiler_fallback();
\t\tif (!ppu_recompiler_fallback_ghc)
\t\t{{
\t\t\terror = \"ppu_recompiler_fallback_ghc allocation failed\";
\t\t\treturn false;
\t\t}}
\t}}
\tcatch (const std::exception& exception)
\t{{
\t\terror = std::string(\"PPU trampoline construction failed: \") + exception.what();
\t\treturn false;
\t}}
\tcatch (...)
\t{{
\t\terror = \"PPU trampoline construction failed with an unknown exception\";
\t\treturn false;
\t}}
\tinitialized = true;
\treturn true;
}}
#endif
"""
    text += initializer
    validate_ppu(text)
    path.write_text(text, encoding="utf-8")


def validate_ppu(text: str) -> None:
    required = (
        f"bool neostation_initialize_ppu_jit(std::string& error) noexcept // {MARKER}",
        "constinit void (*ppu_gateway)(ppu_thread*) = nullptr;",
        "constinit void (*ppu_escape)(ppu_thread*) = nullptr;",
        "constinit void (*ppu_recompiler_fallback_ghc)(ppu_thread&) = nullptr;",
        "neostation_build_ppu_gateway",
        "neostation_build_ppu_escape",
        "neostation_build_ppu_recompiler_fallback",
    )
    for token in required:
        if token not in text:
            raise PatchError(f"PPU validation missing {token!r}")
    if text.count("constinit void (*ppu_gateway)(ppu_thread*) = nullptr;") != 1:
        raise PatchError("PPU gateway has more than one iOS owner")
    if text.count("constinit void (*ppu_recompiler_fallback_ghc)(ppu_thread&) = nullptr;") != 2:
        raise PatchError("PPU fallback architecture definitions drifted")


def patch_spu_header(root: Path) -> None:
    path = root / "rpcs3/Emu/Cell/SPURecompiler.h"
    text = path.read_text(encoding="utf-8")
    replacements = (
        ("\tstatic const spu_function_t tr_dispatch;", "\tstatic spu_function_t tr_dispatch;"),
        ("\tstatic const spu_function_t tr_branch;", "\tstatic spu_function_t tr_branch;"),
        ("\tstatic const spu_function_t tr_interpreter;", "\tstatic spu_function_t tr_interpreter;"),
        ("\tstatic const spu_function_t tr_all;", "\tstatic spu_function_t tr_all;"),
        ("\tstatic std::array<atomic_t<spu_function_t>, (1 << 20)>* const g_dispatcher;", "\tstatic std::array<atomic_t<spu_function_t>, (1 << 20)>* g_dispatcher;"),
        ("\tstatic const spu_function_t g_gateway;", "\tstatic spu_function_t g_gateway;"),
        ("\tstatic void(*const g_escape)(spu_thread*);", "\tstatic void(*g_escape)(spu_thread*);"),
        ("\tstatic void(*const g_tail_escape)(spu_thread*, spu_function_t, u8*);", "\tstatic void(*g_tail_escape)(spu_thread*, spu_function_t, u8*);"),
    )
    changed = False
    for old, new in replacements:
        if old in text:
            text = replace_once(text, old, new, f"SPU mutable declaration {old.strip()}")
            changed = True
        elif new not in text:
            raise PatchError(f"SPU declaration missing both old and new forms: {old!r}")
    if changed:
        text = text.replace("class spu_runtime\n{", f"// {MARKER}\nclass spu_runtime\n{{", 1)
        path.write_text(text, encoding="utf-8")


def patch_spu(root: Path) -> None:
    path = root / "rpcs3/Emu/Cell/SPUCommonRecompiler.cpp"
    text = path.read_text(encoding="utf-8")
    if f"bool neostation_initialize_spu_jit(std::string& error) noexcept // {MARKER}" in text:
        validate_spu(text)
        return

    text = replace_once(
        text,
        "\tconst auto ptr = reinterpret_cast<std::remove_const_t<decltype(spu_runtime::g_dispatcher)>>(jit_runtime::alloc(sizeof(*g_dispatcher), 64, false));\n\n\tfor (auto& x : *ptr)\n",
        f"""\tconst auto ptr = reinterpret_cast<std::remove_const_t<decltype(spu_runtime::g_dispatcher)>>(jit_runtime::alloc(sizeof(*g_dispatcher), 64, false));
\tif (!ptr)
\t{{
\t\treturn std::remove_const_t<decltype(ptr)>{{}}; // {MARKER}: propagate data-arena exhaustion.
\t}}

\tfor (auto& x : *ptr)
""",
        "SPU dispatcher allocation guard",
    )

    definitions = (
        ("DECLARE(spu_runtime::tr_dispatch) =", "tr_dispatch"),
        ("DECLARE(spu_runtime::tr_branch) =", "tr_branch"),
        ("DECLARE(spu_runtime::tr_interpreter) =", "tr_interpreter"),
        ("DECLARE(spu_runtime::g_dispatcher) =", "g_dispatcher"),
        ("DECLARE(spu_runtime::tr_all) =", "tr_all"),
        ("DECLARE(spu_runtime::g_gateway) =", "g_gateway"),
        ("DECLARE(spu_runtime::g_escape) =", "g_escape"),
        ("DECLARE(spu_runtime::g_tail_escape) =", "g_tail_escape"),
    )
    for anchor, name in definitions:
        items = _all_initializers(text, anchor)
        if len(items) != 1:
            raise PatchError(f"SPU {name}: expected one initializer, found {len(items)}")
        text = _wrap_initializer(
            text,
            items[0],
            f"constinit DECLARE(spu_runtime::{name}) = nullptr;",
            f"neostation_build_spu_{name}",
            f"decltype(spu_runtime::{name})",
        )

    initializer = f"""

#ifdef RPCS3_IOS
bool neostation_initialize_spu_jit(std::string& error) noexcept // {MARKER}
{{
\tstatic bool attempted = false;
\tstatic bool initialized = false;
\tif (initialized)
\t{{
\t\treturn true;
\t}}
\tif (attempted)
\t{{
\t\terror = \"SPU trampoline initialization already failed; relaunch NeoStation\";
\t\treturn false;
\t}}
\tattempted = true;
\ttry
\t{{
\t\tauto initialize = [&](auto& target, auto&& builder, const char* name) -> bool
\t\t{{
\t\t\ttarget = builder();
\t\t\tif (!target)
\t\t\t{{
\t\t\t\terror = std::string(name) + \" allocation failed\";
\t\t\t\treturn false;
\t\t\t}}
\t\t\treturn true;
\t\t}};
\t\tif (!initialize(spu_runtime::tr_dispatch, neostation_build_spu_tr_dispatch, \"spu tr_dispatch\") ||
\t\t\t!initialize(spu_runtime::tr_branch, neostation_build_spu_tr_branch, \"spu tr_branch\") ||
\t\t\t!initialize(spu_runtime::tr_interpreter, neostation_build_spu_tr_interpreter, \"spu tr_interpreter\") ||
\t\t\t!initialize(spu_runtime::g_dispatcher, neostation_build_spu_g_dispatcher, \"spu g_dispatcher\") ||
\t\t\t!initialize(spu_runtime::tr_all, neostation_build_spu_tr_all, \"spu tr_all\") ||
\t\t\t!initialize(spu_runtime::g_gateway, neostation_build_spu_g_gateway, \"spu g_gateway\") ||
\t\t\t!initialize(spu_runtime::g_escape, neostation_build_spu_g_escape, \"spu g_escape\") ||
\t\t\t!initialize(spu_runtime::g_tail_escape, neostation_build_spu_g_tail_escape, \"spu g_tail_escape\"))
\t\t{{
\t\t\treturn false;
\t\t}}
\t}}
\tcatch (const std::exception& exception)
\t{{
\t\terror = std::string(\"SPU trampoline construction failed: \") + exception.what();
\t\treturn false;
\t}}
\tcatch (...)
\t{{
\t\terror = \"SPU trampoline construction failed with an unknown exception\";
\t\treturn false;
\t}}
\tinitialized = true;
\treturn true;
}}
#endif
"""
    text += initializer
    validate_spu(text)
    path.write_text(text, encoding="utf-8")


def validate_spu(text: str) -> None:
    required = (
        f"bool neostation_initialize_spu_jit(std::string& error) noexcept // {MARKER}",
        "return std::remove_const_t<decltype(ptr)>{};",
        "neostation_build_spu_tr_dispatch",
        "neostation_build_spu_g_dispatcher",
        "neostation_build_spu_g_tail_escape",
    )
    for token in required:
        if token not in text:
            raise PatchError(f"SPU validation missing {token!r}")
    for name in (
        "tr_dispatch", "tr_branch", "tr_interpreter", "g_dispatcher",
        "tr_all", "g_gateway", "g_escape", "g_tail_escape",
    ):
        token = f"constinit DECLARE(spu_runtime::{name}) = nullptr;"
        if text.count(token) != 1:
            raise PatchError(f"SPU {name} does not have exactly one constant null initializer")
