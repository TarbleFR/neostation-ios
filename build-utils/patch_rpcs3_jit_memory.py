#!/usr/bin/env python3
"""Patch only the pinned embedded Core's iOS JIT arena.

Build 238 deliberately keeps RPCS3's generic JIT/LLVM/ASM code untouched.
The only override is the iOS arena mapping contract.
"""
from pathlib import Path
import sys

from patch_rpcs3_embedded_boot import replace_function

PARTS = Path(__file__).resolve().parent / 'rpcs3'


def patch(root: Path) -> None:
    path = root / 'Utilities/JITIOS.cpp'
    text = path.read_text()
    text = replace_function(
        text,
        'bool prepare_arena(bool expanded) noexcept',
        (PARTS / 'jit_arena.cpp.inc').read_text().rstrip(),
        'NEOSTATION_DYNAMIC_JIT_V3',
    )
    path.write_text(text)
    print(f'Patched JIT arena: {path.relative_to(root)}')


if __name__ == '__main__':
    if len(sys.argv) != 2:
        raise SystemExit('usage: patch_rpcs3_jit_memory.py <pinned-rpcs3-source>')
    patch(Path(sys.argv[1]))
