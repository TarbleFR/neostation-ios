"""Protect the requested library rollback and unchanged native engines."""
import hashlib
import json
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
MANIFEST = json.loads((ROOT / 'docs/retroarch-baseline-manifest.json').read_text())


class RetroArchBaselineScope(unittest.TestCase):
    def test_library_is_the_recorded_build419_reference(self):
        for name, expected in MANIFEST['library_sha256'].items():
            with self.subTest(path=name):
                data = (ROOT / name).read_bytes()
                if name == 'lib/services/ios_rom_library_root_resolver.dart':
                    # Reviewed linkage-only exception: Files returns a literal
                    # filesystem path, including spaces. Reconstruct exactly the
                    # single Build419 expression; all other bytes stay locked.
                    literal = b'final rootPath = path.normalize(linkedRoot);'
                    self.assertEqual(data.count(literal), 1)
                    data = data.replace(literal, b'final rootPath = path.normalize(linkedRoot.trim());', 1)
                if name == 'lib/providers/sqlite_config_provider/scanning.dart':
                    # Build423: the user's seven saved roots exposed the silent
                    # five-folder cap. Only registration changes; scan logic is
                    # still byte-identical to 419/422. Reconstruct those exact
                    # reviewed edits before checking the historical fingerprint.
                    edits = [
                        (b'    if (_config.romFolders.contains(folderPath)) return;\n',
                         b'    if (_config.romFolders.contains(folderPath)) return;\n    if (_config.romFolders.length >= 5) return;\n'),
                        (b'      final updatedConfig = _config.copyWith(\n', b'      _config = _config.copyWith(\n'),
                        (b'      await SqliteConfigService.saveConfig(updatedConfig);\n      _config = updatedConfig;\n',
                         b'      await SqliteConfigService.saveConfig(_config);\n'),
                    ]
                    for current, original in edits:
                        self.assertEqual(data.count(current), 1)
                        data = data.replace(current, original, 1)
                self.assertEqual(hashlib.sha256(data).hexdigest(), expected)

    def test_native_sources_keep_their_existing_identity(self):
        for name, expected in MANIFEST['native_sha256'].items():
            with self.subTest(path=name):
                self.assertEqual(hashlib.sha256((ROOT / name).read_bytes()).hexdigest(), expected)

    def test_retired_repairs_are_outside_executable_app_sources(self):
        for name in ('embedded_library_recovery.dart', 'retroarch_folder_recovery.dart', 'retroarch_library_importer.dart'):
            self.assertFalse((ROOT / 'lib/services' / name).exists())


if __name__ == '__main__':
    unittest.main(verbosity=2)
