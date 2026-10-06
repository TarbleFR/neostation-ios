#!/usr/bin/env python3
"""Build integration and strict evidence checks for the isolated relay extension."""
from pathlib import Path
import copy
import json
import os
import plistlib
import re
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


def _code_without_comments(source: str, *, strip_strings: bool = False) -> str:
    output = []
    index = 0
    while index < len(source):
        if source.startswith('//', index):
            index += 2
            while index < len(source) and source[index] != '\n':
                index += 1
            if index < len(source):
                output.append('\n')
                index += 1
        elif source.startswith('/*', index):
            index += 2
            while index < len(source) and not source.startswith('*/', index):
                if source[index] == '\n':
                    output.append('\n')
                index += 1
            index += 2 if index < len(source) else 0
        elif source[index] in ('"', "'"):
            quote = source[index]
            output.append(' ' if strip_strings else source[index])
            index += 1
            while index < len(source):
                character = source[index]
                if character == '\\' and index + 1 < len(source):
                    output.append('  ' if strip_strings else source[index:index + 2])
                    index += 2
                else:
                    output.append('\n' if strip_strings and character == '\n'
                                  else ' ' if strip_strings else character)
                    index += 1
                    if character == quote:
                        break
        else:
            output.append(source[index])
            index += 1
    return ''.join(output)


def _assert_uses_public_vm_api(testcase: unittest.TestCase, sources: dict[str, str]) -> None:
    include = re.compile(r'^\s*#\s*(?:include|import)\s*[<"]mach/mach_vm\.h[>"]', re.MULTILINE)
    call = re.compile(r'\bmach_vm_(?:map|deallocate|region)\s*\(')
    for label, source in sources.items():
        testcase.assertIsNone(include.search(_code_without_comments(source)), label)
        testcase.assertIsNone(call.search(_code_without_comments(source, strip_strings=True)), label)


def _static_assert_conditions(source: str) -> list[str]:
    code = _code_without_comments(source, strip_strings=True)
    conditions = []
    position = 0
    while True:
        index = code.find('static_assert', position)
        if index < 0:
            return conditions
        before = code[index - 1:index]
        after = code[index + len('static_assert'):index + len('static_assert') + 1]
        if (before and (before.isalnum() or before == '_')) or (after and (after.isalnum() or after == '_')):
            position = index + len('static_assert')
            continue
        open_paren = code.find('(', index + len('static_assert'))
        if open_paren < 0:
            return conditions
        depth = 0
        for close_paren in range(open_paren, len(code)):
            if code[close_paren] == '(':
                depth += 1
            elif code[close_paren] == ')':
                depth -= 1
                if depth == 0:
                    conditions.append(code[open_paren + 1:close_paren])
                    position = close_paren + 1
                    break
        else:
            return conditions


def _has_width_assert(conditions: list[str], left: str, right: str, *, minimum: bool = False) -> bool:
    left_size = rf'sizeof\s*\(\s*{left}\s*\)'
    right_size = rf'sizeof\s*\(\s*(?:std::)?{right}\s*\)'
    direct = r'(?:==|>=)' if minimum else '=='
    reverse = r'(?:==|<=)' if minimum else '=='
    return any(
        re.search(rf'{left_size}\s*{direct}\s*{right_size}', condition) or
        re.search(rf'{right_size}\s*{reverse}\s*{left_size}', condition)
        for condition in conditions)


def _assert_backend_vm_width_asserts(testcase: unittest.TestCase, backend: str) -> None:
    conditions = _static_assert_conditions(backend)
    testcase.assertTrue(_has_width_assert(conditions, 'vm_address_t', 'uintptr_t'), 'vm_address_t')
    testcase.assertTrue(_has_width_assert(conditions, 'vm_size_t', 'uint64_t', minimum=True), 'vm_size_t')
    testcase.assertTrue(_has_width_assert(conditions, 'vm_offset_t', 'uint64_t', minimum=True), 'vm_offset_t')


