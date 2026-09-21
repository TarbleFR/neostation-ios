#!/usr/bin/env python3
"""Validate that dyld initializers in an arm64 RPCS3 Core cannot reach JIT setup.

The validator parses Mach-O load commands, S_INIT_FUNC_OFFSETS and
S_MOD_INIT_FUNC_POINTERS, then follows direct ARM64 B/BL edges through internal
text symbols. It is intentionally independent from source tests: the produced
binary itself must prove that dlopen is passive.
"""
from __future__ import annotations

import bisect
import struct
import sys
from dataclasses import dataclass
from pathlib import Path

MH_MAGIC_64 = 0xFEEDFACF
CPU_TYPE_ARM64 = 0x0100000C
MH_DYLIB = 6
LC_SEGMENT_64 = 0x19
LC_SYMTAB = 0x2
S_INIT_FUNC_OFFSETS = 0x16
S_MOD_INIT_FUNC_POINTERS = 0x9
N_TYPE = 0x0E
N_SECT = 0x0E
MARKER = b'NEOSTATION_BUILD301_PASSIVE_DLOPEN_V1'

FORBIDDEN_SYMBOLS = (
    'asmjit18get_global_runtime',
    'asmjit25initialize_global_runtime',
    'jit13prepare_arena',
    'jit14runtime_memory',
    'jit8allocate',
    'jit_runtime5alloc',
)


class ValidationError(RuntimeError):
    pass


@dataclass(frozen=True)
class Section:
    segment: str
    name: str
    address: int
    size: int
    offset: int
    flags: int
    ordinal: int


@dataclass(frozen=True)
class Symbol:
    address: int
    name: str


def cstring(raw: bytes) -> str:
    return raw.split(b'\0', 1)[0].decode('utf-8', errors='replace')


def sign_extend(value: int, bits: int) -> int:
    sign = 1 << (bits - 1)
    return (value ^ sign) - sign


