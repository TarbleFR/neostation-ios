"""Exercise one multiprocess donor bundle and its requested capabilities."""
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
DONOR_IDENTITIES = (
    ('NeoSwapDonor', '.neoswapdonor', '0'),
)
EXPECTED_DONOR_CONTRACTS = {
    name + '.appex': {'bundleSuffix': suffix, 'principalClass': 'NeoSwapDonorRequestHandler',
                     'marker': 'NeoStationNeoSwapDonor', 'index': index}
    for name, suffix, index in DONOR_IDENTITIES
}

EXPECTED_RELAY_CONTRACTS = {
    'NeoSwapPageRelay.appex': {'bundleSuffix': '.NeoSwapPageRelay',
        'principalClass': 'NeoSwapPageRelayHandler', 'marker': 'NeoStationNeoSwapPageRelay'},
}

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
donor_names = ['NeoSwapDonor']
donors = project.targets.select { |target| donor_names.include?(target.name) }
result = {
  'protected' => helpers.to_h { |name| [name, snapshot(project.targets.find { |target| target.name == name })] },
  'runnerSources' => runner.source_build_phase.files.map { |file| file.file_ref.path },
  'embedded' => runner.copy_files_build_phases.select { |phase| phase.name == 'Embed App Extensions' }.flat_map { |phase| phase.files.map { |file| file.file_ref.path } },
  'targets' => project.targets.map(&:name),
  'dependencies' => runner.dependencies.map { |dependency| dependency.target&.name },
  'donorConfigurations' => donors.to_h { |donor| [donor.name, donor.build_configurations.map { |configuration| configuration.build_settings }] },
  'donorSources' => donors.to_h { |donor| [donor.name, donor.source_build_phase.files.map { |file| file.file_ref.path }] },
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


def signed_macho(capabilities):
    """Synthetic signature layout tests parsing, not certificate trust."""
    xml = plistlib.dumps(capabilities)
    entitlement_slot = struct.pack('>II', 0xFADE7171, len(xml) + 8) + xml
    signature = struct.pack('>III', 0xFADE0CC0, len(entitlement_slot) + 20, 1)
    signature += struct.pack('>II', 5, 20) + entitlement_slot
    header = struct.pack('<8I', 0xFEEDFACF, 0x0100000C, 0, 2, 1, 16, 0, 0)
    return header + struct.pack('<4I', 0x1D, 16, 48, len(signature)) + signature


def packaged_helpers(root):
    app = root / 'Payload/NeoStation.app'
    host = {'CFBundleIdentifier': 'com.test.neostation', 'CFBundleVersion': '368',
            'CFBundleShortVersionString': '0.0.2'}
    jit_contracts = {
        'DolphinJITHelper.appex': {'bundleSuffix': '.dolphinjithelper',
            'principalClass': 'DolphinJITRequestHandler', 'marker': 'NeoStationDolphinJITHelper'},
        'RPCS3JITHelper.appex': {'bundleSuffix': '.rpcs3jithelper',
            'principalClass': 'Rpcs3JITRequestHandler', 'marker': 'NeoStationRPCS3JITHelper'},
        'ARMSX2JITHelper.appex': {'bundleSuffix': '.armsx2jithelper',
            'principalClass': 'Armsx2JITRequestHandler', 'marker': 'NeoStationARMSX2JITHelper'},
    }
    for bundle, contract in {**jit_contracts, **EXPECTED_DONOR_CONTRACTS, **EXPECTED_RELAY_CONTRACTS}.items():
        folder = app / 'PlugIns' / bundle
        folder.mkdir(parents=True)
        info = {**host, 'CFBundleIdentifier': host['CFBundleIdentifier'] + contract['bundleSuffix'],
                'CFBundleExecutable': bundle.removesuffix('.appex'), 'CFBundlePackageType': 'XPC!',
                contract['marker']: '1', 'NSExtension': {
                    'NSExtensionPointIdentifier': 'com.apple.share-services',
                    'NSExtensionPrincipalClass': contract['principalClass']}}
        if bundle in EXPECTED_DONOR_CONTRACTS:
            info['NeoStationNeoSwapDonorIndex'] = contract['index']
            info['MinimumOSVersion'] = '17.4'
            info['NSExtension']['NSExtensionAttributes'] = {'NSExtensionActivationRule': 'FALSEPREDICATE'}
            info['NSExtension']['NSExtensionPointIdentifier'] = 'com.apple.ar.viewer'
            info['NSExtension']['NSExtensionContextClass'] = 'NeoSwapDonorContext'
            info['NSExtension']['NSExtensionContextHostClass'] = 'NSExtensionContext'
            info['XPCService'] = {'ServiceType': 'Application', '_ProcessType': 'App', '_MultipleInstances': True}
        if bundle in EXPECTED_RELAY_CONTRACTS:
            info['MinimumOSVersion'] = '18.0'
            info['NSExtension'].update(
                NSExtensionAttributes={'NSExtensionActivationRule': 'FALSEPREDICATE'},
                NSExtensionPointIdentifier='com.apple.ar.viewer',
                NSExtensionContextClass='NeoSwapPageRelayContext',
                NSExtensionContextHostClass='NSExtensionContext')
            info['XPCService'] = {'ServiceType': 'Application', '_ProcessType': 'App', '_MultipleInstances': True}
        (folder / 'Info.plist').write_bytes(plistlib.dumps(info))
        capabilities = PUBLIC_CAPABILITIES if bundle in EXPECTED_DONOR_CONTRACTS or bundle in EXPECTED_RELAY_CONTRACTS else {}
        (folder / info['CFBundleExecutable']).write_bytes(signed_macho(capabilities))
    return app, host


class DonorContractTests(unittest.TestCase):
    def test_ipa_validator_matches_single_relay_lifecycle_ownership(self):
        validator = (ROOT / 'build-utils/validate_neoswap_ipa.py').read_text()
        bridge = (ROOT / 'packages/rpcs3_internal_bridge/ios/Classes/Rpcs3InternalBridgePlugin.mm').read_text()
        plugin = (ROOT / 'packages/neo_swap/ios/Classes/NeoSwapPlugin.mm').read_text()
        for call in ('NeoSwap_GetAPI(', 'NeoSwap_GetRelayAPI(', 'NeoSwapRelay_WaitReady(',
                     'NeoSwap_LiveBytes(', 'NeoSwap_HostSnapshot(', 'NeoSwap_RegisterClient('):
            self.assertIn(call, bridge)
        self.assertNotIn('NeoSwapRelay_Start(', bridge)
        self.assertNotIn('NeoSwapRelay_Start();', plugin)
        service = (ROOT / 'packages/neo_swap/ios/Classes/NeoSwapRelayService.mm').read_text()
        self.assertIn('[self start];', service.split('- (int)waitReady:(uint32_t)timeout {', 1)[1])
        self.assertIn("'_NeoSwapRelay_Start' not in undefined", validator)
        self.assertIn("'_NeoSwapRelay_Start'", validator)
        self.assertIn("'_NeoSwap_GetRelayAPI'", validator)

    def test_rpcs3_waits_before_first_map_and_uses_session_scoped_adaptive_pool(self):
        bridge = (ROOT / 'packages/rpcs3_internal_bridge/ios/Classes/Rpcs3InternalBridgePlugin.mm').read_text()
        plugin = (ROOT / 'packages/neo_swap/ios/Classes/NeoSwapPlugin.mm').read_text()
        host = (ROOT / 'packages/neo_swap/ios/Classes/NeoSwapHost.h').read_text()
        pool = (ROOT / 'native/neoswap-donation/Pool.cpp').read_text()
        ipc = (ROOT / 'native/neoswap-donation/NeoSwapDonorIPC.mm').read_text()
        handler = (ROOT / 'native/neoswap-donation/NeoSwapDonorRequestHandler.mm').read_text()
        overlay = (ROOT / 'packages/rpcs3_internal_bridge/ios/Classes/RPCS3PerformanceOverlay.mm').read_text()
        header = (ROOT / 'packages/rpcs3_internal_bridge/ios/Classes/RPCS3PerformanceOverlay.h').read_text()
        self.assertIn('NeoSwapRelay_WaitReady(10000)', bridge)
        self.assertIn('relayReady != NEOSWAP_RELAY_OK', bridge)
        self.assertIn('RPCS3_NEOSWAP_NOT_READY', bridge)
        self.assertIn('if (swapResult != NEOSWAP_OK || relayResult != NEOSWAP_RELAY_OK)', bridge)
        self.assertIn('neoswap_relay_fallback', bridge)
        self.assertNotIn('swapResult != NEOSWAP_OK || relayReady !=', bridge)
        self.assertLess(bridge.index('NeoSwapRelay_WaitReady(10000)'),
                        bridge.index('NeoSwap_RegisterClient(NEOSWAP_RPCS3)'))
        self.assertIn('NeoSwap_SetOwnerSessionActive(NEOSWAP_RPCS3, 1)', bridge)
        self.assertIn('NeoSwap_SetOwnerSessionActive(NEOSWAP_RPCS3, 0)', bridge)
        launch = bridge.split('if ([call.method isEqualToString:@"launchGame"])', 1)[1].split(
            'if ([call.method isEqualToString:@"isSessionActive"])', 1)[0]
        boot_call = ('[self bootTitleForCore:titleId.UTF8String '
                     'savestate:savestateId.length ? savestateId.UTF8String : NULL]')
        self.assertLess(launch.index('NeoSwap_SetOwnerSessionActive(NEOSWAP_RPCS3, 1)'),
                        launch.index(boot_call))
        # The telemetry wrapper keeps the SAME Core boot call and status.
        # Donation still becomes active before the launch call above; merely
        # finding a raw API call in an earlier helper would not prove ordering.
        wrapper = bridge.split(
            '- (rpcs3_ios_status)bootTitleForCore:(const char*)title savestate:(const char*)identifier {',
            1)[1].split('\n}', 1)[0]
        raw_boot = 'const rpcs3_ios_status status = _api.boot_game(title, identifier);'
        self.assertEqual(bridge.count('_api.boot_game('), 1)
        self.assertEqual(wrapper.count(raw_boot), 1)
        self.assertIn('return status;', wrapper)
        self.assertLess(wrapper.index('[self invalidatePerformanceSnapshotForBoot]'),
                        wrapper.index(raw_boot))
        self.assertIn('if (status != 0) _performanceSnapshot.end();', wrapper)
        invalidate = bridge.split('- (void)invalidatePerformanceSnapshotForBoot {', 1)[1].split('\n}', 1)[0]
        self.assertIn('if (++_performanceEpoch == 0) ++_performanceEpoch;', invalidate)
        self.assertIn('_performanceSnapshot.begin(_performanceEpoch);', invalidate)
        self.assertIn('_performanceDisplayEpoch.store(_performanceEpoch, std::memory_order_release);', invalidate)
        self.assertIn('NeoSwap_SetOwnerSessionActive', host)
        self.assertIn('NeoSwap_OwnerSessionActive', host)
        self.assertIn('NeoSwap_WaitForDonationReady', host)
        self.assertIn('NeoSwap_WaitForDonationReady(', bridge)
        self.assertIn('kNeoSwapBootMinimumBytes = 384ULL * 1024 * 1024', bridge)
        self.assertIn('kNeoSwapBootWaitMs = 1500', bridge)
        self.assertNotIn('kNeoSwapWarmWaitMs = 8000', bridge)
        self.assertIn('pool_campaign_end(self.donorEpoch)', plugin)
        self.assertIn('Result pool_campaign_end', pool)
        self.assertIn('kDonationHardLimitBytes = 5 * kGiB', plugin)
        self.assertIn('kDonationWarmFloorBytes = 512 * kMiB', plugin)
        self.assertIn('kDonationReserveBytes = 128 * kMiB', plugin)
        self.assertIn('kDonationGrowthQuantumBytes = 128 * kMiB', plugin)
        self.assertIn('kDonationInitialChunkBytes = 256 * kMiB', plugin)
        self.assertIn('kDonationPrimaryChunkBytes = 256 * kMiB', plugin)
        self.assertIn('kDonationFallbackChunkBytes = 128 * kMiB', plugin)
        self.assertIn('kDonationConcurrentGrowths = 2', plugin)
        self.assertIn('kDonationWarmDonorCount = 2', plugin)
        self.assertIn('- (uint64_t)adaptiveDonationTarget', plugin)
        target = plugin.split('- (uint64_t)adaptiveDonationTarget {', 1)[1].split('- (void)retireDonorsIfIdle', 1)[0]
        self.assertIn('adaptive_donation_target(pool.live_bytes', target)
        self.assertNotIn('NeoSwap_LiveBytes', target)
        self.assertIn('if (![logState isEqual:self.donorLoggedStates[errorKey]])', plugin)
        self.assertIn('bytes <= neostation::donation::max_chunk_bytes', ipc)
        self.assertIn('initial > neostation::donation::max_chunk_bytes', handler)
        self.assertIn('pool.prepared_bytes + pending >= adaptiveTarget', plugin)
        self.assertIn('NSMutableIndexSet* donorPendingIndexes', plugin)
        self.assertIn('timeout:60', plugin)
        self.assertIn('@"donationTargetBytes":@(adaptiveTarget)', plugin)
        # Build409: the diagnostic reports the floor/reserve the global budget
        # controller actually hands to adaptive_donation_target(). Before the
        # first decision, and for research profiles, the fixed values remain.
        self.assertIn('@"donationWarmFloorBytes":@([self donorFloorBytes])', plugin)
        self.assertIn('@"donationReserveBytes":@([self donorReserveBytes])', plugin)
        self.assertIn('[self donorFloorBytes], [self donorReserveBytes]', target)
        floor = plugin.split('- (uint64_t)donorFloorBytes {', 1)[1].split('\n}', 1)[0]
        self.assertIn('if (NeoSwapExperimentProfile().configured) return 16*kMiB;', floor)
        self.assertIn('return _budgetDecisionCount ? _budgetDecision.donor_floor_bytes : kDonationWarmFloorBytes;', floor)
        reserve = plugin.split('- (uint64_t)donorReserveBytes {', 1)[1].split('\n}', 1)[0]
        self.assertIn('if (NeoSwapExperimentProfile().configured) return 32*kMiB;', reserve)
        self.assertIn('return _budgetDecisionCount ? _budgetDecision.donor_reserve_bytes : kDonationReserveBytes;', reserve)
        self.assertIn('if (!_budgetDecision.donor_growth_admitted) {', plugin)
        self.assertIn('if (available > _budgetDecision.donor_room_bytes) available = _budgetDecision.donor_room_bytes;', plugin)
        self.assertIn('@"stage":@"global_budget_refused_growth"', plugin)
        self.assertIn('bytes > neostation::donation::max_chunk_bytes', ipc)
        self.assertIn('maximum > neostation::donation::max_chunk_bytes', handler)
        self.assertIn('processResidentBytes', header)
        self.assertIn('RPCS3ProcessResidentBytes', bridge)
        self.assertIn('NeoSwapMemoryGraph(host, relayLiveBytes, relayMeasured, processResidentBytes)', overlay)
        policy = (ROOT / 'packages/rpcs3_internal_bridge/ios/Classes/NeoSwapUsagePolicy.h').read_text()
        self.assertIn('host->owner_donated_live_bytes[NEOSWAP_RPCS3]', policy)
        self.assertIn('loans + relayLiveBacking', policy)
        self.assertNotIn('donor_prepared_bytes', overlay)
        self.assertNotIn('fpsLine', overlay)
        self.assertIn('pending_headroom_budget', plugin)
        self.assertIn('self.donorPendingMaximums[index] = @(first)', plugin)
        broker = (ROOT / 'native/neoswap-donation/Broker.h').read_text()
        self.assertIn('max_chunk_bytes = 256ULL * 1024 * 1024', broker)
        self.assertIn('kDonationPrimaryChunkBytes == neostation::donation::max_chunk_bytes', plugin)
        self.assertIn('systemCyanColor', overlay)
        self.assertIn('systemOrangeColor', overlay)
        # Build409: sub-MiB RSX buffers are admitted for every title whenever
        # relay host loans or donors exist; the global budget closes the gate
        # under measured pressure. The title list only selects the Core profile.
        self.assertIn('const BOOL cpuBuffersEnabled = NeoSwapExperimentProfile().relay() || NeoSwapExperimentProfile().donors();', bridge)
        self.assertIn('NeoSwap_SetCPUBufferExperiment(cpuBuffersEnabled);', bridge)
        self.assertNotIn('NeoSwap_SetCPUBufferExperiment(NeoSwapExperimentProfile().donors() &&', bridge)
        self.assertIn('NeoSwapCPUBufferTitle(titleId.UTF8String', bridge)
        self.assertIn('high_footprint_profile=%d', bridge)
        self.assertIn('cpuBufferExperiment', plugin)
        self.assertIn('NeoSwap_SetCPUBufferPressure(self.cpuBufferPressureRaised', plugin)
        self.assertIn('DISPATCH_MEMORYPRESSURE_WARN | DISPATCH_MEMORYPRESSURE_CRITICAL', plugin)
        self.assertIn('diskFallback":@NO', plugin)
        client = (ROOT / 'native/neoswap/NeoSwapClient.h').read_text()
        self.assertIn('inline void* try_allocate_cpu(', client)
        self.assertIn('bytes >= 1024 * 1024 || bytes < 64 * 1024', client)

    def test_chunk_preparation_uses_chunk_deadline_not_idle_heartbeat(self):
        source = (ROOT / 'native/neoswap-donation/NeoSwapDonorIPC.mm').read_text()
        timer = source.split('- (void)beginTimer {', 1)[1].split('- (void)start {', 1)[0]
        chunk_timeout = timer.index('failure(3120, @"Donor chunk preparation/shared-page verification timed out")')
        heartbeat_timeout = timer.index('failure(3102, @"Donor ledger heartbeat expired")')
        self.assertLess(chunk_timeout, heartbeat_timeout)
        heartbeat_guard = timer[max(0, heartbeat_timeout - 450):heartbeat_timeout]
        self.assertIn('growthState != NeoSwapDonorGrowthPreparing', heartbeat_guard)
        self.assertIn('now - self->_chunkStarted', timer[:heartbeat_timeout])

    def test_simulator_launcher_keeps_native_result_when_cli_stalls(self):
        # Local child exercises orchestration only, never Foundation/donation.
        from neoswap_donor_simulator_test import collect_launch_evidence, validate_evidence
        with tempfile.TemporaryDirectory() as directory:
            evidence = Path(directory) / 'report.json'
            command = [sys.executable, '-c',
                       'import pathlib,sys,time; pathlib.Path(sys.argv[1]).write_text('
                       '\'{"passed":false,"stage":"actual_native_failure"}\'); time.sleep(30)', str(evidence)]
            result = collect_launch_evidence(command, evidence, timeout=5)
            self.assertEqual(result['runtimeEvidence']['stage'], 'actual_native_failure')
            self.assertIs(result['launchClientStoppedAfterEvidence'], True)
            self.assertIsNotNone(result['launchClientReturnCode'])
            with self.assertRaises(RuntimeError):
                validate_evidence(result['runtimeEvidence'])
            with self.assertRaisesRegex(RuntimeError, 'pre-existing'):
                collect_launch_evidence(command, evidence, timeout=1)

    def test_simulator_launcher_requires_evidence_even_after_cli_success(self):
        from neoswap_donor_simulator_test import collect_launch_evidence
        with tempfile.TemporaryDirectory() as directory:
            evidence = Path(directory) / 'report.json'
            with self.assertRaisesRegex(RuntimeError, 'did not produce'):
                collect_launch_evidence([sys.executable, '-c', 'pass'], evidence, timeout=0.5)
            with self.assertRaises(subprocess.CalledProcessError):
                collect_launch_evidence([sys.executable, '-c', 'raise SystemExit(7)'], evidence, timeout=5)

    def test_bundle_identity_versions_and_original_jit_plists(self):
        info = plistlib.loads((ROOT / 'native/neoswap-donation/Info.plist').read_bytes())
        self.assertEqual(info['CFBundlePackageType'], 'XPC!')
        self.assertEqual(info['CFBundleIdentifier'], '$(PRODUCT_BUNDLE_IDENTIFIER)')
        self.assertEqual(info['CFBundleVersion'], '$(CURRENT_PROJECT_VERSION)')
        self.assertEqual(info['CFBundleShortVersionString'], '$(MARKETING_VERSION)')
        self.assertEqual(info['MinimumOSVersion'], '17.4')
        self.assertEqual(info['NeoStationNeoSwapDonor'], '1')
        self.assertEqual(info['NeoStationNeoSwapDonorIndex'], '$(NEOSWAP_DONOR_INDEX)')
        extension = info['NSExtension']
        self.assertEqual(extension['NSExtensionPrincipalClass'], 'NeoSwapDonorRequestHandler')
        self.assertEqual(extension['NSExtensionPointIdentifier'], 'com.apple.ar.viewer')
        self.assertEqual(extension['NSExtensionContextClass'], 'NeoSwapDonorContext')
        self.assertEqual(extension['NSExtensionContextHostClass'], 'NSExtensionContext')
        self.assertEqual(info['XPCService'], {
            'ServiceType': 'Application', '_ProcessType': 'App', '_MultipleInstances': True})
        self.assertIs(info['XPCService']['_MultipleInstances'], True)
        self.assertEqual(extension['NSExtensionAttributes']['NSExtensionActivationRule'], 'FALSEPREDICATE')
        self.assertEqual(donor.DONOR_CONTRACTS, EXPECTED_DONOR_CONTRACTS)
        self.assertEqual(donor.DONOR_CONTRACT, EXPECTED_DONOR_CONTRACTS['NeoSwapDonor.appex'])
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
            destinations = [('packages/neo_swap/ios/Classes/Donation', donor.HOST_SOURCES + donor.HEADERS)]
            destinations += [('ios/' + name, donor.DONOR_SOURCES + donor.HEADERS +
                              ('Info.plist', 'NeoSwapDonor.entitlements'))
                             for name, _, _ in DONOR_IDENTITIES]
            for relative, names in destinations:
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

    def test_rpcs3_validator_requires_exact_single_donor_bundle(self):
        import validate_rpcs3_ipa as rpcs3
        self.assertEqual({name: rpcs3.EXPECTED_HELPERS[name] for name in EXPECTED_DONOR_CONTRACTS},
                         EXPECTED_DONOR_CONTRACTS)
        self.assertEqual(set(rpcs3.EXPECTED_HELPERS),
                         {name + '.appex' for name in JIT_TARGETS} | set(EXPECTED_DONOR_CONTRACTS) | set(EXPECTED_RELAY_CONTRACTS))
        with tempfile.TemporaryDirectory() as directory:
            app, host = packaged_helpers(Path(directory))
            result = rpcs3.validate_helper_bundles(app, host, Path(directory))
            self.assertEqual(len(result), 5)
            self.assertEqual(len(set(result.values())), 5)
            for name, suffix, _ in DONOR_IDENTITIES:
                self.assertEqual(result[name + '.appex'], host['CFBundleIdentifier'] + suffix)
            shutil.rmtree(app / 'PlugIns/NeoSwapDonor.appex')
            with self.assertRaisesRegex(rpcs3.ValidationError, 'Unexpected app-extension set'):
                rpcs3.validate_helper_bundles(app, host)

    def test_rpcs3_validator_requires_relay_identity_and_signature(self):
        import validate_rpcs3_ipa as rpcs3
        self.assertEqual({name: rpcs3.EXPECTED_HELPERS[name] for name in EXPECTED_RELAY_CONTRACTS},
                         EXPECTED_RELAY_CONTRACTS)
        changes = (
            ('CFBundleIdentifier', 'com.test.neostation.neoswappagerelay'),
            ('CFBundleVersion', '367'), ('CFBundleShortVersionString', '0.0.1'),
            ('CFBundleExecutable', '../../Runner'), ('NeoStationNeoSwapPageRelay', 1),
            ('MinimumOSVersion', '17.4'), ('XPCService', {}),
        )
        for key, invalid in changes:
            with self.subTest(field=key), tempfile.TemporaryDirectory() as directory:
                app, host = packaged_helpers(Path(directory))
                path = app / 'PlugIns/NeoSwapPageRelay.appex/Info.plist'
                info = plistlib.loads(path.read_bytes()); info[key] = invalid
                path.write_bytes(plistlib.dumps(info))
                with self.assertRaises(rpcs3.ValidationError):
                    rpcs3.validate_helper_bundles(app, host)
        for capabilities in ({}, dict(PUBLIC_CAPABILITIES, **{'get-task-allow': 1}),
                             dict(PUBLIC_CAPABILITIES, **{'com.apple.private.memorystatus': True})):
            with self.subTest(capabilities=capabilities), tempfile.TemporaryDirectory() as directory:
                app, host = packaged_helpers(Path(directory))
                (app / 'PlugIns/NeoSwapPageRelay.appex/NeoSwapPageRelay').write_bytes(signed_macho(capabilities))
                with self.assertRaises((rpcs3.ValidationError, ValueError)):
                    rpcs3.validate_helper_bundles(app, host)
        with tempfile.TemporaryDirectory() as directory:
            app, host = packaged_helpers(Path(directory))
            shutil.rmtree(app / 'PlugIns/NeoSwapPageRelay.appex')
            with self.assertRaisesRegex(rpcs3.ValidationError, 'Unexpected app-extension set'):
                rpcs3.validate_helper_bundles(app, host)

    def test_rpcs3_validator_rejects_wrong_or_non_string_donor_indices(self):
        import validate_rpcs3_ipa as rpcs3
        for name, _, expected in DONOR_IDENTITIES:
            for invalid in (int(expected), True, '1', '$(NEOSWAP_DONOR_INDEX)'):
                with self.subTest(name=name, invalid=invalid), tempfile.TemporaryDirectory() as directory:
                    app, host = packaged_helpers(Path(directory))
                    path = app / 'PlugIns' / (name + '.appex') / 'Info.plist'
                    info = plistlib.loads(path.read_bytes())
                    info['NeoStationNeoSwapDonorIndex'] = invalid
                    path.write_bytes(plistlib.dumps(info))
                    with self.assertRaisesRegex(rpcs3.ValidationError, 'donor index is inconsistent'):
                        rpcs3.validate_helper_bundles(app, host)

    def test_rpcs3_validator_checks_each_donor_identity_versions_and_signature(self):
        import validate_rpcs3_ipa as rpcs3
        from validate_single_ipa_distribution import DistributionError
        mutations = (
            ('CFBundleIdentifier', 'com.foreign.neoswapdonor'),
            ('CFBundleVersion', '367'), ('CFBundleShortVersionString', '0.0.1'),
            ('CFBundleExecutable', '../../Runner'), ('NeoStationNeoSwapDonor', 1),
            ('CFBundlePackageType', 'APPL'), ('MinimumOSVersion', '16.0'),
        )
        for name, _, _ in DONOR_IDENTITIES:
            for key, invalid in mutations:
                with self.subTest(name=name, field=key), tempfile.TemporaryDirectory() as directory:
                    app, host = packaged_helpers(Path(directory))
                    path = app / 'PlugIns' / (name + '.appex') / 'Info.plist'
                    info = plistlib.loads(path.read_bytes())
                    info[key] = invalid
                    path.write_bytes(plistlib.dumps(info))
                    with self.assertRaises(rpcs3.ValidationError):
                        rpcs3.validate_helper_bundles(app, host)
            for capabilities in ({}, {**PUBLIC_CAPABILITIES, 'get-task-allow': 1},
                                 {**PUBLIC_CAPABILITIES, 'com.apple.private.memorystatus': True}):
                with self.subTest(name=name, capabilities=capabilities), tempfile.TemporaryDirectory() as directory:
                    app, host = packaged_helpers(Path(directory))
                    (app / 'PlugIns' / (name + '.appex') / name).write_bytes(signed_macho(capabilities))
                    with self.assertRaises((rpcs3.ValidationError, DistributionError, ValueError)):
                        rpcs3.validate_helper_bundles(app, host)

    def test_rpcs3_validator_rejects_foreign_extension_outside_host(self):
        import validate_rpcs3_ipa as rpcs3
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app, host = packaged_helpers(root)
            extra = app / 'PlugIns/NeoSwapDonor2.appex'
            extra.mkdir()
            with self.assertRaisesRegex(rpcs3.ValidationError, 'Unexpected app-extension set'):
                rpcs3.validate_helper_bundles(app, host, root)
            extra.rmdir()
            (root / 'Foreign.appex').mkdir()
            with self.assertRaisesRegex(rpcs3.ValidationError, 'must be nested'):
                rpcs3.validate_helper_bundles(app, host, root)

    def test_rpcs3_validator_rejects_missing_or_changed_multiple_instance_metadata(self):
        import validate_rpcs3_ipa as rpcs3
        valid = {'ServiceType': 'Application', '_ProcessType': 'App', '_MultipleInstances': True}
        for invalid in (None, {}, {**valid, '_MultipleInstances': False}, {**valid, '_MultipleInstances': 1},
                        {**valid, '_MultipleInstances': 'true'},
                        {**valid, '_ProcessType': 'Background'}, {**valid, 'ForeignService': True}):
            with self.subTest(metadata=invalid), tempfile.TemporaryDirectory() as directory:
                app, host = packaged_helpers(Path(directory))
                path = app / 'PlugIns/NeoSwapDonor.appex/Info.plist'
                info = plistlib.loads(path.read_bytes())
                if invalid is None:
                    info.pop('XPCService')
                else:
                    info['XPCService'] = invalid
                path.write_bytes(plistlib.dumps(info))
                with self.assertRaisesRegex(rpcs3.ValidationError, 'multiple-instance metadata'):
                    rpcs3.validate_helper_bundles(app, host)

    def test_rpcs3_validator_rejects_unconfigured_donor_context(self):
        # The base NSExtensionContext has nil auxiliary interfaces. It cannot
        # accept the listener endpoint used by the production donor launch.
        import validate_rpcs3_ipa as rpcs3
        for invalid in ('NSExtensionContext', 'ForeignContext', ''):
            with self.subTest(context=invalid), tempfile.TemporaryDirectory() as directory:
                app, host = packaged_helpers(Path(directory))
                path = app / 'PlugIns/NeoSwapDonor.appex/Info.plist'
                info = plistlib.loads(path.read_bytes())
                info['NSExtension']['NSExtensionContextClass'] = invalid
                path.write_bytes(plistlib.dumps(info))
                with self.assertRaisesRegex(rpcs3.ValidationError, 'NSExtensionContextClass'):
                    rpcs3.validate_helper_bundles(app, host)

    def test_rpcs3_validator_rejects_extra_or_misplaced_donor_attributes(self):
        import validate_rpcs3_ipa as rpcs3
        for invalid in ({}, {'NSExtensionActivationRule': 'TRUEPREDICATE'},
                        {'NSExtensionActivationRule': 'FALSEPREDICATE', '_MultipleInstances': True},
                        {'NSExtensionActivationRule': 'FALSEPREDICATE', 'ForeignAttribute': True}):
            with self.subTest(attributes=invalid), tempfile.TemporaryDirectory() as directory:
                app, host = packaged_helpers(Path(directory))
                path = app / 'PlugIns/NeoSwapDonor.appex/Info.plist'
                info = plistlib.loads(path.read_bytes())
                info['NSExtension']['NSExtensionAttributes'] = invalid
                path.write_bytes(plistlib.dumps(info))
                with self.assertRaisesRegex(rpcs3.ValidationError, 'activation rule'):
                    rpcs3.validate_helper_bundles(app, host)

    @unittest.skipUnless(sys.platform == 'darwin', 'Apple codesign required')
    def test_actual_donor_signature_contains_exact_requested_capabilities(self):
        with tempfile.TemporaryDirectory(prefix='neoswap-donor-sign-') as directory:
            root = Path(directory)
            source = root / 'main.c'
            source.write_text('int main(void) { return 0; }\n')
            template = root / 'unsigned-template'
            subprocess.run(['xcrun', 'clang', str(source), '-o', str(template)], check=True)
            entitlements = ROOT / 'native/neoswap-donation/NeoSwapDonor.entitlements'
            for name, _, _ in DONOR_IDENTITIES:
                with self.subTest(name=name):
                    executable = root / name
                    shutil.copy2(template, executable)
                    # Compilation alone does not satisfy the capability contract.
                    with self.assertRaises(ValueError):
                        require_entitlements(embedded_entitlements(executable.read_bytes()),
                                             PUBLIC_CAPABILITIES, name)
                    self.assertEqual(embed(executable, entitlements, required=PUBLIC_CAPABILITIES,
                                           owner=name), PUBLIC_CAPABILITIES)
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
            names = [name for name, _, _ in DONOR_IDENTITIES]
            self.assertCountEqual(result['targets'], ['Runner', *JIT_TARGETS, *names])
            self.assertCountEqual(result['embedded'], [name + '.appex' for name in (*JIT_TARGETS, *names)])
            self.assertCountEqual(result['dependencies'], [*JIT_TARGETS, *names])
            self.assertEqual(set(result['donorConfigurations']), set(names))
            self.assertEqual(set(result['donorSources']), set(names))
            for name, suffix, index in DONOR_IDENTITIES:
                self.assertCountEqual(result['donorSources'][name], donor.DONOR_SOURCES)
                self.assertTrue(result['donorConfigurations'][name])
                for settings in result['donorConfigurations'][name]:
                    self.assertEqual(settings['PRODUCT_BUNDLE_IDENTIFIER'], 'com.test.neostation' + suffix)
                    self.assertEqual(settings['NEOSWAP_DONOR_INDEX'], index)
                    self.assertIsInstance(settings['NEOSWAP_DONOR_INDEX'], str)
                    self.assertEqual(settings['CURRENT_PROJECT_VERSION'], '368')
                    self.assertEqual(settings['MARKETING_VERSION'], '0.0.2')
                    self.assertEqual(settings['CODE_SIGN_ENTITLEMENTS'], name + '/NeoSwapDonor.entitlements')
                    self.assertEqual(settings['INFOPLIST_FILE'], name + '/Info.plist')
                    self.assertEqual(settings['APPLICATION_EXTENSION_API_ONLY'], 'YES')
                    self.assertEqual(settings['IPHONEOS_DEPLOYMENT_TARGET'], '17.4')


if __name__ == '__main__':
    unittest.main(verbosity=2)
