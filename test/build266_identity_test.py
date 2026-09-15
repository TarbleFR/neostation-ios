#!/usr/bin/env python3
"""Negative and positive package-identity tests using synthetic, non-IPA fixtures."""
from pathlib import Path
import importlib.util
import plistlib
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('identity266', ROOT / 'build-utils/validate_build266_identity.py')
validator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(validator)


class IdentityTests(unittest.TestCase):
    def fixture(self, core=True, provider=True, manager=True):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        path = Path(temp.name) / 'synthetic.zip'
        with zipfile.ZipFile(path, 'w') as archive:
            app = 'Payload/NeoStation.app/'
            archive.writestr(app + 'Info.plist', plistlib.dumps({'CFBundleVersion': '266', 'CFBundleExecutable': 'Runner'}))
            archive.writestr(app + 'Runner', b'\0'.join(validator.MANAGER_MARKERS) if manager else b'old')
            archive.writestr(app + 'Frameworks/libRPCS3Core.dylib', b'\0'.join(validator.CORE_MARKERS) if core else b'old')
            tunnel = app + 'PlugIns/NeoStationLocalTunnel.appex/'
            archive.writestr(tunnel + 'Info.plist', plistlib.dumps({'CFBundleExecutable': 'NeoStationLocalTunnel'}))
            archive.writestr(tunnel + 'NeoStationLocalTunnel', validator.PROVIDER_MARKER if provider else b'old')
        return path

    def test_current_identity(self):
        self.assertFalse(validator.validate(self.fixture())['deviceTested'])

    def test_old_core_rejected(self):
        with self.assertRaisesRegex(ValueError, 'Final core'):
            validator.validate(self.fixture(core=False))

    def test_old_extension_rejected(self):
        with self.assertRaisesRegex(ValueError, 'Final extension'):
            validator.validate(self.fixture(provider=False))

    def test_old_host_rejected(self):
        with self.assertRaisesRegex(ValueError, 'Final host'):
            validator.validate(self.fixture(manager=False))


if __name__ == '__main__':
    unittest.main()
