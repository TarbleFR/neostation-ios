from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
ABI = ROOT / 'packages/rpcs3_internal_bridge/ios/Classes/Rpcs3CoreABI.h'
PINNED = Path(sys.argv[1]) / 'rpcs3/ios/RPCS3IOS.h' if len(sys.argv) > 1 else None


class RPCS3PadABITests(unittest.TestCase):
    def test_local_shape_and_bits(self):
        text = ABI.read_text()
        fields = [
            'uint32_t size;',
            'uint32_t connected;',
            'uint64_t buttons;',
            'float left_x;',
            'float left_y;',
            'float right_x;',
            'float right_y;',
            'float l2;',
            'float r2;',
        ]
        positions = [text.index(field) for field in fields]
        self.assertEqual(positions, sorted(positions))

        bits = [
            ('rpcs3_ios_pad_cross', 4),
            ('rpcs3_ios_pad_circle', 5),
            ('rpcs3_ios_pad_square', 6),
            ('rpcs3_ios_pad_r1', 9),
            ('rpcs3_ios_pad_l2', 10),
            ('rpcs3_ios_pad_start', 14),
            ('rpcs3_ios_pad_select', 15),
        ]
        for name, bit in bits:
            pos = text.index(name)
            self.assertIn(f'1ull << {bit}', text[pos:pos + 80])

    def test_pinned_upstream_shape(self):
        if PINNED is None:
            self.skipTest('pinned RPCS3 source path not supplied')

        text = PINNED.read_text()
        for token in (
            'uint32_t struct_size;',
            'uint32_t connected;',
            'uint64_t buttons;',
            'float left_stick_x;',
            'float left_stick_y;',
            'float right_stick_x;',
            'float right_stick_y;',
            'float left_trigger;',
            'float right_trigger;',
            'RPCS3_IOS_PAD_BUTTON_DPAD_UP = UINT64_C(1) << 0',
            'RPCS3_IOS_PAD_BUTTON_DPAD_DOWN = UINT64_C(1) << 1',
            'RPCS3_IOS_PAD_BUTTON_DPAD_LEFT = UINT64_C(1) << 2',
            'RPCS3_IOS_PAD_BUTTON_DPAD_RIGHT = UINT64_C(1) << 3',
            'RPCS3_IOS_PAD_BUTTON_CROSS = UINT64_C(1) << 4',
            'RPCS3_IOS_PAD_BUTTON_CIRCLE = UINT64_C(1) << 5',
            'RPCS3_IOS_PAD_BUTTON_SQUARE = UINT64_C(1) << 6',
            'RPCS3_IOS_PAD_BUTTON_TRIANGLE = UINT64_C(1) << 7',
            'RPCS3_IOS_PAD_BUTTON_L1 = UINT64_C(1) << 8',
            'RPCS3_IOS_PAD_BUTTON_R1 = UINT64_C(1) << 9',
            'RPCS3_IOS_PAD_BUTTON_L2 = UINT64_C(1) << 10',
            'RPCS3_IOS_PAD_BUTTON_R2 = UINT64_C(1) << 11',
            'RPCS3_IOS_PAD_BUTTON_L3 = UINT64_C(1) << 12',
            'RPCS3_IOS_PAD_BUTTON_R3 = UINT64_C(1) << 13',
            'RPCS3_IOS_PAD_BUTTON_START = UINT64_C(1) << 14',
            'RPCS3_IOS_PAD_BUTTON_SELECT = UINT64_C(1) << 15',
            'RPCS3_IOS_PAD_BUTTON_PS = UINT64_C(1) << 16',
        ):
            self.assertIn(token, text)


if __name__ == '__main__':
    if len(sys.argv) > 1:
        sys.argv = [sys.argv[0]]
    unittest.main()
