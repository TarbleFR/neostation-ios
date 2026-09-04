"""Unit fixtures exercise parsing only; they are never packaged as release IPAs."""
import importlib.util
import struct
import unittest
from pathlib import Path

SOURCE = Path(__file__).resolve().parents[1] / 'packages/dolphin_internal_bridge/ci/verify_ipa.py'
spec = importlib.util.spec_from_file_location('dolphin_ipa_verifier', SOURCE)
verifier = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verifier)


def image(commands=(), tail=b'', cpu=verifier.ARM64):
    blob = b''.join(commands)
    return struct.pack('<IiiIIIII', 0xFEEDFACF, cpu, 0, 6, len(commands), len(blob), 0, 0) + blob + tail


def dylib_command(cmd, value):
    text = value.encode() + b'\0'
    size = (24 + len(text) + 7) // 8 * 8
    return struct.pack('<IIIIII', cmd, size, 24, 0, 0, 0) + text + b'\0' * (size - 24 - len(text))


class ParserTests(unittest.TestCase):
    def test_not_a_macho(self):
        with self.assertRaises(ValueError):
            verifier.macho(b'not a library')

    def test_wrong_cpu_is_rejected(self):
        with self.assertRaises(ValueError):
            verifier.macho(image(cpu=0x01000007))

    def test_truncated_commands_are_rejected(self):
        with self.assertRaises(ValueError):
            verifier.macho(image([struct.pack('<II', 0xC, 64)]))

    def test_library_id_is_not_a_linkage_dependency(self):
        value = '@rpath/DolphinCore.framework/DolphinCore'
        parsed = verifier.macho(image([dylib_command(0xD, value)]))
        self.assertEqual(parsed['id'], value)
        self.assertEqual(parsed['dependencies'], [])

    def test_strong_and_weak_dependencies(self):
        parsed = verifier.macho(image([dylib_command(0xC, '@rpath/Required'),
                                       dylib_command(0x80000018, '/usr/lib/Weak')]))
        self.assertEqual([d['weak'] for d in parsed['dependencies']], [False, True])

    def test_ios_and_simulator_remain_distinct(self):
        ios = struct.pack('<IIIIII', 0x32, 24, 2, (17 << 16) | (4 << 8), 0, 0)
        sim = struct.pack('<IIIIII', 0x32, 24, 7, (17 << 16), 0, 0)
        self.assertEqual(verifier.macho(image([ios]))['platform'], 2)
        self.assertEqual(verifier.macho(image([sim]))['platform'], 7)
        self.assertEqual(verifier.macho(image([ios]))['minimumOS'], '17.4.0')

    def test_real_symbol_table_distinguishes_defined_from_undefined(self):
        strings = b'\0_bridge_defined\0_bridge_imported\0'
        symbols = struct.pack('<IBBHQ', 1, 0x0F, 1, 0, 0x1000)
        symbols += struct.pack('<IBBHQ', 17, 0x01, 0, 0, 0)
        symcmd = struct.pack('<IIIIII', 2, 24, 56, 2, 88, len(strings))
        parsed = verifier.macho(image([symcmd], symbols + strings))
        self.assertEqual(parsed['definedSymbols'], ['_bridge_defined'])
        self.assertEqual(parsed['undefinedSymbols'], ['_bridge_imported'])

    def test_malformed_fat_slice_is_rejected(self):
        data = struct.pack('>IIIIIII', 0xCAFEBABE, 1, verifier.ARM64, 0, 200, 50, 0)
        with self.assertRaises(ValueError):
            verifier.macho(data)


if __name__ == '__main__':
    unittest.main()
