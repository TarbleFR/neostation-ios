from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
PODSPEC = ROOT / "packages/rpcs3_internal_bridge/ios/rpcs3_internal_bridge.podspec"

class Rpcs3PodHeaderVisibilityTests(unittest.TestCase):
    def test_cpp_runtime_headers_are_not_public(self):
        text = PODSPEC.read_text()
        match = re.search(
            r"s\.public_header_files\s*=\s*\[(.*?)\]",
            text,
            re.S,
        )
        self.assertIsNotNone(match, "podspec must explicitly define public headers")
        public = set(re.findall(r"'Classes/([^']+\.h)'", match.group(1)))
        expected = {
            "Rpcs3CompositeBridgePlugin.h",
            "Rpcs3InternalBridgePlugin.h",
            "Rpcs3JitBridgePlugin.h",
            "Rpcs3DocumentPickerPlugin.h",
            "Rpcs3RuntimeTuningPlugin.h",
        }
        self.assertEqual(public, expected)
        forbidden = {
            "Rpcs3ArenaLayout.h",
            "Rpcs3ArenaReservation.h",
            "Rpcs3CoreABI.h",
            "Rpcs3EarlyLoaderDiagnostics.h",
        }
        self.assertTrue(public.isdisjoint(forbidden))

    def test_arena_header_remains_cpp_only_implementation_detail(self):
        arena = (
            ROOT
            / "packages/rpcs3_internal_bridge/ios/Classes/Rpcs3ArenaLayout.h"
        ).read_text()
        self.assertIn("#include <algorithm>", arena)
        self.assertIn("namespace neostation::rpcs3::arena", arena)

if __name__ == "__main__":
    unittest.main()
