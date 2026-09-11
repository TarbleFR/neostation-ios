from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
ABI = ROOT / 'packages/rpcs3_internal_bridge/ios/Classes/Rpcs3CoreABI.h'
PINNED = Path(sys.argv[1]) / 'rpcs3/ios/RPCS3IOS.h' if len(sys.argv) > 1 else None

class RPCS3PadABITests(unittest.TestCase):
    def test_local_shape_and_bits(self):
        text = ABI.read_text()
        fields = ['uint32_t size;', 'uint32_t connected;', 'uint64_t buttons;',
                  'float left_x;', 'float left_y;', 'float right_x;', 'float right_y;',
                  'float l2;', 'float r2;']
        positions = [text.index(field) for field in fields]
        self.assertEqual(positions, sorted(positions))
        bits = [('rpcs3_ios_pad_cross', 4), ('rpcs3_ios_pad_circle', 5),
                ('rpcs3_ios_pad_square', 6), ('rpcs3_ios_pad_r1', 9),
                ('rpcs3_ios_pad_l2', 10), ('rpcs3_ios_pad_start', 14),
                ('rpcs3_ios_pad_select', 15)]
        for name, bit in bits:
            pos = text.index(name)
            self.assertIn(f'1ull << {bit}', text[pos:pos + 80])

    def test_pinned_upstream_shape(self):
        if PINNED is None:
            self.skipTest('pinned RPCS3 source path not supplied')
        text = PINNED.read_text()
        for token in ('uint32_t struct_size;', 'uint32_t connected;', 'uint64_t buttons;',
                      'float left_stick_x;', 'float right_stick_y;',
                      'float left_trigger;', 'float right_trigger;',
                      'RPCS3_IOS_PAD_BUTTON_CROSS     = 1ull << 4',
                      'RPCS3_IOS_PAD_BUTTON_R1        = 1ull << 9',
                      'RPCS3_IOS_PAD_BUTTON_START     = 1ull << 14',
                      'RPCS3_IOS_PAD_BUTTON_SELECT    = 1ull << 15'):
            self.assertIn(token, text)

if __name__ == '__main__':
    if len(sys.argv) > 1:
        sys.argv = [sys.argv[0]]
    unittest.main()
