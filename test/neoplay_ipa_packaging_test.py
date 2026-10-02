from pathlib import Path
import importlib.util
import json
import plistlib
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('neoplay_ipa', ROOT / 'build-utils/validate_neoplay_ipa.py')
validator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(validator)
SHA = 'a' * 40

class NeoPlayPackagingTests(unittest.TestCase):
    def fixture(self, root, omit='', build='397', native_minimum='18.0'):
        app = 'Payload/Runner.app/'
        members = {
            'Info.plist': plistlib.dumps({'CFBundleVersion': build, 'NSBonjourServices': list(validator.SERVICES), 'NSLocalNetworkUsageDescription': 'Local screens', 'NSAppTransportSecurity': {'NSAllowsLocalNetworking': True}}),
            'Frameworks/neoplay_bridge.framework/neoplay_bridge': b'\xcf\xfa\xed\xfe' + b' '.join(validator.MARKERS),
            'Frameworks/neoplay_bridge.framework/Info.plist': plistlib.dumps({'MinimumOSVersion': native_minimum}),
            'NeoPlay-build-identity.json': json.dumps({'build': '397', 'commit': SHA, 'physicalTVValidation': False}).encode(),
            'NeoPlay-Pods-acknowledgements.plist': plistlib.dumps({}),
        }
        members.update({language + '.lproj/InfoPlist.strings': plistlib.dumps({'NSLocalNetworkUsageDescription': 'Local'}) for language in validator.LANGUAGES})
        file = Path(root) / 'candidate.ipa'
        with zipfile.ZipFile(file, 'w') as archive:
            for name, data in members.items():
                if name != omit:
                    archive.writestr(app + name, data)
        return file
    def test_packaging_contract_accepts_complete_fixture_without_device_claim(self):
        with tempfile.TemporaryDirectory() as root:
            result = validator.validate(self.fixture(root), '397', SHA)
            self.assertTrue(result['neoplayPackaged'])
            self.assertFalse(result['physicalTVValidation'])

    def test_rejects_absent_plugin_localization_identity_and_notices(self):
        for missing in ('Frameworks/neoplay_bridge.framework/neoplay_bridge', 'zh-Hant.lproj/InfoPlist.strings', 'NeoPlay-build-identity.json', 'NeoPlay-Pods-acknowledgements.plist'):
            with self.subTest(missing=missing), tempfile.TemporaryDirectory() as root:
                with self.assertRaises((AssertionError, KeyError)):
                    validator.validate(self.fixture(root, omit=missing), '397', SHA)

    def test_rejects_old_build_wrong_source_and_dropped_ios18(self):
        with tempfile.TemporaryDirectory() as root:
            with self.assertRaises(AssertionError):
                validator.validate(self.fixture(root, build='396'), '397', SHA)
            with self.assertRaises(AssertionError):
                validator.validate(self.fixture(root), '397', 'b' * 40)
            with self.assertRaises(AssertionError):
                validator.validate(self.fixture(root, native_minimum='26.0'), '397', SHA)

if __name__ == '__main__':
    unittest.main()
