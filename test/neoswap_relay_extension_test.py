#!/usr/bin/env python3
"""Build integration and strict evidence checks for the isolated relay extension."""
from pathlib import Path
import copy
import json
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'build-utils'))
import configure_neoswap_relay as relay

PROTECTED = ('NeoSwapDonor', 'DolphinJITHelper', 'RPCS3JITHelper', 'ARMSX2JITHelper',
             'DolphinCore', 'RPCS3Core', 'ARMSX2Core', 'KartpadCore', 'DusklightCore')
PUBLIC_CAPABILITIES = {'get-task-allow': True,
                      'com.apple.developer.kernel.increased-memory-limit': True,
                      'com.apple.developer.kernel.increased-debugging-memory-limit': True}
CREATE = r'''
require 'xcodeproj'
project = Xcodeproj::Project.new(File.join(ARGV.fetch(0), 'ios/Runner.xcodeproj'))
runner = project.new_target(:application, 'Runner', :ios, '18.0')
runner.build_configurations.each do |configuration|
  configuration.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'com.test.neostation'
  configuration.build_settings['CODE_SIGN_ENTITLEMENTS'] = 'Runner/Original.entitlements'
end
File.write(File.join(ARGV.fetch(0), 'ios/Original.mm'), 'void original(void) {}')
runner.source_build_phase.add_file_reference(project.main_group.new_file('Original.mm'))
phase = runner.new_shell_script_build_phase('Original renderer integration')
phase.shell_script = 'true'
embed = runner.new_copy_files_build_phase('Embed App Extensions')
embed.dst_subfolder_spec = '13'
ARGV.fetch(1).split(',').each do |name|
  type = name.end_with?('Core') ? :static_library : :app_extension
  target = project.new_target(type, name, :ios, '18.0')
  target.build_configurations.each do |configuration|
    configuration.build_settings['ORIGINAL_SENTINEL'] = name
    configuration.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'com.test.neostation.' + name
    configuration.build_settings['CODE_SIGN_ENTITLEMENTS'] = name + '.entitlements'
  end
  runner.add_dependency(target)
  embed.add_file_reference(target.product_reference) if type == :app_extension
end
project.save
'''
AUDIT = r'''
require 'xcodeproj'
require 'json'
project = Xcodeproj::Project.open(ARGV.fetch(0))
def snapshot(target)
  [target.to_hash, target.build_phases.map { |phase| [phase.to_hash, phase.files.map(&:to_hash)] },
   target.build_configurations.map(&:to_hash), target.dependencies.map(&:to_hash)]
end
runner = project.targets.find { |target| target.name == 'Runner' }
relay = project.targets.find { |target| target.name == 'NeoSwapPageRelay' }
puts JSON.generate({
  'protected' => project.targets.reject { |target| ['Runner','NeoSwapPageRelay'].include?(target.name) }.to_h { |target| [target.name,snapshot(target)] },
  'runnerSettings' => runner.build_configurations.map(&:to_hash),
  'runnerPhases' => runner.build_phases.reject { |phase| phase.display_name == 'Embed App Extensions' }.map(&:to_hash),
  'embedded' => runner.copy_files_build_phases.flat_map { |phase| phase.files.map { |file| file.file_ref.path } },
  'dependencies' => runner.dependencies.map { |dependency| dependency.target&.name },
  'targets' => project.targets.map(&:name),
  'relaySettings' => relay&.build_configurations&.map(&:build_settings),
  'relaySources' => relay&.source_build_phase&.files&.map { |file| file.file_ref.path }
})
'''


def fixture(root):
    for directory in ('native/neoswap-relay', 'native/neoswap-donation'):
        shutil.copytree(ROOT / directory, root / directory)
    public = root / 'packages/neo_swap/ios/Classes/NeoSwapRelay.h'
    public.parent.mkdir(parents=True)
    shutil.copyfile(ROOT / 'packages/neo_swap/ios/Classes/NeoSwapRelay.h', public)
    gem = root / 'build-utils/Gemfile.dolphin'
    gem.parent.mkdir(parents=True)
    shutil.copyfile(ROOT / 'build-utils/Gemfile.dolphin', gem)


