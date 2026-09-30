"""Exercise the canonical donor target and its requested executable capabilities."""
from pathlib import Path
import json
import os
import plistlib
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
BASE = '3ccde925351b3e59985ba466e013e87a857d6ad0'
sys.path.insert(0, str(ROOT / 'build-utils'))
import configure_neoswap_donor as donor
from embed_rpcs3_host_entitlements import embed, embedded_entitlements, require_entitlements

PUBLIC_CAPABILITIES = {
    'get-task-allow': True,
    'com.apple.developer.kernel.increased-memory-limit': True,
    'com.apple.developer.kernel.increased-debugging-memory-limit': True,
}
JIT_PLISTS = (
    'native/dolphin_internal_helper/Info.plist',
    'native/rpcs3_internal_helper/Info.plist',
    'native/armsx2_internal_helper/Info.plist',
)
JIT_TARGETS = ('DolphinJITHelper', 'RPCS3JITHelper', 'ARMSX2JITHelper')

CREATE_PROJECT = r'''
require 'xcodeproj'
require 'json'
root = ARGV.fetch(0)
project = Xcodeproj::Project.new(File.join(root, 'ios/Runner.xcodeproj'))
runner = project.new_target(:application, 'Runner', :ios, '17.4')
runner.build_configurations.each do |configuration|
  configuration.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'com.test.neostation'
  configuration.build_settings['CODE_SIGN_ENTITLEMENTS'] = 'Runner/Original.entitlements'
end
File.write(File.join(root, 'ios/UnrelatedRuntime.mm'), 'void original_runtime(void) {}')
runner.source_build_phase.add_file_reference(project.main_group.new_file('UnrelatedRuntime.mm'))
embed = runner.new_copy_files_build_phase('Embed App Extensions')
embed.dst_subfolder_spec = '13'
['DolphinJITHelper', 'RPCS3JITHelper', 'ARMSX2JITHelper'].each do |name|
  helper = project.new_target(:app_extension, name, :ios, '17.4')
  helper.build_configurations.each do |configuration|
    configuration.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'com.test.neostation.' + name.downcase
    configuration.build_settings['CODE_SIGN_ENTITLEMENTS'] = 'JIT/' + name + '.entitlements'
    configuration.build_settings['ORIGINAL_HELPER_SENTINEL'] = name
  end
  File.write(File.join(root, 'ios', name + '.mm'), 'void original_helper(void) {}')
  helper.source_build_phase.add_file_reference(project.main_group.new_file(name + '.mm'))
  runner.add_dependency(helper)
  embed.add_file_reference(helper.product_reference)
end
project.save
'''

AUDIT_PROJECT = r'''
require 'xcodeproj'
require 'json'
project = Xcodeproj::Project.open(ARGV.fetch(0))
def snapshot(target)
  [target.to_hash, target.build_phases.map { |phase| [phase.to_hash, phase.files.map(&:to_hash)] },
   target.build_configurations.map(&:to_hash), target.dependencies.map(&:to_hash)]
end
helpers = ['DolphinJITHelper', 'RPCS3JITHelper', 'ARMSX2JITHelper']
runner = project.targets.find { |target| target.name == 'Runner' }
donor = project.targets.find { |target| target.name == 'NeoSwapDonor' }
result = {
  'protected' => helpers.to_h { |name| [name, snapshot(project.targets.find { |target| target.name == name })] },
  'runnerSources' => runner.source_build_phase.files.map { |file| file.file_ref.path },
  'embedded' => runner.copy_files_build_phases.select { |phase| phase.name == 'Embed App Extensions' }.flat_map { |phase| phase.files.map { |file| file.file_ref.path } },
  'targets' => project.targets.map(&:name),
  'donorConfigurations' => donor ? donor.build_configurations.map { |configuration| configuration.build_settings } : [],
  'donorSources' => donor ? donor.source_build_phase.files.map { |file| file.file_ref.path } : [],
}
puts JSON.generate(result)
'''


def fixture(path):
    canonical = path / 'native/neoswap-donation'
    canonical.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(ROOT / 'native/neoswap-donation', canonical)
    for name in JIT_PLISTS:
        destination = path / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes((ROOT / name).read_bytes())
    gemfile = path / 'build-utils/Gemfile.dolphin'
    gemfile.parent.mkdir(parents=True, exist_ok=True)
    gemfile.write_bytes((ROOT / 'build-utils/Gemfile.dolphin').read_bytes())


