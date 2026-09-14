#!/usr/bin/env python3
"""Port audited ARM64 contention/copy fixes from ARMSX3 into pinned RPCS3."""

from __future__ import annotations

import sys
import subprocess
from pathlib import Path


SPU_MARKER = "NEOSTATION_ARMSX3_NEON_RESERVATION_COPY_V1"
RANGE_MARKER = "NEOSTATION_ARMSX3_RANGE_LOCK_WAIT_V1"
SPU_LLVM_MARKER = "NEOSTATION_ARMSX3_SPU_BYTE_FAST_PATHS_V1"
SPU_ARM64_LOWERING_MARKER = "NEOSTATION_SPU_ARM64_LOWERING_41F0ECC_V1"


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


def patch_spu_llvm(source: Path) -> None:
    """Port ARMSX3 ca223f7's semantics-preserving SPU LLVM folds.

    The folds recognize guest byte add/sub and compare idioms after RPCS3 has
    widened them. Emitting native 8-bit vector operations reduces generated
    AArch64 instructions without changing memory ordering or timing policy.
    """
    path = source / "rpcs3/Emu/Cell/SPULLVMRecompiler.cpp"
    text = path.read_text()
    if SPU_LLVM_MARKER in text:
        return

    absdb_anchor = """\tvoid ABSDB(spu_opcode_t op)
\t{
\t\tconst auto [a, b] = get_vrs<u8[16]>(op.ra, op.rb);
\t\tset_vr(op.rt, absd(a, b));
\t}
"""
    absdb_patch = f"""\tvoid ABSDB(spu_opcode_t op)
\t{{
\t\t// {SPU_LLVM_MARKER}: ARMSX3 ca223f7 compare-result fast path.
\t\tconst auto matches_compare = [&](auto val, auto MP)
\t\t{{
\t\t\tusing VT = typename decltype(MP)::type;
\t\t\tauto [ok, x] = match_expr(val, sext<VT>(match<bool[std::extent_v<VT>]>()));
\t\t\treturn ok;
\t\t}};

\t\tconst auto [a, b] = get_vrs<u8[16]>(op.ra, op.rb);
\t\tif (match_vr<s8[16], s16[8], s32[4], s64[2]>(op.ra, matches_compare) ||
\t\t\tmatch_vr<s8[16], s16[8], s32[4], s64[2]>(op.rb, matches_compare))
\t\t{{
\t\t\tset_vr(op.rt, a ^ b);
\t\t\treturn;
\t\t}}
\t\tset_vr(op.rt, absd(a, b));
\t}}
"""
    text = replace_once(text, absdb_anchor, absdb_patch, "SPU ABSDB compare fold")

    selb_anchor = """\t\t\tcase 2:
\t\t\tcase 1:
\t\t\t{
\t\t\t\tset_vr(op.rt4, select(bitcast<s8[16]>(c) != 0, get_vr<u8[16]>(op.rb), get_vr<u8[16]>(op.ra)));
\t\t\t\treturn;
\t\t\t}
"""
    selb_patch = """\t\t\tcase 2:
\t\t\tcase 1:
\t\t\t{
\t\t\t\tconst bool lhs_to_lo = mask == v128::from16p(0xff00);
\t\t\t\tif (lhs_to_lo || mask == v128::from16p(0x00ff))
\t\t\t\t{
\t\t\t\t\tconst auto lhs = get_vr<u16[8]>(op.ra);
\t\t\t\t\tconst auto rhs = get_vr<u16[8]>(op.rb);
\t\t\t\t\tconst auto lo_op = lhs_to_lo ? lhs : rhs;
\t\t\t\t\tconst auto hi_op = lhs_to_lo ? rhs : lhs;
\t\t\t\t\tif (const auto [ok, add_a, add_b] = match_expr(lo_op, match<u16[8]>() + match<u16[8]>()); ok)
\t\t\t\t\t{
\t\t\t\t\t\tconst auto [ab] = match_expr(hi_op, add_a + (add_b & 0xff00));
\t\t\t\t\t\tconst auto [ba] = match_expr(hi_op, add_b + (add_a & 0xff00));
\t\t\t\t\t\tif (ab || ba)
\t\t\t\t\t\t{
\t\t\t\t\t\t\tset_vr(op.rt4, bitcast<u8[16]>(add_a) + bitcast<u8[16]>(add_b));
\t\t\t\t\t\t\treturn;
\t\t\t\t\t\t}
\t\t\t\t\t}
\t\t\t\t\tif (const auto [ok, sub_a, sub_b] = match_expr(lo_op, match<u16[8]>() - match<u16[8]>()); ok)
\t\t\t\t\t{
\t\t\t\t\t\tif (const auto [hi] = match_expr(hi_op, sub_a - (sub_b & 0xff00)); hi)
\t\t\t\t\t\t{
\t\t\t\t\t\t\tset_vr(op.rt4, bitcast<u8[16]>(sub_a) - bitcast<u8[16]>(sub_b));
\t\t\t\t\t\t\treturn;
\t\t\t\t\t\t}
\t\t\t\t\t}
\t\t\t\t}
\t\t\t\tset_vr(op.rt4, select(bitcast<s8[16]>(c) != 0, get_vr<u8[16]>(op.rb), get_vr<u8[16]>(op.ra)));
\t\t\t\treturn;
\t\t\t}
"""
    text = replace_once(text, selb_anchor, selb_patch, "SPU SELB byte folds")

    shufb_anchor = """\t\tconst auto c = get_vr<u8[16]>(op.rc);

\t\tif (auto [ok, mask] = get_const_vector(c.value, m_pos); ok)
"""
    shufb_patch = """\t\tif (match_vr<s8[16], s16[8], s32[4], s64[2]>(op.rc, [&](auto c, auto MP)
\t\t{
\t\t\tusing VT = typename decltype(MP)::type;
\t\t\tif (auto [ok, i] = match_expr(c, sext<VT>(match<bool[std::extent_v<VT>]>())); ok)
\t\t\t{
\t\t\t\tconst auto a_splat = zshuffle(get_vr<u8[16]>(op.ra), 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15);
\t\t\t\tset_vr(op.rt4, select(bitcast<s8[16]>(c) != 0, splat<u8[16]>(0x80), a_splat));
\t\t\t\treturn true;
\t\t\t}
\t\t\treturn false;
\t\t}))
\t\t{
\t\t\treturn;
\t\t}

\t\tconst auto c = get_vr<u8[16]>(op.rc);

\t\tif (auto [ok, mask] = get_const_vector(c.value, m_pos); ok)
"""
    text = replace_once(text, shufb_anchor, shufb_patch, "SPU SHUFB compare fold")
    path.write_text(text)