class RelayExtensionTests(unittest.TestCase):
    def test_canonical_bundle_contract(self):
        info = plistlib.loads((ROOT / 'native/neoswap-relay/Info.plist').read_bytes())
        for key, value in {'CFBundlePackageType':'XPC!', 'MinimumOSVersion':'18.0',
                           'CFBundleIdentifier':'$(PRODUCT_BUNDLE_IDENTIFIER)',
                           'CFBundleVersion':'$(CURRENT_PROJECT_VERSION)',
                           'CFBundleShortVersionString':'$(MARKETING_VERSION)',
                           'NeoStationNeoSwapPageRelay':'1'}.items():
            self.assertEqual(info[key], value)
        self.assertEqual(info['NSExtension'], {
            'NSExtensionAttributes':{'NSExtensionActivationRule':'FALSEPREDICATE'},
            'NSExtensionPointIdentifier':'com.apple.ar.viewer',
            'NSExtensionPrincipalClass':'NeoSwapPageRelayHandler',
            'NSExtensionContextClass':'NeoSwapPageRelayContext',
            'NSExtensionContextHostClass':'NSExtensionContext'})
        self.assertEqual(info['XPCService'], {'ServiceType':'Application', '_ProcessType':'App', '_MultipleInstances':True})
        self.assertIs(info['XPCService']['_MultipleInstances'], True)
        self.assertEqual(relay.RELAY_CONTRACTS, {'NeoSwapPageRelay.appex':{
            'bundleSuffix':'.NeoSwapPageRelay', 'principalClass':'NeoSwapPageRelayHandler',
            'marker':'NeoStationNeoSwapPageRelay'}})
        capabilities = plistlib.loads((ROOT / 'native/neoswap-relay/NeoSwapPageRelay.entitlements').read_bytes())
        self.assertEqual(capabilities, PUBLIC_CAPABILITIES)
        self.assertTrue(all(value is True for value in capabilities.values()))
        self.assertEqual(relay.REQUIRED_RELAY_ENTITLEMENTS, PUBLIC_CAPABILITIES)

    def test_materialization_is_identical_idempotent_and_preserves_existing_runtime(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixture(root)
            untouched = root / 'ios/NeoSwapDonor/Original.mm'
            untouched.parent.mkdir(parents=True)
            untouched.write_bytes(b'preserve donor and JIT integrations\n')
            relay.materialize(root)
            relay.materialize(root)
            for relative, names in (
                ('packages/neo_swap/ios/Classes/Relay', relay.HOST_SOURCES + relay.HOST_HEADERS),
                ('ios/NeoSwapPageRelay', relay.EXTENSION_SOURCES + relay.EXTENSION_HEADERS +
                 ('Info.plist', 'NeoSwapPageRelay.entitlements')),
            ):
                output = root / relative
                self.assertEqual({path.name for path in output.iterdir()}, set(names))
                for name in names:
                    origin = 'native/neoswap-donation' if name in relay.EXTENSION_DEPENDENCIES else 'native/neoswap-relay'
                    self.assertEqual((output / name).read_bytes(), (root / origin / name).read_bytes())
            self.assertEqual(untouched.read_bytes(), b'preserve donor and JIT integrations\n')

    def test_all_destinations_preflight_before_writes(self):
        for relative in ('packages/neo_swap/ios/Classes/Relay', 'ios/NeoSwapPageRelay'):
            with self.subTest(relative=relative), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                fixture(root)
                unknown = root / relative / 'Unrelated.mm'
                unknown.parent.mkdir(parents=True)
                unknown.write_bytes(b'keep')
                with self.assertRaisesRegex(SystemExit, 'Unexpected generated page-relay files'):
                    relay.materialize(root)
                self.assertEqual(unknown.read_bytes(), b'keep')
                self.assertFalse((root / 'packages/neo_swap/ios/Classes/Relay/Backend.cpp').exists())

    def test_invalid_capabilities_fail_before_generated_writes(self):
        mutations = [{**PUBLIC_CAPABILITIES, 'com.apple.private.memorystatus':True},
                     {**PUBLIC_CAPABILITIES, 'com.apple.security.application-groups':['foreign']}]
        for key in PUBLIC_CAPABILITIES:
            mutations.extend({**PUBLIC_CAPABILITIES, key:value} for value in (False, 1, 'true'))
        for capabilities in mutations:
            with self.subTest(capabilities=capabilities), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                fixture(root)
                (root / 'native/neoswap-relay/NeoSwapPageRelay.entitlements').write_bytes(plistlib.dumps(capabilities))
                with self.assertRaisesRegex(SystemExit, 'Unexpected page-relay entitlements'):
                    relay.materialize(root)
                self.assertFalse((root / 'ios/NeoSwapPageRelay').exists())

    def test_simulator_evidence_requires_actual_lifecycle_and_aliases(self):
        from neoswap_relay_simulator_test import validate_evidence, TARGET_BYTES
        good = {'schema':1, 'platform':'iOS18Simulator', 'passed':True,
                'transport':'real-NSExtension-auxiliary-NSXPC', 'realIPhoneValidated':False,
                'realRPCS3GameplayValidated':False, 'hostPID':51, 'creatorPID':67,
                'creatorExitObserved':True, 'capacityBytes':TARGET_BYTES,
                'writtenBytes':TARGET_BYTES, 'aliasCountDuringUse':2,
                'liveBytesDuringUse':TARGET_BYTES, 'aliasedBytesDuringUse':2 * TARGET_BYTES,
                'retainedBytesAfterRelease':TARGET_BYTES, 'liveBytesAfterRelease':0,
                'capacityBytesAfterShutdown':0, 'pendingCleanupAfterShutdown':0,
                'aliasCoherencePassed':True, 'readOnlyAliasPassed':True,
                'releaseWhileMappedRefused':True, 'staleTokenRefused':True,
                'releaseZeroingPassed':True, 'releasePassed':True, 'secondPreparationPassed':True,
                'secondCreatorPID':68, 'secondGeneration':2,
                'generation':1, 'firstCreatorExitObserved':True, 'secondCreatorExitObserved':True,
                'productionManagerPassed':True, 'productionManagerMainThreadNonblocking':True,
                'productionManagerRPCS3Only':True, 'productionManagerCapacityBytes':8*1024**3,
                'productionManagerWrittenBytes':TARGET_BYTES}
        good['productionManager'] = {'ready':True, 'creatorExitObserved':True, 'state':'ready',
            'capacityBytes':8*1024**3, 'residentBytes':None, 'liveBackingBytes':0,
            'objectCount':0, 'aliasCount':0, 'pendingCleanupEntries':0,
            'capabilityCheck':{'kind':'post_creator_exit_cpu_capability_check',
                'requestedBytes':16 * 1024**2, 'aliasDataVerified':True, 'result':0,
                'cleanupResult':0, 'gameplayValidated':False, 'hostFootprintBeforeBytes':100000,
                'hostFootprintAfterBytes':200000, 'hostFootprintDeltaBytes':100000}}
        validate_evidence(good)
        mutations = [(key, False) for key, value in good.items() if value is True]
        mutations += [(key, True) for key, value in good.items() if value is False]
        mutations += [('creatorPID',51), ('secondCreatorPID',67), ('creatorPID',0),
                      ('capacityBytes',TARGET_BYTES - 1), ('writtenBytes',0),
                      ('liveBytesDuringUse',0), ('aliasedBytesDuringUse',TARGET_BYTES),
                      ('aliasCountDuringUse',1), ('capacityBytesAfterShutdown',65536),
                      ('pendingCleanupAfterShutdown',1), ('liveBytesAfterRelease',1),
                      ('generation',2), ('secondGeneration',1), ('schema',True), ('productionManager',{}),
                      ('productionManagerCapacityBytes',0), ('productionManagerCapacityBytes',1024**3),
                      ('productionManagerWrittenBytes',0), ('productionManagerWrittenBytes',8*1024**3)]
        for key, value in mutations:
            report = copy.deepcopy(good)
            report[key] = value
            with self.subTest(key=key, value=value), self.assertRaises(RuntimeError):
                validate_evidence(report)

    @unittest.skipUnless(sys.platform == 'darwin', 'Apple xcodeproj integration exercised by mandatory macOS CI')
    def test_xcode_project_preserves_all_existing_targets_and_is_idempotent(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixture(root)
            (root / 'ios').mkdir()
            relay.materialize(root)
            create, audit = root / 'create.rb', root / 'audit.rb'
            create.write_text(CREATE)
            audit.write_text(AUDIT)
            project = root / 'ios/Runner.xcodeproj'
            environment = dict(os.environ, BUNDLE_GEMFILE=str(root / 'build-utils/Gemfile.dolphin'), BUILD_NUMBER='372')
            def ruby(script, *arguments, capture=False):
                command = ['bundle', 'exec', 'ruby', str(script), *map(str, arguments)]
                if capture:
                    return json.loads(subprocess.check_output(command, env=environment))
                subprocess.run(command, env=environment, check=True)
            ruby(create, root, ','.join(PROTECTED))
            before = ruby(audit, project, capture=True)
            with patch.object(relay, 'ROOT', root), patch.dict(os.environ, environment):
                relay.configure_project()
                first = (project / 'project.pbxproj').read_bytes()
                relay.configure_project()
            self.assertEqual(first, (project / 'project.pbxproj').read_bytes())
            after = ruby(audit, project, capture=True)
            for key in ('protected', 'runnerSettings', 'runnerPhases'):
                self.assertEqual(before[key], after[key], key)
            self.assertCountEqual(after['targets'], ['Runner', *PROTECTED, 'NeoSwapPageRelay'])
            self.assertCountEqual(after['dependencies'], [*before['dependencies'], 'NeoSwapPageRelay'])
            self.assertCountEqual(after['embedded'], [*before['embedded'], 'NeoSwapPageRelay.appex'])
            self.assertCountEqual(after['relaySources'], relay.EXTENSION_SOURCES)
            self.assertFalse((root / 'ios/.configure_neoswap_relay.rb').exists())
            for settings in after['relaySettings']:
                for key, expected in {'PRODUCT_BUNDLE_IDENTIFIER':'com.test.neostation.NeoSwapPageRelay',
                                      'CURRENT_PROJECT_VERSION':'372', 'MARKETING_VERSION':'0.0.2',
                                      'INFOPLIST_FILE':'NeoSwapPageRelay/Info.plist',
                                      'CODE_SIGN_ENTITLEMENTS':'NeoSwapPageRelay/NeoSwapPageRelay.entitlements',
                                      'APPLICATION_EXTENSION_API_ONLY':'YES',
                                      'IPHONEOS_DEPLOYMENT_TARGET':'18.0',
                                      'CLANG_CXX_LANGUAGE_STANDARD':'c++20'}.items():
                    self.assertEqual(settings[key], expected)


if __name__ == '__main__':
    unittest.main()
