"""Validate the production XIB adapter without inventing alternate layouts."""
import importlib.util
from pathlib import Path
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    'touch_resources', ROOT / 'packages/dolphin_internal_bridge/ci/materialize_touch_resources.py')
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)
FIXTURE = b'''<document><objects><view id="pad"><subviews>
<button id="A" buttonType="roundedRect" customClass="TCButton" customModule="DolphiniOS">
<state key="normal" title="Button"/><buttonConfiguration style="plain"/>
<userDefinedRuntimeAttributes><userDefinedRuntimeAttribute keyPath="controllerButton" type="number">
<integer key="value" value="100"/></userDefinedRuntimeAttribute></userDefinedRuntimeAttributes></button>
<button id="unrelated" buttonType="roundedRect"><state key="normal" title="Menu"/></button>
<view id="stick" customClass="TCJoystick" customModule="DolphiniOS"/>
</subviews><constraints><constraint firstItem="A" firstAttribute="trailing" constant="20" id="position"/>
</constraints></view></objects></document>'''


class DolphinTouchResourceTests(unittest.TestCase):
    def test_virtual_buttons_are_custom_without_system_title_or_configuration(self):
        result = ET.fromstring(MODULE.adapt_touch_layout(FIXTURE))
        button = result.find('.//button[@id="A"]')
        self.assertEqual(button.get('buttonType'), 'custom')
        self.assertEqual(button.get('customModule'), 'dolphin_internal_bridge')
        self.assertNotIn('title', button.find('state').attrib)
        self.assertIsNone(button.find('buttonConfiguration'))

    def test_controller_mapping_ids_and_constraints_are_preserved(self):
        original = ET.fromstring(FIXTURE)
        adapted = ET.fromstring(MODULE.adapt_touch_layout(FIXTURE))
        for selector in ['.//constraints', './/userDefinedRuntimeAttributes']:
            self.assertEqual(ET.tostring(original.find(selector)), ET.tostring(adapted.find(selector)))
        self.assertEqual([v.get('id') for v in original.iter() if 'id' in v.attrib],
                         [v.get('id') for v in adapted.iter() if 'id' in v.attrib])

    def test_unrelated_buttons_are_not_restyled(self):
        result = ET.fromstring(MODULE.adapt_touch_layout(FIXTURE))
        button = result.find('.//button[@id="unrelated"]')
        self.assertEqual(button.get('buttonType'), 'roundedRect')
        self.assertEqual(button.find('state').get('title'), 'Menu')

    def test_container_views_allow_multiple_simultaneous_fingers(self):
        result = ET.fromstring(MODULE.adapt_touch_layout(FIXTURE))
        self.assertTrue(all(view.get('multipleTouchEnabled') == 'YES' for view in result.iter('view')))

    def test_adaptation_is_idempotent(self):
        first = MODULE.adapt_touch_layout(FIXTURE)
        self.assertEqual(MODULE.adapt_touch_layout(first), first)

    def test_malformed_layout_is_rejected(self):
        with self.assertRaises(ET.ParseError):
            MODULE.adapt_touch_layout(b'<document>')


if __name__ == '__main__':
    unittest.main()
