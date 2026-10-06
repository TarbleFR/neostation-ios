"""Host400 preserves unrelated runtime with audited menu, metrics and owned swap deltas."""
from pathlib import Path
import json
import hashlib
import re
import subprocess
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
BASE = 'd3d5681cc8b10af1cd503ea72a4886c82faaa3ef'
FEATURE = 'f4b65f09d5a71ad2e0c72ab347b3df285c98b0f7'
# The original NeoPlay transport, encoders and all other native files remain
# byte-identical. Only the audited discovery retry/error-lifecycle delta below
# replaces the feature revision's postimage; arbitrary further edits still fail.
REVIEWED_NEOPLAY_DISCOVERY_POSTIMAGES = {
    'packages/neoplay_bridge/ios/Classes/NPController.swift': '6f440858413c73b5bf98422544bd400bf26c09ac0c9180827a03b88683ad32be',
    'packages/neoplay_bridge/ios/Classes/NPDiscovery.swift': 'f874fb82b909f7344e00a6ec0f02c446613e20b0fb17b990e015bb124f1eaa19',
    'packages/neoplay_bridge/ios/Classes/NPGoogleCast.swift': '20cb1c77db74c2d6456d74025502ae766abad278b7b14e8962a29b2a91f3b846',
}
REVIEWED_RPCS3_HOST_POSTIMAGES = {
    # Build409 postimage: relay-or-donor CPU buffer admission for every title
    # on top of the authorized swap merge; menu callback and source binding below.
    'packages/rpcs3_internal_bridge/ios/Classes/Rpcs3InternalBridgePlugin.mm': '60295414f6121337484df3b2cfc819a0d100c3bcff22bd9de16b1c0a0a1ca58d',
    'packages/rpcs3_internal_bridge/ios/Classes/RPCS3PerformanceSnapshot.h': 'badde59ea1202e288e48bd8c318d61fde82b764815a83484da37db075be69c79',
}
APPROVED_RPCS3_MENU_FILES = frozenset({
    'packages/rpcs3_internal_bridge/ios/Classes/RPCS3EmbeddedMenuInput.h',
    'packages/rpcs3_internal_bridge/ios/Classes/RPCS3GameInputController.h',
    'packages/rpcs3_internal_bridge/ios/Classes/RPCS3GameInputController.mm',
    'packages/rpcs3_internal_bridge/ios/Classes/Rpcs3InternalBridgePlugin.mm',
    'packages/rpcs3_internal_bridge/ios/Classes/RPCS3PerformanceSnapshot.h',
})
APPROVED_MANAGED_SWAP_FILES = frozenset({
    # Host-only measurements requested after the Build398 packaging failure;
    # allocator, Core flags and all unrelated runtime remain locked below.
    'packages/neo_swap/ios/Classes/NeoSwapPlugin.mm',
    'packages/neo_swap/ios/Classes/NeoSwapMemorySamples.h',
    'native/neoswap/localizations.json',
    'native/neoswap-storage/SourceABI.h',
    'native/neoswap-storage/SourceClient.h',
    'native/neoswap-storage/SourceClient.cpp',
    'native/neoswap-storage/FrameClient.h',
    'native/neoswap-storage/VideoBuffer.h',
    'native/neoswap-storage/SourceArchive.h',
    'native/neoswap-storage/SourceArchive.cpp',
    'native/neoswap-storage/run_source_validation.py',
    'native/neoswap-storage/tests/source_archive_test.cpp',
    'native/neoswap-storage/tests/frame_archive_test.cpp',
    'native/neoswap-storage/tests/source_work_test.cpp',
    'native/neoswap-storage/tests/service_runtime.mm',
    'native/neoswap-storage/run_shader_validation.py',
    'packages/neo_swap/ios/Classes/SourceABI.h',
    'packages/neo_swap/ios/Classes/NeoSwapStorageService.h',
    'packages/neo_swap/ios/Classes/NeoSwapStorageService.mm',
    'packages/neo_swap/ios/Classes/NeoSwapSourceWork.h',
    'build-utils/rpcs3/canonical-source.json',
    'build-utils/rpcs3/embedded-core.patch',
    'native/neoswap-storage/ManagedSwap.h',
    'native/neoswap-storage/ManagedSwap.cpp',
    'native/neoswap-storage/ManagedSwapABI.h',
    'native/neoswap-storage/ManagedSwapABI.cpp',
    'native/neoswap-storage/run_managed_validation.py',
    'native/neoswap-storage/tests/managed_swap_test.cpp',
    'native/neoswap-storage/tests/managed_swap_abi_test.cpp',
    'native/neoswap-storage/tests/managed_swap_swift_test.swift',
    'native/neoswap-storage/tests/store_test.cpp',
    'native/neoswap-storage/tests/benchmark.cpp',
    'packages/neo_swap/ios/Classes/ManagedSwapABI.h',
    'packages/neo_swap/ios/neo_swap.podspec',
})
# Maintainer-authorized integrations after Build401: the swap research branch
# (merge e856bb2) and ARMSX2 2.6 (merge bae194b, pinned byte-for-byte to its
# reviewed revision below and by the candidate scope test), then the Build409
# global budget controller with relay host loans for identified RPCS3 consumers.
APPROVED_SWAP_INTEGRATION_FILES = frozenset({
    'native/neoswap-relay/Backend.h',
    'packages/neo_swap/ios/Classes/NeoSwap.cpp',
    'packages/neo_swap/ios/Classes/NeoSwapCapacityProbe.h',
    'packages/neo_swap/ios/Classes/NeoSwapExperiment.h',
    'packages/neo_swap/ios/Classes/NeoSwapRelayService.mm',
})
ARMSX2_INTEGRATION_SHA = '424a360348ae1178feed330da1af8c45909ed675'
APPROVED_ARMSX2_INTEGRATION_FILES = frozenset({
    '.github/workflows/ios-ci.yml',
    'packages/armsx2_internal_bridge/core/ARMSX2Core.mm',
    'packages/armsx2_internal_bridge/core/ARMSX2GraphicsAssets.inc',
    'packages/armsx2_internal_bridge/core/ARMSX2ShaderLibrary.h',
    'packages/armsx2_internal_bridge/core/target.cmake',
    'packages/armsx2_internal_bridge/ios/Classes/ARMSX2CoreABI.h',
    'packages/armsx2_internal_bridge/ios/Classes/ARMSX2InGameLocalization.mm',
    'packages/armsx2_internal_bridge/ios/Classes/Armsx2InternalBridgePlugin.mm',
    'packages/armsx2_internal_bridge/ios/Classes/Armsx2SessionMenu.mm',
})
APPROVED_BUILD409_FILES = frozenset({
    'native/neoswap-relay/Backend.cpp',
    'native/neoswap/NeoSwapClient.h',
    'packages/neo_swap/ios/Classes/NeoSwapBudget.h',
    'packages/neo_swap/ios/Classes/NeoSwapHost.h',
    'packages/neo_swap/ios/Classes/NeoSwapRelayService.h',
    'packages/rpcs3_internal_bridge/ios/Classes/NeoSwapUsagePolicy.h',
    'packages/rpcs3_internal_bridge/ios/Classes/RPCS3InGameLocalization.mm',
    'packages/rpcs3_internal_bridge/ios/Classes/RPCS3PerformanceOverlay.mm',
})
def original(path, revision=BASE):
    return subprocess.check_output(['git', 'show', revision + ':' + path], cwd=ROOT)

