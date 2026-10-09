"""Run the real notice packager before compilation and against a built bundle."""
from pathlib import Path
import json
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
DOLPHIN = "7cac54161659421ed95c2cd1c0b0746539a4cd38"


class LegalBundlePreflightTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        shutil.copytree(ROOT / "assets/legal", self.root / "assets/legal")
        for name in (
            "build-utils/embed_legal_bundle.py",
            "build-utils/rpcs3/canonical-source.json",
            "build-utils/armsx2/source.json",
            "build-utils/dusklight/source.json",
            "build-utils/kartpad/source.json",
            "build-utils/libretro/cores.json",
            "LICENSE.md", "NOTICE.md", "docs/LEGAL_AND_CREDITS.md",
        ):
            target = self.root / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / name, target)

    def run_packager(self, *args):
        return subprocess.run(
            [sys.executable, str(self.root / "build-utils/embed_legal_bundle.py"),
             "--dolphin-sha", DOLPHIN, *args],
            capture_output=True, text=True, timeout=15,
        )

    def test_preflight_needs_no_app_and_writes_nothing(self):
        before = {str(p.relative_to(self.root)): p.read_bytes()
                  for p in self.root.rglob("*") if p.is_file()}
        result = self.run_packager("--validate-only")
        self.assertEqual(result.returncode, 0, result.stderr)
        after = {str(p.relative_to(self.root)): p.read_bytes()
                 for p in self.root.rglob("*") if p.is_file()}
        self.assertEqual(after, before)

    def test_old_dusklight_notice_is_rejected_before_compilation(self):
        notice = self.root / "assets/legal/Dusklight-CC0-1.0.txt"
        pins = json.loads((self.root / "build-utils/dusklight/source.json").read_text())
        current = "Pinned revision/tag: " + pins["commit"]
        self.assertIn(current, notice.read_text())
        notice.write_text(notice.read_text().replace(
            current, "Pinned revision/tag: ad979d3dae092d0f5cbdaf49eabca7b4f1db4838"))
        result = self.run_packager("--validate-only")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Dusklight-CC0-1.0.txt is stale", result.stderr)
        self.assertIn(pins["commit"], result.stderr)
        self.assertFalse((self.root / "Legal").exists())

    def test_embedding_preserves_notice_and_records_current_sources(self):
        app = self.root / "Runner.app"
        app.mkdir()
        result = self.run_packager("--app", str(app), "--build-number", "369")
        self.assertEqual(result.returncode, 0, result.stderr)
        identity = json.loads((app / "Legal/BUILD_SOURCE_IDENTITY.json").read_text())
        pins = json.loads((self.root / "build-utils/dusklight/source.json").read_text())
        self.assertEqual(identity["build_number"], "369")
        self.assertEqual(identity["dusklight"]["revision"], pins["commit"])
        self.assertEqual(identity["dusklight"]["submodules"], pins["submodules"])
        self.assertEqual((app / "Legal/Dusklight-CC0-1.0.txt").read_bytes(),
                         (self.root / "assets/legal/Dusklight-CC0-1.0.txt").read_bytes())
        self.assertEqual((app / "Legal/Libretro/fbneo-src-license.txt").read_bytes(),
                         (self.root / "assets/legal/libretro/fbneo-src-license.txt").read_bytes())

    def test_missing_core_license_blocks_packaging(self):
        (self.root / "assets/legal/libretro/mgba-LICENSE").unlink()
        result = self.run_packager("--validate-only")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("mgba-LICENSE", result.stderr)


if __name__ == "__main__":
    unittest.main()