class DonorContractTests(unittest.TestCase):
    def test_bundle_identity_versions_and_original_jit_plists(self):
        info = plistlib.loads((ROOT / 'native/neoswap-donation/Info.plist').read_bytes())
        self.assertEqual(info['CFBundlePackageType'], 'XPC!')
        self.assertEqual(info['CFBundleIdentifier'], '$(PRODUCT_BUNDLE_IDENTIFIER)')
        self.assertEqual(info['CFBundleVersion'], '$(CURRENT_PROJECT_VERSION)')
        self.assertEqual(info['CFBundleShortVersionString'], '$(MARKETING_VERSION)')
        self.assertEqual(info['MinimumOSVersion'], '17.4')
        self.assertEqual(info['NeoStationNeoSwapDonor'], '1')
        extension = info['NSExtension']
        self.assertEqual(extension['NSExtensionPrincipalClass'], 'NeoSwapDonorRequestHandler')
        self.assertEqual(extension['NSExtensionPointIdentifier'], 'com.apple.share-services')
        self.assertEqual(extension['NSExtensionAttributes']['NSExtensionActivationRule'], 'FALSEPREDICATE')
        self.assertEqual(donor.DONOR_CONTRACT, {
            'bundleSuffix': '.neoswapdonor', 'principalClass': 'NeoSwapDonorRequestHandler',
            'marker': 'NeoStationNeoSwapDonor',
        })
        for name in JIT_PLISTS:
            old = subprocess.check_output(['git', 'show', BASE + ':' + name], cwd=ROOT)
            self.assertEqual((ROOT / name).read_bytes(), old, name)

    def test_exact_public_requested_capabilities(self):
        payload = plistlib.loads((ROOT / 'native/neoswap-donation/NeoSwapDonor.entitlements').read_bytes())
        self.assertEqual(set(payload), set(PUBLIC_CAPABILITIES))
        self.assertEqual(donor.REQUIRED_DONOR_ENTITLEMENTS, PUBLIC_CAPABILITIES)
        for key in PUBLIC_CAPABILITIES:
            self.assertIs(payload[key], True)
            for invalid in (False, 1, 'true', None):
                with self.assertRaisesRegex(ValueError, key):
                    require_entitlements({**payload, key: invalid}, PUBLIC_CAPABILITIES, 'NeoSwapDonor')

    def test_materialize_exact_canonical_sources_is_idempotent(self):
        with tempfile.TemporaryDirectory(prefix='neoswap-donor-contract-') as directory:
            root = Path(directory)
            fixture(root)
            original = {name: (root / name).read_bytes() for name in JIT_PLISTS}
            donor.materialize(root)
            donor.materialize(root)
            for relative, names in (
                ('packages/neo_swap/ios/Classes/Donation', donor.HOST_SOURCES + donor.HEADERS),
                ('ios/NeoSwapDonor', donor.DONOR_SOURCES + donor.HEADERS + ('Info.plist', 'NeoSwapDonor.entitlements')),
            ):
                destination = root / relative
                self.assertEqual({path.name for path in destination.iterdir()}, set(names))
                for name in names:
                    self.assertEqual((destination / name).read_bytes(),
                                     (root / 'native/neoswap-donation' / name).read_bytes())
            for name, data in original.items():
                self.assertEqual((root / name).read_bytes(), data, name)

    def test_unknown_generated_file_is_refused_and_preserved(self):
        with tempfile.TemporaryDirectory(prefix='neoswap-donor-contract-') as directory:
            root = Path(directory)
            fixture(root)
            folder = root / 'packages/neo_swap/ios/Classes/Donation'
            folder.mkdir(parents=True)
            unrelated = folder / 'UnrelatedRuntime.mm'
            unrelated.write_bytes(b'keep this unrelated source\n')
            with self.assertRaisesRegex(SystemExit, 'Unexpected generated donor files'):
                donor.materialize(root)
            self.assertEqual(unrelated.read_bytes(), b'keep this unrelated source\n')

    def test_extra_entitlement_is_refused_before_materialization(self):
        for entitlement in ('com.apple.private.memorystatus', 'com.apple.security.application-groups'):
            with self.subTest(entitlement=entitlement), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                fixture(root)
                payload = {**PUBLIC_CAPABILITIES, entitlement: True}
                (root / 'native/neoswap-donation/NeoSwapDonor.entitlements').write_bytes(plistlib.dumps(payload))
                with self.assertRaisesRegex(SystemExit, 'Unexpected donation entitlements'):
                    donor.materialize(root)
                self.assertFalse((root / 'ios/NeoSwapDonor').exists())

    def test_non_boolean_capability_is_refused_before_materialization(self):
        for key in PUBLIC_CAPABILITIES:
            for invalid in (False, 1, 'true'):
                with self.subTest(key=key, invalid=invalid), tempfile.TemporaryDirectory() as directory:
                    root = Path(directory)
                    fixture(root)
                    payload = {**PUBLIC_CAPABILITIES, key: invalid}
                    (root / 'native/neoswap-donation/NeoSwapDonor.entitlements').write_bytes(plistlib.dumps(payload))
                    with self.assertRaisesRegex(SystemExit, 'Unexpected donation entitlements'):
                        donor.materialize(root)
                    self.assertFalse((root / 'ios/NeoSwapDonor').exists())

    def test_unsigned_executable_does_not_inherit_sidecar_capabilities(self):
        unsigned = struct.pack('<IiiIIIII', 0xFEEDFACF, 0x0100000C, 0, 2, 0, 0, 0, 0)
        with self.assertRaisesRegex(ValueError, 'NeoSwapDonor executable is missing entitlements'):
            require_entitlements(embedded_entitlements(unsigned), PUBLIC_CAPABILITIES, 'NeoSwapDonor')

    @unittest.skipUnless(sys.platform == 'darwin', 'Apple codesign required')
    def test_actual_donor_signature_contains_exact_requested_capabilities(self):
        with tempfile.TemporaryDirectory(prefix='neoswap-donor-sign-') as directory:
            root = Path(directory)
            source = root / 'main.c'
            source.write_text('int main(void) { return 0; }\n')
            executable = root / 'NeoSwapDonor'
            subprocess.run(['xcrun', 'clang', str(source), '-o', str(executable)], check=True)
            # A successful compile alone does not satisfy the capability contract.
            with self.assertRaises(ValueError):
                require_entitlements(embedded_entitlements(executable.read_bytes()),
                                     PUBLIC_CAPABILITIES, 'NeoSwapDonor')
            entitlements = ROOT / 'native/neoswap-donation/NeoSwapDonor.entitlements'
            self.assertEqual(embed(executable, entitlements, required=PUBLIC_CAPABILITIES,
                                   owner='NeoSwapDonor'), PUBLIC_CAPABILITIES)
            dumped = subprocess.check_output(['codesign', '-d', '--entitlements', ':-', str(executable)])
            self.assertEqual(plistlib.loads(dumped), PUBLIC_CAPABILITIES)

    @unittest.skipUnless(sys.platform == 'darwin', 'macOS xcodeproj bundle required')
    def test_configure_project_preserves_three_jit_helpers_and_is_idempotent(self):
        with tempfile.TemporaryDirectory(prefix='neoswap-donor-project-') as directory:
            root = Path(directory)
            fixture(root)
            (root / 'ios').mkdir(exist_ok=True)
            donor.materialize(root)
            create = root / 'create.rb'
            create.write_text(CREATE_PROJECT)
            audit = root / 'audit.rb'
            audit.write_text(AUDIT_PROJECT)
            project = root / 'ios/Runner.xcodeproj'
            environment = dict(os.environ, BUNDLE_GEMFILE=str(root / 'build-utils/Gemfile.dolphin'),
                               BUILD_NUMBER='368')
            def ruby(script, argument, capture=False):
                command = ['bundle', 'exec', 'ruby', str(script), str(argument)]
                if capture:
                    return json.loads(subprocess.check_output(command, env=environment))
                subprocess.run(command, env=environment, check=True)
            ruby(create, root)
            original = ruby(audit, project, capture=True)
            with patch.object(donor, 'ROOT', root), patch.dict(os.environ, environment):
                donor.configure_project()
            self.assertFalse((root / 'ios/.configure_neoswap_donor.rb').exists())
            first = (project / 'project.pbxproj').read_bytes()
            with patch.object(donor, 'ROOT', root), patch.dict(os.environ, environment):
                donor.configure_project()
            self.assertFalse((root / 'ios/.configure_neoswap_donor.rb').exists())
            self.assertEqual((project / 'project.pbxproj').read_bytes(), first)
            result = ruby(audit, project, capture=True)
            self.assertEqual(result['protected'], original['protected'])
            self.assertEqual(result['runnerSources'], original['runnerSources'])
            self.assertCountEqual(result['targets'], ['Runner', *JIT_TARGETS, 'NeoSwapDonor'])
            self.assertCountEqual(result['embedded'], [name + '.appex' for name in JIT_TARGETS] + ['NeoSwapDonor.appex'])
            self.assertCountEqual(result['donorSources'], donor.DONOR_SOURCES)
            for settings in result['donorConfigurations']:
                self.assertEqual(settings['PRODUCT_BUNDLE_IDENTIFIER'], 'com.test.neostation.neoswapdonor')
                self.assertEqual(settings['CURRENT_PROJECT_VERSION'], '368')
                self.assertEqual(settings['MARKETING_VERSION'], '0.0.2')
                self.assertEqual(settings['CODE_SIGN_ENTITLEMENTS'], 'NeoSwapDonor/NeoSwapDonor.entitlements')
                self.assertEqual(settings['APPLICATION_EXTENSION_API_ONLY'], 'YES')
                self.assertEqual(settings['IPHONEOS_DEPLOYMENT_TARGET'], '17.4')


if __name__ == '__main__':
    unittest.main(verbosity=2)
