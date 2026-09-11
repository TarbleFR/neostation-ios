#!/usr/bin/env python3
"""Patch only the pinned embedded Core's iOS JIT arena.

Build 238 deliberately keeps RPCS3's generic JIT/LLVM/ASM code untouched.
The overrides are the iOS arena mapping contract and its runtime build identifier.
"""
from pathlib import Path
import sys

from patch_rpcs3_embedded_boot import replace_function, replace_once

PARTS = Path(__file__).resolve().parent / 'rpcs3'
PATCH_ID = 'NEOSTATION_DYNAMIC_JIT_V3'


def patch(root: Path) -> None:
    edits = {}
    path = root / 'Utilities/JITIOS.cpp'
    text = path.read_text()
    text = replace_function(
        text,
        'bool prepare_arena(bool expanded) noexcept',
        (PARTS / 'jit_arena.cpp.inc').read_text().rstrip(),
        PATCH_ID,
    )
    edits[path] = text

    # A comment is absent from the linked binary. Record the arena revision in
    # the existing exported ABI metadata and the native initialization log.
    path = root / 'rpcs3/ios/RPCS3IOS.cpp'
    text = path.read_text()
    old = r'\"jit\":\"sealed-arena\"'
    text = replace_once(text, old, old + rf',\"neostation_jit\":\"{PATCH_ID}\"')
    text = replace_once(text, '\t\temit_jit_arena_statistics("after core initialization");',
                        f'\t\temit_log(4, "{PATCH_ID}: dynamic RX/RW arena verified");\n'
                        '\t\temit_jit_arena_statistics("after core initialization");')
    edits[path] = text

    # Reject upstream drift before changing any source file.
    for path, text in edits.items():
        path.write_text(text)
        print(f'Patched JIT: {path.relative_to(root)}')


if __name__ == '__main__':
    if len(sys.argv) != 2:
        raise SystemExit('usage: patch_rpcs3_jit_memory.py <pinned-rpcs3-source>')
    patch(Path(sys.argv[1]))
