#!/usr/bin/env python3
"""Execute the real ARM64 language stub with Unicorn, not a source-string test.

Install the CI-pinned test dependency with: pip install unicorn==2.1.2
Run with --runtime PATH to validate/emulate the exact packaged donor bytes too.
No missing-dependency skip is allowed for this regression gate.
"""
from __future__ import annotations

import argparse
import contextlib
import io
from pathlib import Path
import struct
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "build-utils/kartpad"))
import patch_donor_language_bridge as bridge

try:
    from unicorn import Uc, UC_ARCH_ARM64, UC_MODE_ARM, UC_PROT_READ, UC_PROT_EXEC
    from unicorn import arm64_const as arm
except ImportError as exc:
    raise SystemExit("Install required ABI test dependency: unicorn==2.1.2") from exc

FUNCTION = 0x102F62774
SLOT = 0x105348563
SLIDES = (0, 0x1000, 0x4000, 0x47F1000, 0x400000000)
LANGUAGES = (1, 2, 3, 4, 5, 6, 0, 255)
RUNTIME: Path | None = None


def execute(code: bytes, function: int, slot: int, language: int):
    """Run at a high 64-bit context pointer; retain byte-for-byte witnesses."""
    uc = Uc(UC_ARCH_ARM64, UC_MODE_ARM)
    page = function & ~0xFFF
    uc.mem_map(page, 0x2000)
    uc.mem_write(function, code)
    uc.mem_protect(page, 0x2000, UC_PROT_READ | UC_PROT_EXEC)
    slot_page = slot & ~0xFFF
    uc.mem_map(slot_page, 0x1000)
    slot_before = bytearray(b'\xA5' * 0x1000)
    slot_before[slot & 0xFFF] = language
    uc.mem_write(slot_page, bytes(slot_before))
    context_page = 0x1234567000
    context = context_page + 0x100
    uc.mem_map(context_page, 0x1000)
    context_before = bytes((i * 73 + 19) & 255 for i in range(0x1000))
    uc.mem_write(context_page, context_before)
    stack_page = 0x2345678000
    uc.mem_map(stack_page, 0x1000)
    stack_before = b'\x5A' * 0x1000
    uc.mem_write(stack_page, stack_before)
    return_pc = 0x3456789000
    uc.mem_map(return_pc, 0x1000)
    initial_registers = {}
    for i in range(31):
        register = getattr(arm, f'UC_ARM64_REG_X{i}')
        value = (0x1111111111111111 * (i + 1)) & ((1 << 64) - 1)
        if i == 0:
            value = context
        elif i == 30:
            value = return_pc
        uc.reg_write(register, value)
        initial_registers[register] = value
    uc.reg_write(arm.UC_ARM64_REG_SP, stack_page + 0x800)
    uc.reg_write(arm.UC_ARM64_REG_NZCV, 0xA0000000)
    for i in range(32):
        uc.reg_write(getattr(arm, f'UC_ARM64_REG_Q{i}'), (i + 1) * 0x123456789ABCDEF)
    uc.emu_start(function, return_pc, count=8)
    assert uc.reg_read(arm.UC_ARM64_REG_PC) == return_pc, 'stub did not return'
    expected = bytearray(context_before)
    struct.pack_into('<I', expected, 0x100 + bridge.CPU_CONTEXT_R3_OFFSET, language)
    return uc, {
        'context': bytes(uc.mem_read(context_page, 0x1000)),
        'expected': bytes(expected),
        'original': context_before,
        'slot': bytes(uc.mem_read(slot_page, 0x1000)),
        'slot_before': bytes(slot_before),
        'stack': bytes(uc.mem_read(stack_page, 0x1000)),
        'stack_before': stack_before,
        'registers': initial_registers,
        'sp': stack_page + 0x800,
    }


def assert_guest_abi(test: unittest.TestCase, code: bytes, function: int, slot: int):
    for slide in SLIDES:
        for language in LANGUAGES:
            with test.subTest(slide=hex(slide), language=language):
                uc, witness = execute(code, function + slide, slot + slide, language)
                test.assertEqual(witness['context'], witness['expected'], 'only guest r3 may change')
                test.assertEqual(witness['slot'], witness['slot_before'], 'language/aspect neighbors changed')
                test.assertEqual(witness['stack'], witness['stack_before'], 'native stack changed')
                for register, expected in witness['registers'].items():
                    if register != arm.UC_ARM64_REG_X8:
                        test.assertEqual(uc.reg_read(register), expected, f'ARM64 register {register} changed')
                test.assertEqual(uc.reg_read(arm.UC_ARM64_REG_SP), witness['sp'])
                test.assertEqual(uc.reg_read(arm.UC_ARM64_REG_NZCV), 0xA0000000)
                for i in range(32):
                    test.assertEqual(uc.reg_read(getattr(arm, f'UC_ARM64_REG_Q{i}')),
                                     (i + 1) * 0x123456789ABCDEF)


