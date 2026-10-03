"""Portable checks of CI evidence/error propagation, not Apple SDK simulation."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

from verify_apple_evidence import verify


ROOT = Path(__file__).resolve().parents[3]
SHA = 'a' * 40


class AppleEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        (self.directory / 'source.txt').write_text(SHA + '\n')
        (self.directory / 'selected-device.json').write_text(json.dumps({
            'runtime': 'com.apple.CoreSimulator.SimRuntime.iOS-18-5',
            'deviceType': 'com.apple.CoreSimulator.SimDeviceType.iPhone-16',
            'name': 'iPhone 16',
        }))
        self.report = {
            'sourceSHA': SHA, 'success': True, 'testRuntimeOnly': True,
            'realRetroArchGameplayValidated': False, 'cycles': 10,
            'starts': 12, 'stops': 12, 'endedEvents': 12,
            'firstFrameTimeoutRetainedOwnership': True,
            'lateCallbackIgnored': True, 'stopAcknowledgementRequired': True,
        }
        self.write_report()

    def write_report(self):
        (self.directory / 'host-probe.json').write_text(json.dumps(self.report))

    def test_matching_report_requires_script_completion_before_workflow_accepts(self):
        with self.assertRaises(FileNotFoundError):
            verify(self.directory, SHA, require_completion=True)
        result = verify(self.directory, SHA, write_completion=True)
        self.assertEqual(result['verifiedCheckCount'], 11)
        self.assertEqual(verify(self.directory, SHA, require_completion=True), result)

    def test_no_report_cannot_be_a_success_even_after_shell_exit_zero(self):
        (self.directory / 'host-probe.json').unlink()
        with self.assertRaises(FileNotFoundError):
            verify(self.directory, SHA)

    def test_mixed_checkout_and_short_sha_rejected(self):
        for sha in ['b' * 40, SHA[:8]]:
            with self.subTest(sha=sha), self.assertRaises(ValueError):
                verify(self.directory, sha)

    def test_incomplete_counter_or_false_invariant_rejected(self):
        for key, value in [('cycles', 9), ('starts', 11), ('stops', 11),
                           ('endedEvents', 11), ('lateCallbackIgnored', False),
                           ('success', 1), ('realRetroArchGameplayValidated', True)]:
            with self.subTest(key=key):
                original = self.report[key]
                self.report[key] = value
                self.write_report()
                with self.assertRaises(ValueError):
                    verify(self.directory, SHA)
                self.report[key] = original

    def test_changed_report_does_not_reuse_a_previous_completion(self):
        verify(self.directory, SHA, write_completion=True)
        self.report['detail'] = 'Changed report after initial verification'
        self.write_report()
        with self.assertRaises(ValueError):
            verify(self.directory, SHA, require_completion=True)

    def test_failure_marker_cannot_be_masked_by_a_valid_report(self):
        (self.directory / 'host-checks-failed.json').write_text('{"exitStatus":23}')
        with self.assertRaises(ValueError):
            verify(self.directory, SHA)

    def test_validation_remains_enabled_under_python_optimization(self):
        self.report['stopAcknowledgementRequired'] = False
        self.write_report()
        process = subprocess.run([
            os.sys.executable, '-O', str(Path(__file__).with_name('verify_apple_evidence.py')),
            str(self.directory), SHA,
        ], capture_output=True, text=True)
        self.assertNotEqual(process.returncode, 0)
        self.assertIn('stopAcknowledgementRequired', process.stderr)

    @unittest.skipUnless(shutil.which('bash'), 'Bash is unavailable')
    def test_actual_script_preserves_failed_sdk_command_status(self):
        # This deliberately fails before any compiler/device action. It tests
        # the production shell's failure path, never pretends to run UIKit.
        binaries = self.directory / 'bin'
        binaries.mkdir()
        command = binaries / 'xcrun'
        command.write_text('#!/bin/sh\nexit 23\n')
        command.chmod(0o755)
        evidence = self.directory / 'failed-sdk'
        environment = dict(os.environ, PATH=str(binaries) + os.pathsep + os.environ['PATH'])
        process = subprocess.run([
            'bash', str(Path(__file__).with_name('run_apple_checks.sh')), str(evidence),
        ], cwd=ROOT, env=environment, capture_output=True, text=True)
        self.assertEqual(process.returncode, 23, process.stderr)
        marker = json.loads((evidence / 'host-checks-failed.json').read_text())
        self.assertEqual(marker['exitStatus'], 23)
        self.assertFalse((evidence / 'host-checks-complete.json').exists())


if __name__ == '__main__':
    unittest.main()