class MachO:
    def __init__(self, data: bytes):
        self.data = data
        if len(data) < 32:
            raise ValidationError('RPCS3 Core is too small for a Mach-O header')
        magic, cpu, _, filetype, command_count, command_bytes, _, _ = struct.unpack_from(
            '<IIIIIIII', data, 0
        )
        if magic != MH_MAGIC_64 or cpu != CPU_TYPE_ARM64 or filetype != MH_DYLIB:
            raise ValidationError('RPCS3 Core must be an arm64 Mach-O dylib')
        if command_count > 65536 or 32 + command_bytes > len(data):
            raise ValidationError('RPCS3 Core has invalid Mach-O load commands')

        self.sections: list[Section] = []
        self.symbol_table: tuple[int, int, int, int] | None = None
        self.text_vmaddr = 0
        position = 32
        ordinal = 1
        for _ in range(command_count):
            if position + 8 > 32 + command_bytes:
                raise ValidationError('Truncated Mach-O load command')
            command, size = struct.unpack_from('<II', data, position)
            if size < 8 or position + size > 32 + command_bytes:
                raise ValidationError('Invalid Mach-O load command size')
            if command == LC_SEGMENT_64:
                if size < 72:
                    raise ValidationError('Truncated LC_SEGMENT_64')
                segment = cstring(data[position + 8:position + 24])
                vmaddr, _, _, _ = struct.unpack_from('<QQQQ', data, position + 24)
                _, _, section_count, _ = struct.unpack_from('<IIII', data, position + 56)
                if segment == '__TEXT':
                    self.text_vmaddr = vmaddr
                section_pos = position + 72
                if section_pos + section_count * 80 > position + size:
                    raise ValidationError('Truncated Mach-O section table')
                for _ in range(section_count):
                    name = cstring(data[section_pos:section_pos + 16])
                    section_segment = cstring(data[section_pos + 16:section_pos + 32])
                    address, section_size = struct.unpack_from('<QQ', data, section_pos + 32)
                    offset, _, _, _, flags, _, _, _ = struct.unpack_from(
                        '<IIIIIIII', data, section_pos + 48
                    )
                    if offset + section_size > len(data) and section_size:
                        raise ValidationError(f'Truncated section {section_segment},{name}')
                    self.sections.append(Section(
                        section_segment, name, address, section_size, offset, flags, ordinal
                    ))
                    ordinal += 1
                    section_pos += 80
            elif command == LC_SYMTAB:
                if size < 24:
                    raise ValidationError('Truncated LC_SYMTAB')
                self.symbol_table = struct.unpack_from('<IIII', data, position + 8)
            position += size
        if position != 32 + command_bytes:
            raise ValidationError('Mach-O load-command sizes do not match')

        self.text = next((s for s in self.sections if s.segment == '__TEXT' and s.name == '__text'), None)
        if self.text is None:
            raise ValidationError('RPCS3 Core has no __TEXT,__text section')
        self.symbols = self._symbols()
        self.symbols_by_address: dict[int, list[Symbol]] = {}
        for symbol in self.symbols:
            self.symbols_by_address.setdefault(symbol.address, []).append(symbol)
        self.unique_symbol_addresses = sorted(self.symbols_by_address)

    def _symbols(self) -> list[Symbol]:
        if self.symbol_table is None:
            raise ValidationError('RPCS3 Core has no symbol table for initializer audit')
        symbol_offset, count, string_offset, string_size = self.symbol_table
        if symbol_offset + count * 16 > len(self.data) or string_offset + string_size > len(self.data):
            raise ValidationError('RPCS3 Core has a truncated symbol table')
        symbols: dict[tuple[int, str], Symbol] = {}
        for index in range(count):
            string_index, kind, section, _, value = struct.unpack_from(
                '<IBBHQ', self.data, symbol_offset + index * 16
            )
            if (kind & N_TYPE) != N_SECT or section != self.text.ordinal or not value or not string_index:
                continue
            if string_index >= string_size:
                raise ValidationError('Invalid Mach-O symbol string index')
            start = string_offset + string_index
            end = self.data.find(b'\0', start, string_offset + string_size)
            if end < 0:
                raise ValidationError('Unterminated Mach-O symbol name')
            name = self.data[start:end].decode('utf-8', errors='replace')
            symbols[(value, name)] = Symbol(value, name)
        result = sorted(symbols.values(), key=lambda item: (item.address, item.name))
        if not result:
            raise ValidationError('RPCS3 Core has no local text symbols for initializer audit')
        return result

    def initializers(self) -> list[int]:
        result: list[int] = []
        for section in self.sections:
            section_type = section.flags & 0xFF
            raw = self.data[section.offset:section.offset + section.size]
            if section_type == S_INIT_FUNC_OFFSETS:
                if len(raw) % 4:
                    raise ValidationError('Invalid S_INIT_FUNC_OFFSETS size')
                for (offset,) in struct.iter_unpack('<I', raw):
                    result.append(self.text_vmaddr + offset)
            elif section_type == S_MOD_INIT_FUNC_POINTERS:
                if len(raw) % 8:
                    raise ValidationError('Invalid S_MOD_INIT_FUNC_POINTERS size')
                for (address,) in struct.iter_unpack('<Q', raw):
                    if address:
                        result.append(address)
        if not result:
            raise ValidationError('RPCS3 Core exposes no dyld initializer section')
        return sorted(set(result))

    def symbol_for(self, address: int) -> Symbol | None:
        index = bisect.bisect_right(self.unique_symbol_addresses, address) - 1
        if index < 0:
            return None
        start_address = self.unique_symbol_addresses[index]
        end = (
            self.unique_symbol_addresses[index + 1]
            if index + 1 < len(self.unique_symbol_addresses)
            else self.text.address + self.text.size
        )
        if address >= end:
            return None
        aliases = self.symbols_by_address[start_address]
        preferred = next((s for s in aliases if '__GLOBAL__sub_I_' in s.name), None)
        return preferred or aliases[0]

    def function_bounds(self, symbol: Symbol) -> tuple[int, int]:
        index = bisect.bisect_right(self.unique_symbol_addresses, symbol.address)
        end = (
            self.unique_symbol_addresses[index]
            if index < len(self.unique_symbol_addresses)
            else self.text.address + self.text.size
        )
        end = min(end, symbol.address + 256 * 1024, self.text.address + self.text.size)
        return symbol.address, end

    def direct_branches(self, symbol: Symbol) -> set[int]:
        start, end = self.function_bounds(symbol)
        file_start = self.text.offset + (start - self.text.address)
        file_end = self.text.offset + (end - self.text.address)
        if file_start < self.text.offset or file_end > self.text.offset + self.text.size:
            return set()
        targets: set[int] = set()
        for offset in range(file_start, file_end - 3, 4):
            (instruction,) = struct.unpack_from('<I', self.data, offset)
            opcode = instruction & 0xFC000000
            if opcode not in (0x14000000, 0x94000000):  # B / BL imm26
                continue
            immediate = sign_extend(instruction & 0x03FFFFFF, 26) << 2
            pc = self.text.address + (offset - self.text.offset)
            target = pc + immediate
            if self.text.address <= target < self.text.address + self.text.size:
                targets.add(target)
        return targets


def forbidden(name: str) -> bool:
    return any(token in name for token in FORBIDDEN_SYMBOLS)


def validate(data: bytes) -> dict:
    if MARKER not in data:
        raise ValidationError('RPCS3 Core is missing the Build 301 passive-dlopen marker')
    image = MachO(data)
    initializer_addresses = image.initializers()
    initializer_symbols = []
    failures: list[str] = []

    for address in initializer_addresses:
        seed = image.symbol_for(address)
        seed_name = seed.name if seed else f'0x{address:x}'
        initializer_symbols.append(seed_name)
        queue: list[tuple[Symbol, list[str]]] = []
        if seed:
            queue.append((seed, [seed.name]))
        visited: set[int] = set()
        while queue:
            current, path = queue.pop(0)
            if current.address in visited or len(path) > 16:
                continue
            visited.add(current.address)
            if forbidden(current.name):
                failures.append(' -> '.join(path))
                break
            for target in image.direct_branches(current):
                called = image.symbol_for(target)
                if called and called.address not in visited:
                    queue.append((called, path + [called.name]))

    if failures:
        raise ValidationError(
            'dyld initializer reaches forbidden JIT setup:\n' + '\n'.join(sorted(set(failures))[:20])
        )

    return {
        'initializerCount': len(initializer_addresses),
        'initializerSymbols': len(set(initializer_symbols)),
        'marker': MARKER.decode('ascii'),
        'forbiddenReachability': False,
    }


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit('usage: validate_rpcs3_passive_dlopen.py <libRPCS3Core.dylib>')
    path = Path(sys.argv[1])
    try:
        report = validate(path.read_bytes())
    except ValidationError as error:
        raise SystemExit(f'RPCS3 passive-dlopen validation failed: {error}') from error
    print(report)
    print('RPCS3 passive-dlopen Mach-O validation passed.')


if __name__ == '__main__':
    main()
