#!/usr/bin/env python3
"""Port audited ARM64 contention/copy fixes from ARMSX3 into pinned RPCS3."""

from __future__ import annotations

import sys
from pathlib import Path


SPU_MARKER = "NEOSTATION_ARMSX3_NEON_RESERVATION_COPY_V1"
RANGE_MARKER = "NEOSTATION_ARMSX3_RANGE_LOCK_WAIT_V1"


def replace_once(text: str, old: str, new: str, description: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{description}: expected one source anchor, found {count}")
    return text.replace(old, new, 1)


def patch_spu(source: Path) -> None:
    path = source / "rpcs3/Emu/Cell/SPUThread.cpp"
    text = path.read_text()

    if SPU_MARKER not in text:
        include_anchor = "#include <unordered_set>\n"
        include_patch = """#include <unordered_set>

#if defined(ARCH_ARM64)
#include <arm_neon.h>
#endif
"""
        text = replace_once(
            text, include_anchor, include_patch, "ARM64 NEON include"
        )

        scalar_fallback = """#else
\tstd::memcpy(_dst, _src, 128);
#endif
"""
        neon_copy = f"""#elif defined(ARCH_ARM64)
\t// {SPU_MARKER}: preserve the reservation line in 16-byte vector chunks.
\tconst u8* const src = reinterpret_cast<const u8*>(_src);
\tu8* const dst = reinterpret_cast<u8*>(_dst);
\tconst uint8x16_t v0 = vld1q_u8(src + 0x00);
\tconst uint8x16_t v1 = vld1q_u8(src + 0x10);
\tconst uint8x16_t v2 = vld1q_u8(src + 0x20);
\tconst uint8x16_t v3 = vld1q_u8(src + 0x30);
\tconst uint8x16_t v4 = vld1q_u8(src + 0x40);
\tconst uint8x16_t v5 = vld1q_u8(src + 0x50);
\tconst uint8x16_t v6 = vld1q_u8(src + 0x60);
\tconst uint8x16_t v7 = vld1q_u8(src + 0x70);
\tvst1q_u8(dst + 0x00, v0);
\tvst1q_u8(dst + 0x10, v1);
\tvst1q_u8(dst + 0x20, v2);
\tvst1q_u8(dst + 0x30, v3);
\tvst1q_u8(dst + 0x40, v4);
\tvst1q_u8(dst + 0x50, v5);
\tvst1q_u8(dst + 0x60, v6);
\tvst1q_u8(dst + 0x70, v7);
#else
\tstd::memcpy(_dst, _src, 128);
#endif
"""
        fallback_count = text.count(scalar_fallback)
        if fallback_count != 2:
            raise SystemExit(
                "ARM64 reservation copies: expected two scalar fallbacks, "
                f"found {fallback_count}"
            )
        text = text.replace(scalar_fallback, neon_copy)

    if RANGE_MARKER not in text:
        old_writer = """\twriter_lock::~writer_lock() noexcept
\t{
\t\tif (range_lock)
\t\t{
\t\t\tg_range_lock_bits[1] &= ~(1ull << (range_lock - g_range_lock_set));
\t\t\trange_lock->release(0);
\t\t\treturn;
\t\t}

\t\tg_range_lock_bits[1].release(0);
\t}
"""
        new_writer = f"""\twriter_lock::~writer_lock() noexcept
\t{{
\t\t// {RANGE_MARKER}: wake PPUs only when the shared word becomes clear.
\t\tif (range_lock)
\t\t{{
\t\t\tconst u64 left = (g_range_lock_bits[1] &= ~(1ull << (range_lock - g_range_lock_set)));
\t\t\trange_lock->release(0);
\t\t\tif (!left)
\t\t\t{{
\t\t\t\tg_range_lock_bits[1].notify_all();
\t\t\t}}
\t\t\treturn;
\t\t}}

\t\tg_range_lock_bits[1].release(0);
\t\tg_range_lock_bits[1].notify_all();
\t}}
"""
        text = replace_once(text, old_writer, new_writer, "range-lock notify")

    path.write_text(text)


def patch_vm(source: Path) -> None:
    path = source / "rpcs3/Emu/Memory/vm.cpp"
    text = path.read_text()
    if RANGE_MARKER in text:
        return

    old_wait = """\t\t\t\tif (i < 100)
\t\t\t\t\tbusy_wait(200);
\t\t\t\telse
\t\t\t\t\tstd::this_thread::yield();
"""
    new_wait = f"""\t\t\t\t// {RANGE_MARKER}: wait for a notified transition instead of yielding blind.
\t\t\t\tif (i < 100)
\t\t\t\t{{
\t\t\t\t\tbusy_wait(200);
\t\t\t\t}}
\t\t\t\telse if (const u64 bits = get_range_lock_bits(true))
\t\t\t\t{{
\t\t\t\t\tget_range_lock_bits(true).wait(bits, atomic_wait_timeout{{50'000}});
\t\t\t\t}}
"""
    path.write_text(replace_once(text, old_wait, new_wait, "range-lock wait"))


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: patch_rpcs3_armsx3_performance.py <rpcs3-source-root>")
    source = Path(sys.argv[1]).resolve()
    patch_spu(source)
    patch_vm(source)
    print("RPCS3 ARMSX3-derived ARM64 performance patch: OK")


if __name__ == "__main__":
    main()
