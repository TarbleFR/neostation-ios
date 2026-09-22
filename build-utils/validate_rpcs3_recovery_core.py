#!/usr/bin/env python3
"""Validate the Build 303 recovery Core: Build266 allocator + Build301 passive dlopen."""
from pathlib import Path
import struct
import sys

MINIMUM_CORE_SIZE = 60_000_000
REQUIRED = (
    b'NEOSTATION_BUILD301_PASSIVE_DLOPEN_V1',
    b'NEOSTATION_BUILD266_JIT_V09_SHADER_V1',
    b'NEOSTATION_DYNAMIC_JIT_V5',
    b'NEOSTATION_BUILD264_GOW3_ARM64_LTO_V1',
    b'NEOSTATION_BUILD265_RSX_SPU_VIDEO_V1',
    b'NEOSTATION_BUILD266_SHADER_CHECKPOINT_V1',
    b'505a85e5a8f2cdff1cd63168bd2c56b0f92282bf',
    b'RPCS3 LLVM JIT self-test entry=%p',
)
FORBIDDEN_MARKERS = (
    b'NEOSTATION_BUILD295_FIXED_JIT_RESERVATION_V1',
    b'NEOSTATION_BUILD302_RESERVED_STARTUP_V1',
)
FORBIDDEN_UNDEFINED = {
    '_vm_map', '__os_log_default', '__os_log_error_impl', '_os_log_type_enabled'
}

def undefined_symbols(data: bytes) -> set[str]:
    command_count, command_bytes = struct.unpack_from('<II', data, 16)
    end_commands = 32 + command_bytes
    if command_count > 65536 or end_commands > len(data):
        raise ValueError('invalid Mach-O load commands')
    pos = 32
    symtab = None
    for _ in range(command_count):
        command, size = struct.unpack_from('<II', data, pos)
        if size < 8 or pos + size > end_commands:
            raise ValueError('invalid Mach-O command size')
        if command == 0x2:
            symtab = struct.unpack_from('<IIII', data, pos + 8)
        pos += size
    if symtab is None:
        return set()
    symbol_offset, symbol_count, string_offset, string_size = symtab
    result=set()
    for index in range(symbol_count):
        string_index, kind, _, _, _ = struct.unpack_from('<IBBHQ', data, symbol_offset + 16 * index)
        if kind & 0xE0 or not kind & 1 or (kind & 0x0E) != 0 or string_index == 0:
            continue
        start=string_offset+string_index
        end=data.find(b'\0', start, string_offset+string_size)
        if end >= start:
            result.add(data[start:end].decode('utf-8', errors='replace'))
    return result

def validate(data: bytes) -> None:
    if len(data) < MINIMUM_CORE_SIZE:
        raise ValueError('Core is unexpectedly small')
    if data[:4] != b'\xcf\xfa\xed\xfe' or struct.unpack_from('<I', data, 4)[0] != 0x0100000C:
        raise ValueError('Core must be arm64 Mach-O')
    if struct.unpack_from('<I', data, 12)[0] != 6:
        raise ValueError('Core must be a dylib')
    for marker in REQUIRED:
        if marker not in data:
            raise ValueError(f'missing required marker {marker!r}')
    for marker in FORBIDDEN_MARKERS:
        if marker in data:
            raise ValueError(f'fixed-reservation regression marker present: {marker!r}')
    bad=sorted(FORBIDDEN_UNDEFINED & undefined_symbols(data))
    if bad:
        raise ValueError('forbidden load-time imports: ' + ', '.join(bad))

if __name__ == '__main__':
    if len(sys.argv) != 2:
        raise SystemExit('usage: validate_rpcs3_recovery_core.py <libRPCS3Core.dylib>')
    validate(Path(sys.argv[1]).read_bytes())
    print('Validated recovery Core: Build266 allocator + Build301 passive dlopen; Build295/302 absent.')
