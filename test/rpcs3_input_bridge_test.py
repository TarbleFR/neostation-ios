from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
ABI = ROOT / 'packages/rpcs3_internal_bridge/ios/Classes/Rpcs3CoreABI.h'
PLUGIN = ROOT / 'packages/rpcs3_internal_bridge/ios/Classes/Rpcs3InternalBridgePlugin.mm'
INPUT = ROOT / 'packages/rpcs3_internal_bridge/ios/Classes/RPCS3GameInputController.mm'
PODSPEC = ROOT / 'packages/rpcs3_internal_bridge/ios/rpcs3_internal_bridge.podspec'

class RPCS3InputBridgeTests(unittest.TestCase):
    def test_pinned_pad_abi(self):
        text = ABI.read_text()
        for token in (
            'uint32_t connected;', 'uint64_t buttons;',
            'rpcs3_ios_pad_cross    = 1ull << 4',
            'rpcs3_ios_pad_circle   = 1ull << 5',
            'rpcs3_ios_pad_square   = 1ull << 6',
            'rpcs3_ios_pad_r1       = 1ull << 9',
            'rpcs3_ios_pad_l2       = 1ull << 10',
            'rpcs3_ios_pad_start    = 1ull << 14',
            'rpcs3_ios_pad_select   = 1ull << 15',
            'rpcs3_ios_status (*set_pad_state)(uint32_t, const rpcs3_ios_pad_state*)',
        ):
            self.assertIn(token, text)

    def test_plugin_loads_pad_symbol(self):
        text = PLUGIN.read_text()
        self.assertIn('LOAD("rpcs3_ios_set_pad_state", set_pad_state);', text)
        self.assertIn('RPCS3GameInputController', text)
        self.assertIn('[controller.inputController start];', text)
        self.assertIn('[controller.inputController stop];', text)

    def test_physical_mapping_and_connected_state(self):
        text = INPUT.read_text()
        self.assertIn('RPCS3SetBit(uint64_t* bits, uint64_t bit', text)
        self.assertIn('rpcs3_ios_pad_cross, pad.buttonA.isPressed', text)
        self.assertIn('rpcs3_ios_pad_circle, pad.buttonB.isPressed', text)
        self.assertIn('rpcs3_ios_pad_square, pad.buttonX.isPressed', text)
        self.assertIn('rpcs3_ios_pad_triangle, pad.buttonY.isPressed', text)
        self.assertIn('state.connected = 1;', text)
        self.assertIn('_api->set_pad_state(0, state);', text)

    def test_touch_is_connected_virtual_pad(self):
        text = INPUT.read_text()
        self.assertIn('BOOL showTouch = self.started && self.physicalController == nil;', text)
        self.assertIn('if (showTouch) [self sendTouchState];', text)
        self.assertIn('_touchState.connected = 1;', text)
        self.assertIn('_touchState.l2 = 1.0f;', text)
        self.assertIn('_touchState.r2 = 1.0f;', text)

    def test_layout_guards(self):
        text = INPUT.read_text()
        self.assertIn('sizeof(rpcs3_ios_pad_state) == 40', text)
        self.assertIn('offsetof(rpcs3_ios_pad_state, connected) == 4', text)
        self.assertIn('offsetof(rpcs3_ios_pad_state, buttons) == 8', text)

    def test_gamecontroller_framework(self):
        self.assertIn("'GameController'", PODSPEC.read_text())

if __name__ == '__main__':
    unittest.main()
