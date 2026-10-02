from pathlib import Path
import os
import subprocess
import tempfile
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
        self.assertIn('_api->set_pad_state(0, &gameplayState);', text)

    def test_touch_is_connected_virtual_pad(self):
        text = INPUT.read_text()
        # The existing touch toggle is also part of visibility policy.
        self.assertIn('BOOL showTouch = self.started && self.physicalController == nil && self.touchControlsEnabled;', text)
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

    def test_embedded_menu_routing_behavior(self):
        with tempfile.TemporaryDirectory() as temporary:
            executable = Path(temporary) / 'rpcs3_embedded_menu_input_test'
            subprocess.run([
                os.environ.get('CXX', 'c++'), '-std=c++20', '-Wall', '-Wextra', '-Werror',
                '-I', str(INPUT.parent),
                str(ROOT / 'test/native/rpcs3_embedded_menu_input_test.cpp'),
                '-o', str(executable),
            ], check=True)
            subprocess.run([str(executable)], check=True, timeout=10)

    def test_only_neostation_menu_is_wired(self):
        text = INPUT.read_text()
        self.assertNotIn('psButton', text)
        self.assertNotIn('makeButton:@"PS"', text)
        self.assertIn('_menuInput.consume(gameplayState)', text)
        self.assertIn('if (openMenu && self.started && self.menuRequested) self.menuRequested();', text)
        plugin = PLUGIN.read_text()
        self.assertIn('controller.inputController.menuRequested = controller.menuHandler;', plugin)
        self.assertIn('controller.menuHandler = ^{ [weakSelf showGameMenu]; };', plugin)
        self.assertIn('if (!controller || controller.presentedViewController) return;', plugin)

if __name__ == '__main__':
    unittest.main()