class Build398Integration(unittest.TestCase):
    def test_unrelated_runtime_preserved_except_approved_menu_and_managed_swap(self):
        protected = ['native', 'packages/neo_swap', 'packages/dolphin_internal_bridge', 'packages/armsx2_internal_bridge', 'packages/rpcs3_internal_bridge', 'packages/dusklight_internal_bridge', 'packages/kartpad_internal_bridge', 'packages/stikjit_bridge', 'lib/services', 'build-utils/rpcs3', '.github/workflows/ios-ci.yml', ':(exclude)native/import-memory-candidate.json']
        changed = set(subprocess.check_output(['git', 'diff', '--name-only', BASE, '--', *protected], cwd=ROOT).decode().splitlines())
        self.assertEqual(changed - APPROVED_RPCS3_MENU_FILES - APPROVED_MANAGED_SWAP_FILES
                         - APPROVED_SWAP_INTEGRATION_FILES - APPROVED_ARMSX2_INTEGRATION_FILES - APPROVED_BUILD409_FILES, set(),
                         'Only the explicitly reviewed menu, owned CPU swap module, authorized swap/ARMSX2 integrations and Build409 budget files may differ from Build396')
        for path in sorted(APPROVED_ARMSX2_INTEGRATION_FILES):
            self.assertEqual((ROOT / path).read_bytes(), original(path, ARMSX2_INTEGRATION_SHA), path)
        for path in ('native/neoswap-storage/Store.h', 'native/neoswap-storage/Store.cpp',
                     'native/neoswap-storage/StorageABI.h', 'native/neoswap-storage/Client.h',
                     'native/neoswap-storage/ShaderCache.h', 'native/neoswap-storage/ShaderCache.cpp'):
            self.assertEqual((ROOT / path).read_bytes(), original(path), path)

    def test_approved_menu_routing_preserves_core_abi_and_passes_input_behavior(self):
        for path in (
            'packages/rpcs3_internal_bridge/ios/Classes/Rpcs3CoreABI.h',
        ):
            self.assertEqual((ROOT / path).read_bytes(), original(path), path)
        plugin_path = 'packages/rpcs3_internal_bridge/ios/Classes/Rpcs3InternalBridgePlugin.mm'
        plugin = (ROOT / plugin_path).read_bytes()
        callback = b'      controller.inputController.menuRequested = controller.menuHandler;\n'
        self.assertEqual(plugin.count(callback), 1)
        source_binding=(
            b'  using SourceBinder = int32_t (*)(const NeoSwapSourceAPI*);\n'
            b'  auto bindSource = reinterpret_cast<SourceBinder>(dlsym(handle, "rpcs3_ios_set_source_archive_api"));\n'
            b'  const int sourceResult = bindSource ? bindSource(NeoSwapStorage_GetSourceAPI(NEOSWAP_SOURCE_ABI)) : NS_SOURCE_DISABLED;\n'
            b'  NeoSwapStorage_SetSourceBinderResult(sourceResult);\n'
            b'  RPCS3Diagnostic(@"neoswap_glsl_archive", [NSString stringWithFormat:\n'
            b'      @"abi=1 bind=%d scope=owned_GLSL_after_module_create admission=no_disk_wait restore=debug_utility_copy",\n'
            b'      sourceResult]);\n')
        self.assertEqual(plugin.count(source_binding),1)
        # The full reviewed host postimage binds the single metrics producer,
        # restart/teardown/UI ownership fences and bounded VDEC notice filter.
        # The callback/source binding and Core/input behavior remain mandatory.
        for path, expected in REVIEWED_RPCS3_HOST_POSTIMAGES.items():
            self.assertEqual(hashlib.sha256((ROOT/path).read_bytes()).hexdigest(), expected, path)
        self.assertIn(b'const BOOL videoArchive = strstr(message, "NEOSWAP_VDEC ") != nullptr;', plugin)
        self.assertIn(b'if (level > 2 && !profiler && !videoArchive) return;', plugin)
        subprocess.run([sys.executable, str(ROOT / 'test/rpcs3_input_bridge_test.py')], cwd=ROOT, check=True, timeout=30)
        subprocess.run([sys.executable, str(ROOT / 'test/rpcs3_performance_snapshot_test.py')], cwd=ROOT, check=True, timeout=30)
    def test_screen_sharing_moves_to_the_main_menu_and_preserves_other_tools(self):
        text = (ROOT/'lib/screens/settings_screen/new_settings_options/tools_settings_content.dart').read_text()
        self.assertIn('int getItemCount() => 3;', text)
        self.assertRegex(text, r'if \(index == 2\)\s*\{\s*_openNeoSwap\(\);')
        self.assertEqual(text.count('onTap: _openNeoSwap'), 1)
        self.assertNotIn('showNeoPlayDialog', text)
        self.assertNotIn('NeoPlayLocale', text)
        self.assertNotIn('index == 3', text)
        header = (ROOT/'lib/widgets/header.dart').read_text()
        self.assertIn("import 'package:neostation/widgets/airplay_menu_button.dart';", header)
        self.assertRegex(header, r'if \(defaultTargetPlatform == TargetPlatform.iOS\) \.\.\.\[\s*SizedBox\(width: 4.r\),\s*const AirPlayMenuButton\(\),')
        self.assertEqual(header.count('const AirPlayMenuButton()'), 1)
        action = (ROOT/'lib/widgets/airplay_menu_button.dart').read_text()
        self.assertIn('Icons.airplay_rounded', action)
        self.assertEqual(action.count('onPressed: () => showNeoPlayDialog(context)'), 1)
        self.assertNotIn('NeoPlayBridge.', action)
    def test_packages_and_version(self):
        pubspec = (ROOT/'pubspec.yaml').read_text()
        for name in ('neo_swap', 'neoplay_bridge'):
            self.assertIn('  - packages/' + name, pubspec)
            self.assertIn('  ' + name + ':\n    path: packages/' + name, pubspec)
        self.assertIn('version: 0.0.2+399', pubspec)
    def test_full_ipa_requires_previous_build_and_both_exact_evidence_suites(self):
        text = (ROOT/'.github/workflows/neoswap-ipa.yml').read_text()
        self.assertIn('neostation-neoswap-neoplay-build409', text)
        self.assertNotIn('group: neostation-neoswap-private\n', text)
        self.assertIn('run_id = 37135708903', text)
        self.assertIn("run['conclusion'] == 'success'", text)
        self.assertIn('905461854998c65e1b884cabfedd7b46060c701b', text)
        self.assertIn("expected = 'NeoStation-NeoSwap-NeoPlay-Build-401-' + expected_sha", text)
        self.assertIn("'neoplay-check.yml',", text)
        self.assertIn('head_sha={sha}', text)
        self.assertLess(text.index('Require completed Build 401'), text.index('Wait for exact-SHA validation workflows'))
        self.assertIn('needs: wait-evidence', text)
        self.assertIn("xcode-version: '26.3'", text)
        self.assertLess(text.index('python3 build-utils/configure_neoplay_ios.py'), text.index('pod install --project-directory=ios'))
        self.assertLess(text.index('python3 build-utils/configure_neoplay_ios.py --deployment-only'), text.index('flutter build ios'))
        host = text.split('      - name: Configure release host', 1)[1]
        self.assertLess(host.index('python3 build-utils/configure_armsx2_ios.py'), host.index('python3 build-utils/configure_neoplay_ios.py\n'))
        self.assertLess(text.index('python3 build-utils/validate_neoplay_ipa.py'), text.index('      - name: Upload direct private IPA'))
        self.assertIn('python3 build-utils/validate_neoswap_ipa.py', text)
        self.assertNotIn('gh release create', text)
    def test_native_neoplay_code_is_the_reviewed_feature_source(self):
        files = subprocess.check_output(['git','ls-tree','-r','--name-only',FEATURE,'--','packages/neoplay_bridge'],cwd=ROOT).decode().splitlines()
        self.assertTrue(files)
        actual_files = {str(path.relative_to(ROOT)) for path in (ROOT / 'packages/neoplay_bridge').rglob('*')
                        if path.is_file() and not any(part.startswith('.') for part in path.relative_to(ROOT).parts)}
        self.assertEqual(actual_files, set(files), 'No unreviewed native bridge files may be added or removed')
        self.assertTrue(set(REVIEWED_NEOPLAY_DISCOVERY_POSTIMAGES).issubset(files))
        for file in files:
            actual = (ROOT/file).read_bytes()
            if file in REVIEWED_NEOPLAY_DISCOVERY_POSTIMAGES:
                self.assertEqual(hashlib.sha256(actual).hexdigest(), REVIEWED_NEOPLAY_DISCOVERY_POSTIMAGES[file], file)
                continue
            if file == 'packages/neoplay_bridge/ios/neoplay_bridge.podspec':
                # Only this linkage declaration resolves the demonstrated
                # static Cast / dynamic wrapper dependency conflict.
                addition = b'  s.static_framework = true\n'
                self.assertEqual(actual.count(addition), 1)
                actual = actual.replace(addition, b'')
            self.assertEqual(actual, original(file, FEATURE), file)
        workflow = (ROOT / '.github/workflows/neoplay-check.yml').read_text()
        self.assertIn('python3 test/neoplay_pod_graph_test.py', workflow)
        self.assertIn('build/neoplay-native/pod-graph.json', workflow)
    def test_discovery_restart_does_not_disconnect_or_start_a_cast_session(self):
        text = (ROOT / 'packages/neoplay_bridge/ios/Classes/NPGoogleCast.swift').read_text()
        discovery = text.split('    func startDiscovery() {', 1)[1].split('    func didUpdateDeviceList()', 1)[0]
        self.assertLess(discovery.index('context.discoveryManager.stopDiscovery()'),
                        discovery.index('context.discoveryManager.startDiscovery()'))
        for forbidden in ('endSession', 'startSession', 'currentCastSession', 'onReady =', 'ownsSession ='):
            self.assertNotIn(forbidden, discovery)
        controller = (ROOT / 'packages/neoplay_bridge/ios/Classes/NPController.swift').read_text()
        request = controller.split('    func discover() {', 1)[1].split('}', 1)[0]
        self.assertNotIn('stop(', request)
        self.assertIn('failure = nil', request)
    def test_candidate_identity_remains_honest(self):
        data = json.loads((ROOT/'native/import-memory-candidate.json').read_text())
        self.assertEqual(data['target_build'], 409)
        self.assertEqual(data['neoplay_integration']['preserved_neoswap_base'], BASE)
        self.assertEqual(data['neoplay_integration']['source'], FEATURE)
        self.assertFalse(data['neoplay_integration']['physical_device_validation'])
if __name__ == '__main__':
    unittest.main()
