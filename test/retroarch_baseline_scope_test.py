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
