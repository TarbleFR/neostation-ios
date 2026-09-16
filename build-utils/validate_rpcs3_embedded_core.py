#!/usr/bin/env python3
"""Reject stale embedded cores before packaging and inside the final IPA."""
from pathlib import Path
import struct
import sys

from patch_rpcs3_build266_v09_core import (
    BUILD_MARKER,
    JIT_MARKER,
    REVISION,
    SHADER_CHECKPOINT_MARKER,
)

MINIMUM_CORE_SIZE = 60_000_000
REQUIRED_MARKERS = (
    ('Build 266 JIT', JIT_MARKER.encode('ascii')),
    ('Build 264 ARM64/ThinLTO', b'NEOSTATION_BUILD264_GOW3_ARM64_LTO_V1'),
    ('Build 265 RSX/SPU/video', b'NEOSTATION_BUILD265_RSX_SPU_VIDEO_V1'),
    ('selective ThinLTO', b'thin-rpcs3-core-only'),
    ('SPU on-demand policy', b'NeoStation: SPU cache warmup deferred; LLVM compiles blocks on demand;'),
    ('LLVM JIT self-test', b'RPCS3 LLVM JIT self-test entry=%p'),
    ('Build 266 v0.9 backport', BUILD_MARKER.encode('ascii')),
    ('Build 266 shader checkpoint', SHADER_CHECKPOINT_MARKER.encode('ascii')),
    ('Build 266 upstream revision', REVISION.encode('ascii')),
)


def validate_core(data: bytes) -> None:
    if len(data) < MINIMUM_CORE_SIZE:
        raise ValueError('Embedded RPCS3 Core is unexpectedly small')
    if data[:4] != b'\xcf\xfa\xed\xfe' or struct.unpack_from('<I', data, 4)[0] != 0x0100000C:
        raise ValueError('Embedded RPCS3 Core must be a native arm64 Mach-O')
    if struct.unpack_from('<I', data, 12)[0] != 6:
        raise ValueError('Embedded RPCS3 Core must be a dynamic library')
    for label, marker in REQUIRED_MARKERS:
        if marker not in data:
            raise ValueError(f'Embedded RPCS3 Core is missing {label} marker {marker!r}')


if __name__ == '__main__':
    if len(sys.argv) != 2:
        raise SystemExit('usage: validate_rpcs3_embedded_core.py <libRPCS3Core.dylib>')
    validate_core(Path(sys.argv[1]).read_bytes())
    print(
        f'Validated embedded RPCS3: {JIT_MARKER}, Build 264 ARM64/ThinLTO, '
        f'{BUILD_MARKER}, {SHADER_CHECKPOINT_MARKER}, v0.9 revision {REVISION}, '
        'SPU on-demand policy and LLVM self-test'
    )
