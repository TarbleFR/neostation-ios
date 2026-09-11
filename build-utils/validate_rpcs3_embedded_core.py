#!/usr/bin/env python3
"""Reject stale embedded cores before packaging and inside the final IPA."""
from pathlib import Path
import struct
import sys

from patch_rpcs3_jit_memory import PATCH_ID

REQUIRED_MARKERS = (
    PATCH_ID.encode('ascii'),
    b'NeoStation: SPU cache warmup deferred; LLVM compiles blocks on demand;',
    b'RPCS3 LLVM JIT self-test entry=%p',
)


def validate_core(data: bytes) -> None:
    if len(data) < 60_000_000:
        raise ValueError('Embedded RPCS3 Core is unexpectedly small')
    if data[:4] != b'\xcf\xfa\xed\xfe' or struct.unpack_from('<I', data, 4)[0] != 0x0100000C:
        raise ValueError('Embedded RPCS3 Core must be a native arm64 Mach-O')
    if struct.unpack_from('<I', data, 12)[0] != 6:
        raise ValueError('Embedded RPCS3 Core must be a dynamic library')
    for marker in REQUIRED_MARKERS:
        if marker not in data:
            raise ValueError(f'Embedded RPCS3 Core is missing {marker!r}')


if __name__ == '__main__':
    if len(sys.argv) != 2:
        raise SystemExit('usage: validate_rpcs3_embedded_core.py <libRPCS3Core.dylib>')
    validate_core(Path(sys.argv[1]).read_bytes())
    print(f'Validated embedded RPCS3: {PATCH_ID}, SPU on-demand policy and LLVM self-test')
