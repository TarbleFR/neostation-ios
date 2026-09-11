#!/usr/bin/env python3
"""Regression checks for NeoStation's pinned StikJIT 1.5.0 RPCS3 patch."""
from pathlib import Path
import re
import sys
import unittest

SOURCE = Path(sys.argv.pop(1)).resolve() if len(sys.argv) > 1 else None


class StikJitRpcs3PatchTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if SOURCE is None:
            raise unittest.SkipTest('pass the patched StikJIT source directory')
        cls.swift = (SOURCE / 'Sources/ScriptRunner.swift').read_text()
        cls.js = (SOURCE / 'Resources/universal.js').read_text()

    def test_full_width_page_packet_preserves_rpcs3_address(self):
        digits_match = re.search(r'jitAddressHexDigits = (\d+)', self.swift)
        length_match = re.search(r'jitPageCommandLength = (\d+)', self.swift)
        self.assertIsNotNone(digits_match)
        self.assertIsNotNone(length_match)
        digits = int(digits_match.group(1))
        command_length = int(length_match.group(1))
        self.assertEqual(digits, 16)
        self.assertEqual(command_length, 26)

        address = 0x7000000000
        encoded = f'{address:0{digits}x}'
        body = f'M{encoded},1:69'
        checksum = sum(body.encode('ascii')) & 0xff
        packet = f'${body}#{checksum:02x}'
        self.assertEqual(len(packet), command_length)
        self.assertTrue(packet.startswith('$M0000007000000000,1:69#'))
        self.assertNotEqual(encoded, f'{address & 0xfffffffff:09x}')

    def test_batch_replies_are_drained_before_failure_is_reported(self):
        loop = self.swift.index('for responseIndex in 0..<commandsInBatch')
        refusal = self.swift.index('if reply != "OK"', loop)
        report = self.swift.index('if let firstBatchFailure {', refusal)
        next_batch = self.swift.index('progress("Blessed', report)
        self.assertLess(loop, refusal)
        self.assertLess(refusal, report)
        self.assertLess(report, next_batch)
        self.assertIn('debugserver rejected JIT page 0x', self.swift)
        self.assertIn('NEOSTATION_STIKJIT_RPCS3_V1', self.swift)

    def test_universal_script_propagates_page_preparation_failure(self):
        self.assertIn('NEOSTATION_STIKJIT_UNIVERSAL_V1', self.js)
        self.assertIn('prepareJITPageResponse !== "OK"', self.js)
        self.assertIn('numberToLittleEndianHexString(0n)', self.js)
        self.assertIn('for (let i = 7; i >= 0; i--)', self.js)
        self.assertIn('for (let i = 0; i < 8; i++)', self.js)

    def test_firmware_detection_and_cache_paths_are_not_part_of_patch(self):
        # The transport patch is deliberately confined to ScriptRunner and the
        # Universal script. This test documents the scope the build relies on.
        self.assertNotIn('DeveloperDiskImageService', self.swift)
        self.assertNotIn('SynchronousDDIDownloader', self.swift)
        self.assertNotIn('EndpointProbe', self.swift)


if __name__ == '__main__':
    unittest.main()
