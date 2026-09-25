#!/usr/bin/env python3
"""Execute the pinned donor's real SystemBMGHolder::Init and BMG parser.

This is not a mock implementation of language selection: the exact ARM64
instructions from the donor/packaged IPA run against synthetic guest BMG data.
It also proves that updating SystemManager alone leaves the holder stale.
"""
from __future__ import annotations
import argparse
import hashlib
from pathlib import Path
import struct
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'build-utils/kartpad'))
from patch_donor_language_bridge import parse_macho, load_symbols, vm_to_file
from unicorn import Uc, UC_ARCH_ARM64, UC_MODE_ARM
from unicorn import arm64_const as arm

FUNCTIONS = {
    '_func_80637A20': (300, 'c0480a9d3ea7671c52e7eeef7058953ee0c379301356f68b3c423e8f31a16d33'),
    '_func_805F8C00': (620, 'e330b37b4ec54076cef67ab5fe715233edb3775008b4fa38ba68f17b8d63929e'),
}
OFFSETS = {1: 0, 2: 0x248, 3: 0x124, 4: 0x490, 5: 0x36c, 6: 0}


def verify(runtime: Path) -> None:
    data = runtime.read_bytes()
    segments, table = parse_macho(data)
    symbols, _ = load_symbols(data, table)
    for name, (size, expected) in FUNCTIONS.items():
        offset = vm_to_file(segments, symbols[name])
        actual = hashlib.sha256(data[offset:offset + size]).hexdigest()
        assert actual == expected, f'pinned guest BMG function drift: {name}'

    for slide in (0, 0x4000, 0x47F1000):
        uc = Uc(UC_ARCH_ARM64, UC_MODE_ARM)
        mapped: set[int] = set()

        def put(address: int, value: bytes):
            for page in range(address & ~4095, (address + len(value) + 4095) & ~4095, 4096):
                if page not in mapped:
                    uc.mem_map(page, 4096)
                    mapped.add(page)
            uc.mem_write(address, value)

        for name, (size, _) in FUNCTIONS.items():
            address = symbols[name]
            offset = vm_to_file(segments, address)
            put(address + slide, data[offset:offset + size])
        flat = 0x2000000000
        put(symbols['__ZN9GuestFlat14gFlatGuestBaseE'] + slide, struct.pack('<Q', flat))
        system = 0x81000000
        holder = 0x81001000
        messages = 0x80898150
        put(flat + 0x80386000, struct.pack('>I', system))
        put(flat + system, bytes(0x100))
        put(flat + holder, bytes([0xA5]) * 0x100)
        for offset in set(OFFSETS.values()):
            blob = bytearray(0x124)
            blob[:8] = b'MESGbmg1'
            struct.pack_into('>II', blob, 8, len(blob), 4)
            for index, tag in enumerate((b'INF1', b'DAT1', b'STR1', b'MID1')):
                start = 0x20 + index * 0x20
                blob[start:start + 4] = tag
                struct.pack_into('>I', blob, start + 4, 0x20)
            put(flat + messages + offset, bytes(blob))
        cpu = 0x1234567100
        stack = 0x2345678800
        done = 0x3456789000
        put(cpu, bytes(464))
        put(stack - 0x800, bytes(0x1000))
        put(done, b'\x1f\x20\x03\xd5')
        original_neighbors = bytes(uc.mem_read(flat + holder + 20, 0x100 - 20))
        previous_holder = bytes(uc.mem_read(flat + holder, 20))
        # Repeated EN -> FR -> DE -> ES -> IT -> NL -> EN changes in one runtime.
        for language in (1, 3, 2, 4, 5, 6, 1):
            asset_language = 1 if language == 6 else language
            uc.mem_write(flat + system + 0x5c, struct.pack('>I', asset_language))
            assert bytes(uc.mem_read(flat + holder, 20)) == previous_holder, 'negative control changed holder'
            uc.mem_write(cpu + 12, struct.pack('<I', holder))
            uc.reg_write(arm.UC_ARM64_REG_X0, cpu)
            uc.reg_write(arm.UC_ARM64_REG_SP, stack)
            uc.reg_write(arm.UC_ARM64_REG_X30, done)
            uc.emu_start(symbols['_func_80637A20'] + slide, done, count=2000)
            assert uc.reg_read(arm.UC_ARM64_REG_PC) == done
            assert uc.reg_read(arm.UC_ARM64_REG_SP) == stack
            selected = messages + OFFSETS[language]
            expected = (selected, selected + 0x28, selected + 0x48,
                        selected + 0x68, selected + 0x88)
            actual_holder = bytes(uc.mem_read(flat + holder, 20))
            assert struct.unpack('>IIIII', actual_holder) == expected, (language, slide)
            assert bytes(uc.mem_read(flat + holder + 20, 0x100 - 20)) == original_neighbors
            previous_holder = actual_holder
    print('PASS: 21 real donor BMG rebindings, all PAL languages, stale-holder negative control, ASLR and neighboring memory')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--runtime', required=True, type=Path)
    verify(parser.parse_args().runtime)
