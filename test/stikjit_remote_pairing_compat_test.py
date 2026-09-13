#!/usr/bin/env python3
"""Regression checks for current iOS Remote Pairing compatibility."""
from pathlib import Path
import plistlib
import sys
import unittest


ROOT = Path(__file__).resolve().parents[1]
SOURCE = Path(sys.argv.pop(1)).resolve() if len(sys.argv) > 1 else None
IDEVICE_SHA = "6fb49aeb33e8e27f2e52267729b631e53c87e1d9"


class StikJitRemotePairingCompatibilityTests(unittest.TestCase):
    def test_workflow_pins_post_release_opack_decoder(self):
        workflow = (ROOT / ".github/workflows/build-ipa-once.yml").read_text()
        self.assertIn(f"IDEVICE_SHA: {IDEVICE_SHA}", workflow)
        self.assertIn("cargo build --locked --release --target aarch64-apple-ios", workflow)
        self.assertIn('STIK_SRC/idevice/libidevice_ffi.a', workflow)
        self.assertIn("grep -q 'OPACK back-reference'", workflow)

    def test_every_jit_process_can_browse_remote_pairing(self):
        for relative in (
            "native/rpcs3_internal_helper/Info.plist",
            "native/dolphin_internal_helper/Info.plist",
        ):
            info = plistlib.loads((ROOT / relative).read_bytes())
            self.assertIn("_remotepairing._tcp", info["NSBonjourServices"])
            self.assertTrue(info["NSLocalNetworkUsageDescription"])

        scaffold = (
            ROOT / "packages/dolphin_internal_bridge/ci/build_support.py"
        ).read_text()
        self.assertIn("info['NSBonjourServices'] = ['_remotepairing._tcp']", scaffold)
        self.assertIn("info['NSLocalNetworkUsageDescription']", scaffold)

    def test_patched_stikjit_discovers_port_with_safe_fallback(self):
        if SOURCE is None:
            self.skipTest("pass the patched StikJIT source directory")
        swift = (SOURCE / "Sources/StikJIT.swift").read_text()
        self.assertIn("NEOSTATION_REMOTE_PAIRING_DISCOVERY_V1", swift)
        self.assertIn('serviceType = "_remotepairing._tcp"', swift)
        self.assertIn("parameters.includePeerToPeer = true", swift)
        self.assertIn("NeoStationRemotePairingPortResolver.resolve() ?? 49152", swift)
        self.assertIn("path.remoteEndpoint", swift)


if __name__ == "__main__":
    unittest.main()
