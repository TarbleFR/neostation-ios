import importlib.util
from pathlib import Path
import plistlib
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('neoplay_config', ROOT / 'build-utils/configure_neoplay_ios.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

class NeoPlayConfigTests(unittest.TestCase):
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
