"""Catch iOS recorder API/ObjC++ errors before a full Flutter/core build."""
from pathlib import Path
import os
import subprocess
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
XCODE = Path('/Applications/Xcode_16.4.app/Contents/Developer')


@unittest.skipUnless(sys.platform == 'darwin' and XCODE.is_dir(),
                     'Pinned Xcode 16.4 iOS SDK required')
class RecordingSDKTests(unittest.TestCase):
    def test_production_recorder_compiles_with_strict_cpp20_and_ios_sdk(self):
        environment = dict(os.environ, DEVELOPER_DIR=str(XCODE))
        sdk = subprocess.check_output(['xcrun', '--sdk', 'iphonesimulator',
                                       '--show-sdk-path'], env=environment,
                                      text=True, timeout=30).strip()
        classes = ROOT / 'packages/dolphin_internal_bridge/ios/Classes'
        result = subprocess.run([
            'xcrun', '--sdk', 'iphonesimulator', 'clang++', '-std=c++20',
            '-target', 'arm64-apple-ios17.4-simulator', '-isysroot', sdk,
            '-fobjc-arc', '-fblocks', '-fsyntax-only', '-I', str(classes),
            str(classes / 'DolphinRecordingController.mm'),
            str(classes / 'DolphinSessionMenu.mm')], env=environment,
            capture_output=True, text=True, timeout=90)
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == '__main__':
    unittest.main()
