"""Build398 preserves NeoPlay and Build396 runtime except approved embedded menu routing."""
from pathlib import Path
import json
import re
import subprocess
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
BASE = 'd3d5681cc8b10af1cd503ea72a4886c82faaa3ef'
FEATURE = 'f4b65f09d5a71ad2e0c72ab347b3df285c98b0f7'
APPROVED_RPCS3_MENU_FILES = frozenset({
    'packages/rpcs3_internal_bridge/ios/Classes/RPCS3EmbeddedMenuInput.h',
    'packages/rpcs3_internal_bridge/ios/Classes/RPCS3GameInputController.h',
    'packages/rpcs3_internal_bridge/ios/Classes/RPCS3GameInputController.mm',
    'packages/rpcs3_internal_bridge/ios/Classes/Rpcs3InternalBridgePlugin.mm',
})
def original(path, revision=BASE):
    return subprocess.check_output(['git', 'show', revision + ':' + path], cwd=ROOT)

class Build398Integration(unittest.TestCase):
    def test_runtime_jit_storage_and_launch_preserved_except_approved_menu_routing(self):
        protected = ['native', 'packages/neo_swap', 'packages/dolphin_internal_bridge', 'packages/armsx2_internal_bridge', 'packages/rpcs3_internal_bridge', 'packages/dusklight_internal_bridge', 'packages/kartpad_internal_bridge', 'packages/stikjit_bridge', 'lib/services', 'build-utils/rpcs3', '.github/workflows/ios-ci.yml', ':(exclude)native/import-memory-candidate.json']
        changed = set(subprocess.check_output(['git', 'diff', '--name-only', BASE, '--', *protected], cwd=ROOT).decode().splitlines())
        self.assertEqual(changed - APPROVED_RPCS3_MENU_FILES, set(), 'Only the explicitly reviewed embedded RPCS3 menu input files may differ from Build396')

    def test_approved_menu_routing_preserves_core_abi_and_passes_input_behavior(self):
        for path in (
            'packages/rpcs3_internal_bridge/ios/Classes/Rpcs3CoreABI.h',
            'build-utils/rpcs3/embedded-core.patch',
        ):
            self.assertEqual((ROOT / path).read_bytes(), original(path), path)
        plugin_path = 'packages/rpcs3_internal_bridge/ios/Classes/Rpcs3InternalBridgePlugin.mm'
        plugin = (ROOT / plugin_path).read_bytes()
        callback = b'      controller.inputController.menuRequested = controller.menuHandler;\n'
        self.assertEqual(plugin.count(callback), 1)
        self.assertEqual(plugin.replace(callback, b''), original(plugin_path), 'Menu callback wiring must be the only bridge plugin change')
        subprocess.run([sys.executable, str(ROOT / 'test/rpcs3_input_bridge_test.py')], cwd=ROOT, check=True, timeout=30)
    def test_both_tools_are_present_at_distinct_gamepad_indices(self):
        text = (ROOT/'lib/screens/settings_screen/new_settings_options/tools_settings_content.dart').read_text()
        self.assertIn('TargetPlatform.iOS ? 4 : 3', text)
        self.assertRegex(text, r'if \(index == 2\)\s*\{\s*_openNeoSwap\(\);')
        self.assertRegex(text, r'if \(index == 3 && defaultTargetPlatform == TargetPlatform.iOS\)\s*\{\s*showNeoPlayDialog\(context\);')
        self.assertEqual(text.count('onTap: _openNeoSwap'), 1)
        self.assertEqual(text.count('onTap: () => showNeoPlayDialog(context)'), 1)
    def test_packages_and_version(self):
        pubspec = (ROOT/'pubspec.yaml').read_text()
        for name in ('neo_swap', 'neoplay_bridge'):
            self.assertIn('  - packages/' + name, pubspec)
            self.assertIn('  ' + name + ':\n    path: packages/' + name, pubspec)
        self.assertIn('version: 0.0.2+398', pubspec)
    def test_full_ipa_requires_previous_build_and_both_exact_evidence_suites(self):
        text = (ROOT/'.github/workflows/neoswap-ipa.yml').read_text()
        self.assertIn('neostation-neoswap-neoplay-build398', text)
        self.assertNotIn('group: neostation-neoswap-private\n', text)
        self.assertIn('run_id = 37065639799', text)
        self.assertIn("run['conclusion'] == 'success'", text)
        self.assertIn('d3d5681cc8b10af1cd503ea72a4886c82faaa3ef', text)
        self.assertIn("'neoplay-check.yml',", text)
        self.assertIn('head_sha={sha}', text)
        self.assertLess(text.index('Require completed Build 396'), text.index('Wait for exact-SHA validation workflows'))
        self.assertIn('needs: wait-evidence', text)
        self.assertIn("xcode-version: '26.3'", text)
        self.assertLess(text.index('python3 build-utils/configure_neoplay_ios.py'), text.index('pod install --project-directory=ios'))
        self.assertLess(text.index('python3 build-utils/validate_neoplay_ipa.py'), text.index('      - name: Upload direct private IPA'))
        self.assertIn('python3 build-utils/validate_neoswap_ipa.py', text)
        self.assertNotIn('gh release create', text)
    def test_native_neoplay_code_is_the_reviewed_feature_source(self):
        files = subprocess.check_output(['git','ls-tree','-r','--name-only',FEATURE,'--','packages/neoplay_bridge'],cwd=ROOT).decode().splitlines()
        self.assertTrue(files)
        for file in files:
            self.assertEqual((ROOT/file).read_bytes(), original(file, FEATURE), file)
    def test_candidate_identity_remains_honest(self):
        data = json.loads((ROOT/'native/import-memory-candidate.json').read_text())
        self.assertEqual(data['target_build'], 398)
        self.assertEqual(data['neoplay_integration']['preserved_neoswap_base'], BASE)
        self.assertEqual(data['neoplay_integration']['source'], FEATURE)
        self.assertFalse(data['neoplay_integration']['physical_device_validation'])
if __name__ == '__main__':
    unittest.main()
