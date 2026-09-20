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
FORBIDDEN_UNDEFINED_SYMBOLS = (
    '_vm_map',
    '__os_log_default',
    '__os_log_error_impl',
    '_os_log_type_enabled',
)


def undefined_symbols(data: bytes) -> set[str]:
    """Read external undefined symbols from one arm64 Mach-O image."""
    command_count, command_bytes = struct.unpack_from('<II', data, 16)
    command_end = 32 + command_bytes
    if command_count > 65536 or command_end > len(data):
        raise ValueError('Embedded RPCS3 Core has invalid Mach-O load commands')
    position = 32
    symbol_table: tuple[int, int, int, int] | None = None
    for _ in range(command_count):
        if position + 8 > command_end:
            raise ValueError('Embedded RPCS3 Core has a truncated load command')
        command, size = struct.unpack_from('<II', data, position)
        if size < 8 or position + size > command_end:
            raise ValueError('Embedded RPCS3 Core has an invalid load command')
        if command == 0x2:  # LC_SYMTAB
            if size < 24:
                raise ValueError('Embedded RPCS3 Core has a truncated symbol table command')
            symbol_table = struct.unpack_from('<IIII', data, position + 8)
        position += size
    if position != command_end:
        raise ValueError('Embedded RPCS3 Core load command sizes do not match')
    if symbol_table is None:
        return set()

    symbol_offset, symbol_count, string_offset, string_size = symbol_table
    if (symbol_offset + 16 * symbol_count > len(data) or
            string_offset + string_size > len(data)):
        raise ValueError('Embedded RPCS3 Core has a truncated symbol table')
    result: set[str] = set()
    for index in range(symbol_count):
        string_index, kind, _, _, _ = struct.unpack_from(
            '<IBBHQ', data, symbol_offset + 16 * index
        )
        if kind & 0xE0 or not kind & 1 or (kind & 0x0E) != 0 or string_index == 0:
            continue
        if string_index >= string_size:
            raise ValueError('Embedded RPCS3 Core has an invalid symbol string offset')
        start = string_offset + string_index
        end = data.find(b'\0', start, string_offset + string_size)
        if end < start:
            raise ValueError('Embedded RPCS3 Core has an unterminated symbol name')
        result.add(data[start:end].decode('utf-8', errors='replace'))
    return result


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
    forbidden = sorted(set(FORBIDDEN_UNDEFINED_SYMBOLS) & undefined_symbols(data))
    if forbidden:
        raise ValueError(
            'Embedded RPCS3 Core contains forbidden load-time imports: ' + ', '.join(forbidden)
        )


if __name__ == '__main__':
    if len(sys.argv) != 2:
        raise SystemExit('usage: validate_rpcs3_embedded_core.py <libRPCS3Core.dylib>')
    validate_core(Path(sys.argv[1]).read_bytes())
    print(
        f'Validated embedded RPCS3: {JIT_MARKER}, Build 264 ARM64/ThinLTO, '
        f'{BUILD_MARKER}, {SHADER_CHECKPOINT_MARKER}, v0.9 revision {REVISION}, '
        'SPU on-demand policy, LLVM self-test and guarded load-time imports'
    )