def patch_spu_arm64_lowering(source: Path) -> None:
    """Keep x86-only LLVM idioms out of the AArch64 SPU compiler.

    This is the architecture-neutral portion of upstream RPCS3 41f0ecc. The
    later NeoStation architecture patch already handles its conditional-branch
    portion with native ARM64 lane extraction, so this patch carries the other
    audited AVX/AVX-512 guards only.
    """
    path = source / "rpcs3/Emu/Cell/SPULLVMRecompiler.cpp"
    text = path.read_text()
    if SPU_ARM64_LOWERING_MARKER in text:
        return

    patch = (
        Path(__file__).resolve().parent
        / "patches/rpcs3_build264_spu_arm64_lowering.patch"
    )
    checked = subprocess.run(
        ["git", "-C", str(source), "apply", "--check", str(patch)],
        capture_output=True,
        text=True,
    )
    if checked.returncode:
        raise SystemExit(
            "SPU ARM64 lowering guards no longer apply cleanly:\n"
            + checked.stderr
        )
    subprocess.run(
        ["git", "-C", str(source), "apply", str(patch)], check=True
    )

    text = path.read_text()
    marker_anchor = '#include "stdafx.h"\n'
    marker_patch = (
        '#include "stdafx.h"\n\n'
        f'// {SPU_ARM64_LOWERING_MARKER}: ported from upstream 41f0ecc.\n'
    )
    path.write_text(
        replace_once(text, marker_anchor, marker_patch, "SPU ARM64 marker")
    )


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: patch_rpcs3_armsx3_performance.py <rpcs3-source-root>")
    source = Path(sys.argv[1]).resolve()
    patch_spu(source)
    patch_vm(source)
    patch_spu_llvm(source)
    patch_spu_arm64_lowering(source)
    print("RPCS3 ARMSX3-derived ARM64 performance patch: OK")


if __name__ == "__main__":
    main()