class RelayExtensionTests(unittest.TestCase):
    def test_relay_reruns_replace_same_name_evidence_artifacts(self):
        workflow = (ROOT / '.github/workflows/neoswap-relay-check.yml').read_text()
        for artifact in ('NeoSwap-Source-${{ github.sha }}', 'NeoSwap-Relay-${{ github.sha }}'):
            start = workflow.index('name: ' + artifact)
            block = workflow[start:start + 450]
            self.assertIn('overwrite: true', block, artifact)

    def test_fast_footprint_retry_is_single_bounded_and_fail_closed(self):
        service = (ROOT / 'packages/neo_swap/ios/Classes/NeoSwapRelayService.mm').read_text()
        self.assertIn('kFastFootprintRetryDelaySeconds = 0.15', service)
        self.assertIn('kMaxFastFootprintRetries = 1', service)
        self.assertIn('result == NEOSWAP_RELAY_LIMIT && measured', service)
        self.assertIn('[measured[@"aliasDataVerified"] isEqual:@YES]', service)
        self.assertIn('[measured[@"cleanupResult"] intValue] == NEOSWAP_RELAY_OK', service)
        self.assertIn('cleanup == NEOSWAP_RELAY_OK && !pressureRaisedAfterCleanup', service)
        self.assertIn('_fastFootprintRetryCount < kMaxFastFootprintRetries', service)
        self.assertIn('_retryAfter = now + kNormalRetryDelaySeconds', service)
        self.assertIn('const uint32_t boundedTimeout = std::min(timeout, 10000u)', service)
        self.assertIn('if (!fastRetryPending || retryAfter > deadline)', service)
        self.assertIn('if (NSThread.isMainThread || !boundedTimeout)', service)
        harness = (ROOT / 'test/neoswap_relay_simulator_test.py').read_text()
        implementation = harness.index('- (void)exerciseManager {')
        manager = harness[implementation:harness.index('\n}\n', implementation) + 3]
        self.assertEqual(manager.count('NeoSwapRelay_WaitReady(10000)'), 2)
        self.assertNotIn('if (ready != NEOSWAP_RELAY_OK) ready = NeoSwapRelay_WaitReady', manager)

    def test_public_vm_api_guard_cases(self):
        allowed = {
            'comments': '''
                // #include <mach/mach_vm.h>
                /* #import "mach/mach_vm.h" */
                // mach_vm_map(mach_task_self(), nullptr, 0, 0, 0, 0, 0, 0, 0, 0);
            ''',
            'strings': '''
                const char* header = "mach/mach_vm.h";
                const char* call = "mach_vm_region(mach_task_self(), &address, &size)";
            ''',
            'public': '''
                #include <mach/mach.h>
                kern_return_t result = vm_region_64(task, &address, &size, flavor, info, &count, &object);
            ''',
        }
        _assert_uses_public_vm_api(self, allowed)
        forbidden = [
            '#include <mach/mach_vm.h>',
            '#include "mach/mach_vm.h"',
            '#import <mach/mach_vm.h>',
            '#import "mach/mach_vm.h"',
            'auto result = mach_vm_map(task, &address, size, 0, flags, port, 0, false, prot, max, inherit);',
            'auto result = mach_vm_deallocate(task, address, size);',
            'auto result = mach_vm_region(task, &address, &size, flavor, info, &count, &object);',
        ]
        for source in forbidden:
            with self.subTest(source=source), self.assertRaises(AssertionError):
                _assert_uses_public_vm_api(self, {'source.mm':source})

    def test_backend_vm_width_assert_guard_cases(self):
        good = '''
            static_assert(sizeof(vm_address_t) == sizeof(std::uintptr_t), "address width");
            static_assert(sizeof(vm_size_t) == sizeof(std::uint64_t), "size width");
            static_assert(sizeof(uint64_t) == sizeof(vm_offset_t), "offset width");
        '''
        _assert_backend_vm_width_asserts(self, good)
        minimum = good.replace('sizeof(vm_size_t) ==', 'sizeof(vm_size_t) >=').replace(
            'sizeof(uint64_t) == sizeof(vm_offset_t)', 'sizeof(uint64_t) <= sizeof(vm_offset_t)')
        _assert_backend_vm_width_asserts(self, minimum)
        for wrong in (
                minimum.replace('sizeof(vm_size_t) >=', 'sizeof(vm_size_t) <='),
                minimum.replace('sizeof(uint64_t) <=', 'sizeof(uint64_t) >='),
                minimum.replace('sizeof(vm_address_t) ==', 'sizeof(vm_address_t) >=')):
            with self.subTest(wrong=wrong), self.assertRaises(AssertionError):
                _assert_backend_vm_width_asserts(self, wrong)
        missing = '''
            static_assert(sizeof(vm_address_t) == sizeof(std::uintptr_t), "address width");
            static_assert(sizeof(vm_size_t) == sizeof(std::uint64_t), "size width");
        '''
        with self.assertRaises(AssertionError):
            _assert_backend_vm_width_asserts(self, missing)
        spilled = '''
            static_assert(sizeof(vm_address_t) == sizeof(vm_size_t), "wrong address width");
            static_assert(sizeof(vm_offset_t) == sizeof(std::uintptr_t), "unrelated uintptr");
            static_assert(sizeof(vm_size_t) == sizeof(std::uint64_t), "size width");
            static_assert(sizeof(vm_offset_t) == sizeof(std::uint64_t), "offset width");
        '''
        with self.assertRaises(AssertionError):
            _assert_backend_vm_width_asserts(self, spilled)
        incorrect = [
            good.replace('std::uintptr_t', 'std::uint64_t'),
            good.replace('std::uint64_t), "size width"', 'std::uintptr_t), "size width"'),
            good.replace('uint64_t) == sizeof(vm_offset_t)', 'uintptr_t) == sizeof(vm_offset_t)'),
        ]
        for source in incorrect:
            with self.subTest(source=source), self.assertRaises(AssertionError):
                _assert_backend_vm_width_asserts(self, source)

    def test_materialized_sources_and_harness_use_public_vm_api(self):
        from neoswap_relay_simulator_test import HARNESS
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixture(root)
            relay.materialize(root)
            generated = {}
            for relative in ('packages/neo_swap/ios/Classes/Relay', 'ios/NeoSwapPageRelay'):
                for path in (root / relative).iterdir():
                    if path.suffix in ('.cpp', '.h', '.mm'):
                        generated[str(path.relative_to(root))] = path.read_text()
            _assert_uses_public_vm_api(self, {**generated, 'test/neoswap_relay_simulator_test.py::HARNESS':HARNESS})
            _assert_backend_vm_width_asserts(
                self, (root / 'packages/neo_swap/ios/Classes/Relay/Backend.cpp').read_text())

    def test_optional_mach_import_guard_matches_final_ipa_contract(self):
        from neoswap_relay_simulator_test import validate_optional_mach_imports, OPTIONAL_MACH_IMPORTS
        allowed = '_vm_map\n_vm_deallocate\n_vm_region_64\n_dlsym\n_mach_task_self_\n'
        validate_optional_mach_imports(allowed)
        validate_optional_mach_imports('')
        expected = {'_mach_make_memory_entry_64', '_mach_vm_map',
                    '_mach_vm_deallocate', '_mach_vm_purgable_control'}
        self.assertEqual(OPTIONAL_MACH_IMPORTS, expected)
        for symbol in expected:
            for rendered in (symbol + '\n', '                 U ' + symbol + '\n'):
                with self.subTest(symbol=symbol, rendered=rendered), self.assertRaises(RuntimeError):
                    validate_optional_mach_imports(allowed + rendered)
        # Reject exact linker symbols, not unrelated longer names or the public
        # native-width vm_* entry points which every supported SDK exports.
        validate_optional_mach_imports('_mach_vm_map_named_diagnostic\n')

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
                'productionManagerHostLoanOwnerEnabled':True, 'productionManagerHostLoanQuotaEnforced':True,
                'productionManagerDiagnosticsCoherent':True, 'productionManagerIdleSamples':3,
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
