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


def _base_info(version: str) -> dict:
    return {
        'CFBundleExecutable': 'Runner',
        'CFBundleIdentifier': 'com.neogamelab.neostation',
        'CFBundleVersion': version,
        'CFBundleName': 'neostation',
        'CFBundleDisplayName': 'NeoStation iOS',
        'CFBundleIconName': 'AppIcon',
        'CFBundleIconFiles': list(validator.SPRINGBOARD_ICON_BASES),
        'CFBundleIcons': {
            'CFBundlePrimaryIcon': {
                'CFBundleIconName': 'AppIcon',
                'CFBundleIconFiles': ['NeoStationIcon60'],
            },
        },
        'CFBundleIcons~ipad': {
            'CFBundlePrimaryIcon': {
                'CFBundleIconName': 'AppIcon',
                'CFBundleIconFiles': list(validator.SPRINGBOARD_ICON_BASES),
            },
        },
    }


def _minimal_png(width: int, height: int) -> bytes:
    # validate_rpcs3_ipa only needs the PNG signature/IHDR dimensions. The
    # production build uses sips to create complete PNG files.
    return (
        b'\x89PNG\r\n\x1a\n'
        + (13).to_bytes(4, 'big')
        + b'IHDR'
        + width.to_bytes(4, 'big')
        + height.to_bytes(4, 'big')
    )


def _write_icon_contract(archive: zipfile.ZipFile) -> None:
    prefix = 'Payload/NeoStation.app/'
    archive.writestr(prefix + 'Assets.car', b'asset-catalog')
    sealed = {'Assets.car': {'hash2': b'x'}}
    for name, dimensions in validator.SPRINGBOARD_ICON_FILES.items():
        archive.writestr(prefix + name, _minimal_png(*dimensions))
        sealed[name] = {'hash2': b'x'}
    archive.writestr(
        prefix + '_CodeSignature/CodeResources',
        plistlib.dumps({'files2': sealed}),
    )


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
            '_neostation_rpcs3_ios_get_savestate_status',
            '_neostation_rpcs3_ios_enumerate_savestates_live',
        ):
            self.assertIn(symbol, validator.REQUIRED_CORE_SYMBOLS)


    def test_icon_fallback_generation_and_xcode_paths_share_runner_root(self):
        prepare = (BUILD_UTILS / 'prepare_ios_icon_fallback.py').read_text()
        resources = (BUILD_UTILS / 'add_ios_icon_fallback_resources.rb').read_text()
        self.assertIn('FALLBACK_DIR = RUNNER', prepare)
        self.assertNotIn('RUNNER / "IconFallback"', prepare)
        self.assertIn("find_subpath('Runner', false)", resources)
        self.assertNotIn("Runner/IconFallback", resources)


    def test_accepts_complete_springboard_icon_contract(self):
        with tempfile.TemporaryDirectory() as temp:
            app = Path(temp) / 'NeoStation.app'
            app.mkdir()
            info = _base_info('301')
            (app / 'Info.plist').write_bytes(plistlib.dumps(info))
            (app / 'Assets.car').write_bytes(b'asset-catalog')
            sealed = {'Assets.car': {'hash2': b'x'}}
            for name, dimensions in validator.SPRINGBOARD_ICON_FILES.items():
                (app / name).write_bytes(_minimal_png(*dimensions))
                sealed[name] = {'hash2': b'x'}
            signature = app / '_CodeSignature'
            signature.mkdir()
            (signature / 'CodeResources').write_bytes(
                plistlib.dumps({'files2': sealed})
            )
            report = validator.validate_springboard_icons(app, info)
            self.assertTrue(report['codeResourcesValidated'])
            self.assertEqual(report['iconName'], 'AppIcon')
            self.assertEqual(
                set(report['fallbackDimensions']),
                set(validator.SPRINGBOARD_ICON_FILES),
            )


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
            info = _base_info('243')
            with zipfile.ZipFile(ipa, 'w') as archive:
                archive.writestr('Payload/NeoStation.app/Info.plist', plistlib.dumps(info))
                archive.writestr('Payload/NeoStation.app/Runner', b'fake-macho')
                _write_icon_contract(archive)
            with self.assertRaisesRegex(validator.ValidationError, 'RPCS3 core missing'):
                validator.validate_ipa(ipa, '243', 'deadbeef')

    def test_rejects_wrong_build_number_before_native_inspection(self):
        with tempfile.TemporaryDirectory() as temp:
            ipa = Path(temp) / 'wrong-build.ipa'
            info = _base_info('242')
            with zipfile.ZipFile(ipa, 'w') as archive:
                archive.writestr('Payload/NeoStation.app/Info.plist', plistlib.dumps(info))
                archive.writestr('Payload/NeoStation.app/Runner', b'fake-macho')
                _write_icon_contract(archive)
            with self.assertRaisesRegex(validator.ValidationError, 'Wrong CFBundleVersion'):
                validator.validate_ipa(ipa, '243', 'deadbeef')


if __name__ == '__main__':
    unittest.main()
