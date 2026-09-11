from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
ABI = ROOT / 'packages/rpcs3_internal_bridge/ios/Classes/Rpcs3CoreABI.h'
PLUGIN = ROOT / 'packages/rpcs3_internal_bridge/ios/Classes/Rpcs3InternalBridgePlugin.mm'
INPUT = ROOT / 'packages/rpcs3_internal_bridge/ios/Classes/RPCS3GameInputController.mm'
PODSPEC = ROOT / 'packages/rpcs3_internal_bridge/ios/rpcs3_internal_bridge.podspec'


class RPCS3InputBridgeTests(unittest.TestCase):
    def test_pinned_pad_abi_is_exposed(self):
        text = ABI.read_text()
        for token in (
            'rpcs3_ios_pad_cross',
            'rpcs3_ios_pad_circle',
            'rpcs3_ios_pad_select',
            'rpcs3_ios_pad_start',
            'float left_x;',
            'float right_y;',
            'rpcs3_ios_status (*set_pad_state)(uint32_t, const rpcs3_ios_pad_state*)',
        ):
            self.assertIn(token, text)

    def test_plugin_requires_core_pad_symbol_and_installs_input_owner(self):
        text = PLUGIN.read_text()
        self.assertIn('LOAD("rpcs3_ios_set_pad_state", set_pad_state);', text)
        self.assertIn('RPCS3GameInputController', text)
        self.assertIn('initWithHostView:controller.view api:&self->_api', text)
        self.assertIn('[controller.inputController start];', text)
        self.assertIn('[controller.inputController stop];', text)

    def test_physical_controller_mapping_includes_back_and_ps3_layout(self):
        text = INPUT.read_text()
        self.assertIn('GCControllerDidConnectNotification', text)
        self.assertIn('GCControllerDidDisconnectNotification', text)
        self.assertIn('rpcs3_ios_pad_cross, pad.buttonA.isPressed', text)
        # East face button maps to PS3 Circle, which restores in-game Back.
        self.assertIn('rpcs3_ios_pad_circle, pad.buttonB.isPressed', text)
        self.assertIn('rpcs3_ios_pad_square, pad.buttonX.isPressed', text)
        self.assertIn('rpcs3_ios_pad_triangle, pad.buttonY.isPressed', text)
        self.assertIn('rpcs3_ios_pad_start, menu.isPressed', text)
        self.assertIn('rpcs3_ios_pad_select, options.isPressed', text)
        self.assertIn('_api->set_pad_state(0, state);', text)

    def test_touch_controls_are_automatic_without_physical_controller(self):
        text = INPUT.read_text()
        self.assertIn('NEOSTATION_RPCS3_INPUT_V1', text)
        self.assertIn('BOOL showTouch = self.started && self.physicalController == nil;', text)
        for label in ('@"▲"', '@"▼"', '@"◀"', '@"▶"', '@"□"', '@"✕"', '@"○"', '@"△"'):
            self.assertIn(label, text)
        self.assertIn('self.leftStick.valueChanged', text)
        self.assertIn('self.rightStick.valueChanged', text)
        self.assertIn('_touchState.l2 = 1.0f;', text)
        self.assertIn('_touchState.r2 = 1.0f;', text)

    def test_gamecontroller_framework_is_linked(self):
        self.assertIn("'GameController'", PODSPEC.read_text())


if __name__ == '__main__':
    unittest.main()