"""Regression coverage for the generated iOS host's CocoaPods configuration."""
from __future__ import annotations
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('dolphin_config', ROOT / 'build-utils/configure_dolphin_ios_v2.py')
assert SPEC and SPEC.loader
CONFIG = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CONFIG)


class DolphinXcconfigTests(unittest.TestCase):
    def test_loads_pods_before_flutter_and_preserves_existing_settings(self):
        with tempfile.TemporaryDirectory() as temporary:
            ios = Path(temporary)
            (ios / 'Flutter').mkdir()
            original = '#include "Generated.xcconfig"\nOTHER_SETTING = unchanged\n'
            for name in ('Debug', 'Release'):
                (ios / 'Flutter' / (name + '.xcconfig')).write_text(original)
            untouched = ios / 'OtherEmulator.xcconfig'
            untouched.write_text('OTHER_EMULATOR = unchanged\n')
            with patch.object(CONFIG, 'IOS', ios):
                CONFIG.configure_flutter_xcconfigs()
                before = {p.name: p.read_bytes() for p in (ios / 'Flutter').glob('*.xcconfig')}
                CONFIG.configure_flutter_xcconfigs()
                CONFIG.configure_flutter_xcconfigs()
                after = {p.name: p.read_bytes() for p in (ios / 'Flutter').glob('*.xcconfig')}
            self.assertEqual(before, after)
            for name in ('Debug', 'Release'):
                result = after[name + '.xcconfig'].decode()
                expected = '#include? "Pods/Target Support Files/Pods-Runner/Pods-Runner.' + name.lower() + '.xcconfig"\n'
                self.assertEqual(result, expected + original)
            self.assertEqual(untouched.read_text(), 'OTHER_EMULATOR = unchanged\n')
            self.assertFalse((ios / 'Flutter/Profile.xcconfig').exists())

    def test_does_not_duplicate_existing_pods_includes(self):
        with tempfile.TemporaryDirectory() as temporary:
            ios = Path(temporary)
            (ios / 'Flutter').mkdir()
            for name in ('Debug', 'Release', 'Profile'):
                value = '#include "../Pods/Target Support Files/Pods-Runner/Pods-Runner.' + name.lower() + '.xcconfig"\n#include "Generated.xcconfig"\n'
                (ios / 'Flutter' / (name + '.xcconfig')).write_text(value)
            before = {p.name: p.read_bytes() for p in (ios / 'Flutter').glob('*.xcconfig')}
            with patch.object(CONFIG, 'IOS', ios):
                CONFIG.configure_flutter_xcconfigs()
            self.assertEqual(before, {p.name: p.read_bytes() for p in (ios / 'Flutter').glob('*.xcconfig')})

    def test_rejects_missing_flutter_include(self):
        with tempfile.TemporaryDirectory() as temporary:
            ios = Path(temporary)
            (ios / 'Flutter').mkdir()
            (ios / 'Flutter/Debug.xcconfig').write_text('UNRELATED_SETTING = preserve\n')
            with patch.object(CONFIG, 'IOS', ios), self.assertRaises(SystemExit):
                CONFIG.configure_flutter_xcconfigs()
            self.assertEqual((ios / 'Flutter/Debug.xcconfig').read_text(), 'UNRELATED_SETTING = preserve\n')

    def test_only_dolphin_helper_requires_extension_safe_apis(self):
        source = (ROOT / 'build-utils/configure_dolphin_ios_v2.py').read_text()
        helper = source.split('helper.build_configurations.each do |configuration|')[-1].split('runner.build_configurations.each')[0]
        self.assertIn("settings['APPLICATION_EXTENSION_API_ONLY'] = 'YES'", helper)
        host = source.split('runner.build_configurations.each do |configuration|')[-1]
        self.assertNotIn("settings['APPLICATION_EXTENSION_API_ONLY']", host)
        pod = (ROOT / 'packages/dolphin_jit_helper/ios/dolphin_jit_helper.podspec').read_text()
        self.assertIn("'APPLICATION_EXTENSION_API_ONLY' => 'YES'", pod)


if __name__ == '__main__':
    unittest.main()
