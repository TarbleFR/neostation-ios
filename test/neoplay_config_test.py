import importlib.util
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('neoplay_config', ROOT / 'build-utils/configure_neoplay_ios.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

class NeoPlayConfigTests(unittest.TestCase):
    def host(self, ios, pod='17.4', framework='17.4'):
        (ios / 'Flutter').mkdir()
        (ios / 'Podfile').write_text("platform :ios, '" + pod + "'\n# preserve emulator pods\n")
        (ios / 'Flutter/AppFrameworkInfo.plist').write_bytes(plistlib.dumps(
            {'MinimumOSVersion': framework, 'UnrelatedSentinel': 'retain'}))

    def test_floor_is_taken_from_reviewed_plugin_and_is_idempotent(self):
        self.assertEqual(module.deployment_floor(), '18.0')
        with tempfile.TemporaryDirectory() as folder:
            ios = Path(folder)
            self.host(ios)
            module.configure_deployment_files(ios)
            first = [(ios / path).read_bytes() for path in ('Podfile', 'Flutter/AppFrameworkInfo.plist')]
            module.configure_deployment_files(ios)
            self.assertEqual(first, [(ios / path).read_bytes() for path in ('Podfile', 'Flutter/AppFrameworkInfo.plist')])
            self.assertIn("platform :ios, '18.0'", first[0].decode())
            self.assertIn('# preserve emulator pods', first[0].decode())
            self.assertEqual(plistlib.loads(first[1]), {'MinimumOSVersion': '18.0', 'UnrelatedSentinel': 'retain'})

    def test_never_lowers_higher_floors_and_activates_commented_platform(self):
        with tempfile.TemporaryDirectory() as folder:
            ios = Path(folder)
            self.host(ios, '26.0', '19.1')
            (ios / 'Podfile').write_text("# platform :ios, '26.0'\n# unrelated\n")
            module.configure_deployment_files(ios)
            self.assertEqual((ios / 'Podfile').read_text(), "platform :ios, '26.0'\n# unrelated\n")
            self.assertEqual(plistlib.loads((ios / 'Flutter/AppFrameworkInfo.plist').read_bytes())['MinimumOSVersion'], '19.1')

    def test_ambiguous_or_missing_generated_host_fails_closed(self):
        with tempfile.TemporaryDirectory() as folder:
            ios = Path(folder)
            self.host(ios)
            for contents in ('# no platform\n', "platform :ios, '17.4'\nplatform :ios, '18.0'\n"):
                (ios / 'Podfile').write_text(contents)
                with self.assertRaises(ValueError):
                    module.configure_deployment_files(ios)
                self.assertEqual((ios / 'Podfile').read_text(), contents)

    def test_actual_project_configurator_is_required_and_failure_is_preserved(self):
        with tempfile.TemporaryDirectory() as folder:
            ios = Path(folder)
            self.host(ios)
            failure = module.subprocess.CalledProcessError(23, 'ruby')
            with patch.object(module.subprocess, 'run', side_effect=failure) as run:
                with self.assertRaises(module.subprocess.CalledProcessError) as raised:
                    module.configure_deployment_target(ios)
                self.assertIs(raised.exception, failure)
                self.assertTrue(run.call_args.kwargs['check'])
                self.assertEqual(run.call_args.args[0][-2:], [str(ios), '18.0'])

    def test_idempotent_and_preserves_existing_permissions(self):
        with tempfile.TemporaryDirectory() as folder:
            ios = Path(folder)
            runner = ios / 'Runner'
            runner.mkdir()
            original = {'NSBonjourServices': ['_existing._tcp'], 'NSAppTransportSecurity': {'NSExceptionDomains': {'localhost': {}}}, 'NSMotionUsageDescription': 'Keep motion', 'CFBundleIdentifier': 'org.neostation'}
            info = runner / 'Info.plist'
            info.write_bytes(plistlib.dumps(original))
            french = runner / 'fr.lproj/InfoPlist.strings'
            french.parent.mkdir()
            french.write_text('"NSMotionUsageDescription" = "Conserver";\n', encoding='utf-8')
            module.configure(ios)
            first = info.read_bytes()
            first_french = french.read_text(encoding='utf-8')
            module.configure(ios)
            self.assertEqual(first, info.read_bytes())
            self.assertEqual(first_french, french.read_text(encoding='utf-8'))
            actual = plistlib.loads(first)
            self.assertEqual(actual['NSMotionUsageDescription'], 'Keep motion')
            self.assertIn('_existing._tcp', actual['NSBonjourServices'])
            self.assertTrue(actual['NSAppTransportSecurity']['NSAllowsLocalNetworking'])
            self.assertNotIn('NSAllowsArbitraryLoads', actual['NSAppTransportSecurity'])
            self.assertIn('"NSMotionUsageDescription" = "Conserver";', first_french)
            self.assertEqual(len(list(runner.glob('*.lproj/InfoPlist.strings'))), 12)
            self.assertTrue((runner / 'zh-Hant.lproj/InfoPlist.strings').exists())
            self.assertEqual(set(module.STRINGS), {'en','es','ru','zh','zh_Hant','pt','fr','de','it','id','ja','ko'})

if __name__ == '__main__':
    unittest.main()
