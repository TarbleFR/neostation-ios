"""Regressions for SYSTEM settings and the original touch resource adaptation."""
import importlib.util
from pathlib import Path
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    'dolphin_touch_materializer',
    ROOT / 'packages/dolphin_internal_bridge/ci/materialize_touch_resources.py',
)
MATERIALIZER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MATERIALIZER)


class TouchResourceTests(unittest.TestCase):
    def adapt(self, source):
        return ET.fromstring(MATERIALIZER.adapt_touch_layout(source))

    def test_only_controller_buttons_become_custom(self):
        root = self.adapt(b'<view><button buttonType="roundedRect" customClass="TCButton" '
                          b'customModule="DolphiniOS"/><button buttonType="roundedRect" id="menu"/></view>')
        control, menu = root.findall('button')
        self.assertEqual(control.get('buttonType'), 'custom')
        self.assertEqual(control.get('customModule'), 'dolphin_internal_bridge')
        self.assertEqual(menu.get('buttonType'), 'roundedRect')

    def test_adaptation_is_idempotent(self):
        source = b'<view><button customClass="TCButton" buttonType="roundedRect"/></view>'
        adapted = MATERIALIZER.adapt_touch_layout(source)
        self.assertEqual(MATERIALIZER.adapt_touch_layout(adapted), adapted)

    def test_missing_type_gets_custom(self):
        control = self.adapt(b'<button customClass="TCButton"/>')
        self.assertEqual(control.get('buttonType'), 'custom')

    def test_original_geometry_constraints_and_art_are_preserved(self):
        source = (b'<button customClass="TCButton"><rect key="frame" x="42" width="50"/>'
                  b'<constraints><constraint firstAttribute="width" constant="50"/></constraints>'
                  b'<state key="normal" image="wii_a"/></button>')
        original = ET.fromstring(source)
        adapted = self.adapt(source)
        self.assertEqual(ET.tostring(original.find('rect')), ET.tostring(adapted.find('rect')))
        self.assertEqual(ET.tostring(original.find('constraints')), ET.tostring(adapted.find('constraints')))
        self.assertEqual(adapted.find('state').get('image'), 'wii_a')

    def test_placeholder_title_and_system_configuration_are_removed(self):
        root = self.adapt(b'<button customClass="TCButton"><state key="normal" title="Button"/>'
                          b'<buttonConfiguration style="plain"/></button>')
        self.assertIsNone(root.find('state').get('title'))
        self.assertIsNone(root.find('buttonConfiguration'))

    def test_views_allow_simultaneous_controller_fingers(self):
        root = self.adapt(b'<view><view/></view>')
        self.assertTrue(all(view.get('multipleTouchEnabled') == 'YES' for view in root.iter('view')))


class SystemSettingsSourceTests(unittest.TestCase):
    def test_label_is_in_system_emulator_tab_not_game_settings(self):
        source = (ROOT / 'lib/widgets/system_emulator_settings_dialog.dart').read_text()
        self.assertIn('DolphinSystemEmulatorCard.appliesTo', source)
        self.assertIn('isIOS: Platform.isIOS', source)
        self.assertIn('DolphinSystemEmulatorCard()', source)
        card = (ROOT / 'packages/dolphin_internal_bridge/lib/dolphin_system_emulator_card.dart').read_text()
        self.assertIn("title: Text('Dolphin iOS')", card)
        self.assertIn("system == 'gc' || system == 'wii'", card)
        self.assertNotIn('onTap:', card)
        self.assertNotIn('setDefault', card)
        tabs = (ROOT / 'lib/widgets/system_emulator_settings_dialog/tabs.dart').read_text()
        self.assertIn('return _buildCoresList();', tabs)

    def test_correct_system_files_are_audited_as_shared_code(self):
        guard = (ROOT / 'build-utils/check_dolphin_isolation_v2.py').read_text()
        shared = guard.split('SHARED_FILES = {', 1)[1].split('\n}', 1)[0]
        self.assertIn('lib/widgets/system_emulator_settings_dialog.dart', shared)


if __name__ == '__main__':
    unittest.main()