def fixture(*, overlap: bool = False, short_function: bool = False) -> bytes:
    """Small Mach-O fixture with file-backed TEXT and zero-fill DATA padding."""
    data = bytearray(0x5000)
    text_vm = 0x100000000
    data_vm = text_vm + 0x8000
    symbols = (
        (bridge.SCGETLANGUAGE_SYMBOL, text_vm + 0x200),
        ('_next_function', text_vm + 0x200 + (12 if short_function else 0x100)),
        (bridge.ASPECT_SYMBOL, data_vm + 0x122),
        ('_next_data', data_vm + (0x123 if overlap else 0x128)),
    )
    commands = bytearray()
    for name, vm, size, off, file_size, prot in (
            (b'__TEXT', text_vm, 0x4000, 0, 0x4000, 5),
            (b'__DATA', data_vm, 0x1000, 0, 0, 3)):
        commands.extend(struct.pack('<II16sQQQQiiII', 0x19, 72, name, vm, size,
                                    off, file_size, prot, prot, 0, 0))
    strings = bytearray(b'\0')
    entries = bytearray()
    for name, address in symbols:
        entries.extend(bridge.NLIST_64.pack(len(strings), 0xF, 1, 0, address))
        strings.extend(name.encode() + b'\0')
    symoff = 0x4000
    stroff = symoff + len(entries)
    commands.extend(struct.pack('<IIIIII', 2, 24, symoff, len(symbols), stroff, len(strings)))
    bridge.HEADER.pack_into(data, 0, bridge.MH_MAGIC_64, 0x100000C, 0, 6, 3, len(commands), 0, 0)
    data[32:32 + len(commands)] = commands
    data[0x200:0x210] = bridge.EXPECTED_PROLOGUE
    data[symoff:symoff + len(entries)] = entries
    data[stroff:stroff + len(strings)] = strings
    return bytes(data)


class LanguageBridgeTests(unittest.TestCase):
    def test_corrected_arm64_guest_abi_all_languages_and_slides(self):
        assert_guest_abi(self, bridge.bridge_bytes(FUNCTION, SLOT), FUNCTION, SLOT)

    def test_negative_adrp_displacement(self):
        function, slot = 0x107FFF774, 0x101003563
        assert_guest_abi(self, bridge.bridge_bytes(function, slot), function, slot)

    def test_build334_defect_is_reproduced(self):
        # Exact broken entry bytes extracted from the user-tested Build 334 IPA.
        legacy = bytes.fromhex('281f01d0008d5539c0035fd6')
        for language in (1, 3, 6):
            uc, witness = execute(legacy, FUNCTION, SLOT, language)
            self.assertEqual(witness['context'], witness['original'])
            self.assertNotEqual(witness['context'], witness['expected'])
            self.assertEqual(uc.reg_read(arm.UC_ARM64_REG_X0), language)
            self.assertNotEqual(uc.reg_read(arm.UC_ARM64_REG_X0),
                                witness['registers'][arm.UC_ARM64_REG_X0])

    def test_patcher_changes_only_verified_sixteen_byte_span(self):
        source = fixture()
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'runtime'
            path.write_bytes(source)
            with contextlib.redirect_stdout(io.StringIO()):
                bridge.patch(path)
            patched = path.read_bytes()
            self.assertEqual(patched[:0x200], source[:0x200])
            self.assertEqual(patched[0x210:], source[0x210:])
            self.assertEqual(bridge.validate_bridge(patched)['guestReturnOffset'], 12)
            with self.assertRaisesRegex(SystemExit, 'prologue drifted'):
                bridge.patch(path)

    def test_rejects_legacy_bridge_even_with_valid_macho(self):
        data = bytearray(fixture())
        function, offset, slot = bridge.bridge_layout(data)
        data[offset:offset + 12] = struct.pack('<III', bridge.encode_adrp(8, function, slot),
                                              bridge.encode_ldrb_w(0, 8, slot & 0xFFF), 0xD65F03C0)
        with self.assertRaisesRegex(SystemExit, 'guest ABI bridge missing or invalid'):
            bridge.validate_bridge(data)

    def test_rejects_changed_fourth_original_instruction(self):
        data = bytearray(fixture())
        data[0x20C] ^= 1
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'runtime'
            path.write_bytes(data)
            with self.assertRaisesRegex(SystemExit, 'prologue drifted'):
                bridge.patch(path)
            self.assertEqual(path.read_bytes(), bytes(data))

    def test_rejects_padding_overlap_and_short_function(self):
        for kwargs in ({'overlap': True}, {'short_function': True}):
            with self.subTest(kwargs=kwargs), self.assertRaises(SystemExit):
                bridge.bridge_layout(fixture(**kwargs))

    def test_rejects_truncated_or_wrong_architecture(self):
        for source in (b'', fixture()[:48]):
            with self.assertRaises(SystemExit):
                bridge.bridge_layout(source)
        source = bytearray(fixture())
        struct.pack_into('<i', source, 4, 0x1000007)
        with self.assertRaisesRegex(SystemExit, 'arm64 MH_DYLIB'):
            bridge.bridge_layout(source)

    def test_encoder_rejects_out_of_range_or_unaligned_operands(self):
        for callback in (
                lambda: bridge.encode_adrp(8, 0, 1 << 32),
                lambda: bridge.encode_ldrb_w(8, 8, 4096),
                lambda: bridge.encode_str_w(8, 0, 13)):
            with self.assertRaises(SystemExit):
                callback()


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--runtime', type=Path)
    args = parser.parse_args()
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(LanguageBridgeTests)
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    if not result.wasSuccessful():
        raise SystemExit(1)
    if args.runtime:
        data = args.runtime.read_bytes()
        report = bridge.validate_bridge(data)
        function, offset, slot = bridge.bridge_layout(data)
        assert_guest_abi(unittest.TestCase(), data[offset:offset + bridge.BRIDGE_SIZE], function, slot)
        print(f'PASS: exact donor instructions executed in 40 language/ASLR cases: {report}')
    print('PASS: ARM64 guest ABI regression, Build 334 negative control, and fail-closed patch boundaries')
