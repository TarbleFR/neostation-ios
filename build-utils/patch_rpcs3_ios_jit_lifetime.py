#!/usr/bin/env python3
from __future__ import annotations

import sys
from pathlib import Path

MARKER = "NEOSTATION_IOS_JIT_LIFETIME_FENCE"


def fail(message: str) -> None:
    raise SystemExit(f"error: {message}")


def main() -> None:
    if len(sys.argv) != 2:
        fail("usage: patch_rpcs3_ios_jit_lifetime.py <rpcs3-source-root>")

    source_root = Path(sys.argv[1]).resolve()
    target = source_root / "Utilities" / "JITIOS.cpp"
    if not target.is_file():
        fail(f"RPCS3 iOS JIT source not found: {target}")

    text = target.read_text(encoding="utf-8")
    if MARKER in text:
        print(f"{target}: lifetime fence already present")
        return

    needle = '''\tarena_allocator& allocator = executable ? g_arena.code_allocator : g_arena.data_allocator;\n\tif (!allocator.release(offset, size))\n\t{\n\t\tset_error("Attempted to release an invalid or overlapping JIT allocation");\n\t\treturn;\n\t}\n\n\tusz& live = executable ? g_arena.live_code_bytes : g_arena.live_data_bytes;\n\tlive = size <= live ? live - size : 0;\n'''

    replacement = '''\t// NEOSTATION_IOS_JIT_LIFETIME_FENCE\n\t// RPCS3 publishes addresses from these temporary LLVM allocations into\n\t// long-lived PPU resolver tables and SPU runtime/trampoline structures.\n\t// Recycling a slot while one of those addresses is still reachable can\n\t// overwrite executable code during Linking PPU Modules / Building SPU\n\t// Cache.  Keep temporary arena allocations stable for the whole emulation\n\t// session; reset_runtime()/process teardown owns the lifetime boundary.\n\t// The expanded iOS arena provides the capacity required for this policy.\n\t(void)offset;\n\treturn;\n'''

    if needle not in text:
        fail("release_allocation implementation does not match pinned RPCS3 source; refusing a fuzzy patch")

    patched = text.replace(needle, replacement, 1)
    if patched.count(MARKER) != 1:
        fail("lifetime patch marker count is invalid")

    target.write_text(patched, encoding="utf-8")
    print(f"{target}: pinned temporary JIT allocations until session reset")


if __name__ == "__main__":
    main()
