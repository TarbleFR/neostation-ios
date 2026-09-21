"""Orchestrate and validate NeoStation's passive RPCS3 Core loading patch."""
from pathlib import Path
from .common import MARKER, PatchError, Initializer, _initializer_at, _all_initializers, _wrap_initializer, replace_once
from .jit_memory import patch_jit_header, patch_jit_asm, patch_jit_ios_header, patch_jit_ios, validate_jit_asm, validate_jit_ios
from .trampolines import patch_ppu, patch_spu_header, patch_spu, validate_ppu, validate_spu
from .ios_api import patch_ios_api, validate_ios_api


def validate_source_tree(root: Path) -> None:
    files = {
        "jit": root / "Utilities/JITASM.cpp",
        "jit_ios": root / "Utilities/JITIOS.cpp",
        "ppu": root / "rpcs3/Emu/Cell/PPUThread.cpp",
        "spu": root / "rpcs3/Emu/Cell/SPUCommonRecompiler.cpp",
        "spu_header": root / "rpcs3/Emu/Cell/SPURecompiler.h",
        "api": root / "rpcs3/ios/RPCS3IOS.cpp",
    }
    for name, path in files.items():
        if not path.is_file():
            raise PatchError(f"missing patched source {name}: {path}")
    validate_jit_asm(files["jit"].read_text(encoding="utf-8"))
    validate_jit_ios(files["jit_ios"].read_text(encoding="utf-8"))
    validate_ppu(files["ppu"].read_text(encoding="utf-8"))
    validate_spu(files["spu"].read_text(encoding="utf-8"))
    validate_ios_api(files["api"].read_text(encoding="utf-8"))
    header = files["spu_header"].read_text(encoding="utf-8")
    for forbidden in (
        "static const spu_function_t tr_dispatch;",
        "* const g_dispatcher;",
        "void(*const g_escape)",
        "void(*const g_tail_escape)",
    ):
        if forbidden in header:
            raise PatchError(f"SPU header retained immutable deferred pointer: {forbidden}")


def patch(root: Path) -> None:
    root = root.resolve()
    patch_jit_header(root)
    patch_jit_asm(root)
    patch_jit_ios_header(root)
    patch_jit_ios(root)
    patch_ppu(root)
    patch_spu_header(root)
    patch_spu(root)
    patch_ios_api(root)
    validate_source_tree(root)
    print(f"{MARKER}: passive dlopen and explicit recoverable JIT initialization verified")
