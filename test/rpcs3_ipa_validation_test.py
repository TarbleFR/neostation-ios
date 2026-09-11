from __future__ import annotations

import importlib.util
import plistlib
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BUILD_UTILS = ROOT / 'build-utils'
sys.path.insert(0, str(BUILD_UTILS))

spec = importlib.util.spec_from_file_location(
    'validate_rpcs3_ipa', BUILD_UTILS / 'validate_rpcs3_ipa.py'
)
validator = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(validator)


class RPCS3IPAValidationTests(unittest.TestCase):
    def test_required_runtime_contract_includes_input_and_ingame_exports(self):
        self.assertEqual(validator.CORE_NAME, 'libRPCS3Core.dylib')
        for symbol in (
            '_rpcs3_ios_set_pad_state',
            '_rpcs3_ios_boot_game',
            '_rpcs3_ios_run_llvm_self_test',
            '_rpcs3_ios_set_game_setting',
            '_rpcs3_ios_get_performance_metrics',
            '_neostation_rpcs3_ios_save_state',
            '_neostation_rpcs3_ios_enumerate_savestates_live',
        ):
            self.assertIn(symbol, validator.REQUIRED_CORE_SYMBOLS)

    def test_rejects_path_traversal(self):
        with tempfile.TemporaryDirectory() as temp:
            ipa = Path(temp) / 'bad.ipa'
            with zipfile.ZipFile(ipa, 'w') as archive:
                archive.writestr('../escape', b'x')
            with zipfile.ZipFile(ipa) as archive:
                with self.assertRaises(validator.ValidationError):
                    validator.safe_members(archive)

    def test_rejects_packaged_app_without_rpcS3_core_before_native_inspection(self):
        with tempfile.TemporaryDirectory() as temp:
            ipa = Path(temp) / 'missing-core.ipa'
            info = {
                'CFBundleExecutable': 'NeoStation',
                'CFBundleIdentifier': 'com.neogamelab.neostation',
                'CFBundleVersion': '243',
            }
            with zipfile.ZipFile(ipa, 'w') as archive:
                archive.writestr('Payload/NeoStation.app/Info.plist', plistlib.dumps(info))
                archive.writestr('Payload/NeoStation.app/NeoStation', b'fake-macho')
            with self.assertRaisesRegex(validator.ValidationError, 'RPCS3 core missing'):
                validator.validate_ipa(ipa, '243', 'deadbeef')

    def test_rejects_wrong_build_number_before_native_inspection(self):
        with tempfile.TemporaryDirectory() as temp:
            ipa = Path(temp) / 'wrong-build.ipa'
            info = {
                'CFBundleExecutable': 'NeoStation',
                'CFBundleIdentifier': 'com.neogamelab.neostation',
                'CFBundleVersion': '242',
            }
            with zipfile.ZipFile(ipa, 'w') as archive:
                archive.writestr('Payload/NeoStation.app/Info.plist', plistlib.dumps(info))
                archive.writestr('Payload/NeoStation.app/NeoStation', b'fake-macho')
            with self.assertRaisesRegex(validator.ValidationError, 'Wrong CFBundleVersion'):
                validator.validate_ipa(ipa, '243', 'deadbeef')


if __name__ == '__main__':
    unittest.main()
