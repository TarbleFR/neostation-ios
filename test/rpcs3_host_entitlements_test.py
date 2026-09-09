"""Check actual embedded capabilities, not the presence of a sidecar plist."""
from pathlib import Path
import plistlib
import struct
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'build-utils'))
from embed_rpcs3_host_entitlements import (  # noqa: E402
    REQUIRED_RUNTIME_ENTITLEMENTS, embed, embedded_entitlements,
    require_runtime_entitlements,
)


class EmbeddedEntitlementTests(unittest.TestCase):
    def test_unsigned_binary_is_rejected_even_with_valid_sidecar(self):
        require_runtime_entitlements(REQUIRED_RUNTIME_ENTITLEMENTS)
        unsigned = struct.pack('<IiiIIIII', 0xFEEDFACF, 0x0100000C, 0, 2, 0, 0, 0, 0)
        with self.assertRaisesRegex(ValueError, 'Runner executable is missing'):
            require_runtime_entitlements(embedded_entitlements(unsigned))

    def test_false_or_missing_capability_is_rejected(self):
        for key in REQUIRED_RUNTIME_ENTITLEMENTS:
            for value in (False, 1, 'true', None):
                payload = dict(REQUIRED_RUNTIME_ENTITLEMENTS, **{key: value})
                with self.assertRaisesRegex(ValueError, key):
                    require_runtime_entitlements(payload)

    @unittest.skipUnless(sys.platform == 'darwin', 'Apple codesign required')
    def test_codesign_embeds_and_preserves_capabilities(self):
        with tempfile.TemporaryDirectory(prefix='rpcs3-sign-') as directory:
            path = Path(directory)
            (path / 'main.c').write_text('int main(void) { return 0; }\n')
            executable = path / 'Runner'
            subprocess.run(['clang', str(path / 'main.c'), '-o', str(executable)], check=True)
            payload = dict(REQUIRED_RUNTIME_ENTITLEMENTS, **{'test.existing-capability': True})
            entitlements = path / 'Runner.entitlements'
            entitlements.write_bytes(plistlib.dumps(payload))
            with self.assertRaises(ValueError):
                require_runtime_entitlements(embedded_entitlements(executable.read_bytes()))
            self.assertEqual(embed(executable, entitlements), payload)
            # Independently ask Apple's tool to verify the parser's result.
            dumped = subprocess.check_output(['codesign', '-d', '--entitlements', ':-', str(executable)])
            self.assertEqual(plistlib.loads(dumped), payload)
            data = executable.read_bytes()
            with self.assertRaises(ValueError):
                require_runtime_entitlements(embedded_entitlements(data[:len(data) // 2]))


if __name__ == '__main__':
    unittest.main()
