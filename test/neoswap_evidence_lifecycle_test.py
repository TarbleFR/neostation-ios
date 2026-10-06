"""Execute the actual exact-SHA evidence producer/export across Flutter cleanup.

CI downloads are explicit fixtures; this tests the workflow contract, not real
memory donation, Simulator execution or physical iPhone validation.
"""
import copy
from contextlib import redirect_stdout
import io
import json
import hashlib
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import textwrap
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
workflow = (ROOT / '.github/workflows/neoswap-ipa.yml').read_text()
gate = workflow.split('- name: Require exact import, memory donation and retained simulator checks before compilation', 1)[1].split('\n      - name:', 1)[0]
script = textwrap.dedent(re.search(r"python3 - <<'PY'\n(.*?)\n          PY", gate, re.S).group(1))
copy_commands = [
    line.strip() for line in workflow.splitlines()
    if line.strip().startswith('cp ') and any(name in line for name in (
        'capacity-8GiB-macOS.json', 'phone-shake-tests.json',
        'neoswap-evidence/donation"',
        'neoswap-evidence/vulkan"',
        'neoswap-evidence/relay"',
    ))
]
assert len(copy_commands) == 5
sha = 'd' * 40
WORKFLOW_IDS = {
    'neoswap-check.yml': 101,
    'neoswap-donation-check.yml': 102,
    'neoswap-vulkan-proof.yml': 106,
    'neoswap-relay-check.yml': 107,
    'dolphin-pacing-check.yml': 103,
    'dolphin-motion-check.yml': 104,
    'cheats-media-check.yml': 105,
}
report = {'platform': 'macOS host', 'verifiedBytes': 8589934592,
          'footprintBefore': 1049280, 'footprintPeak': 5325504,
          'realIPhoneValidated': False}
motion_report = {'productionSwiftExecuted': True, 'sensor': 'mocked',
                 'realDeviceValidated': False, 'result': 'native test evidence'}
canonical = json.loads((ROOT/'build-utils/rpcs3/canonical-source.json').read_text())
vulkan_input = 'native/neoswap-donation/VulkanDonationProbe.h'
vulkan_identity = {
    'source': sha, 'moltenVK': '1.4.2',
    'moltenVKSHA256': 'f95765a6229cb7b915990a2890ce12ebe36a730b021545d3d52ae69ce4c4024e',
    'canonicalPatchSHA256': canonical['patch_sha256'],
    'productionImportSHA256': canonical['files_sha256']['rpcs3/ios/NeoSwapVulkanBuffer.h'],
    'inputsSHA256': {vulkan_input: hashlib.sha256((ROOT/vulkan_input).read_bytes()).hexdigest()},
}
vulkan_report = {
    'passed': True, 'residentTargetVerified': True, 'hostPID': 501, 'donorPID': 502,
    'donorResidentBytes': 134217728,
    'vulkanDonation': {
        'passed': True, 'importedBytes': 134217728, 'donatedLiveBytesDuringGPU': 134217728,
        'gpuWrittenBytes': 134217728, 'gpuToCpuAliasVerified': True, 'retiredLiveBytes': 0,
        'rendererBudgetDuringGPU': 134217728, 'rendererBudgetAfterRetirement': 0,
        'productionRPCS3ImportPath': True, 'productionHostBroker': True,
        'hostNonvolatileDeltaBytes': 0, 'hostFootprintDeltaBytes': 2*1024**2,
        'realIPhoneValidated': False, 'realRPCS3GameplayValidated': False,
    },
}
donation_reports = {
    'kernel': {'passed': True, 'platform': 'macOS-kernel-two-process',
               'source': sha, 'realIPhoneValidated': False,
               'ledgers': [{'pid': 501, 'physical': 4096, 'nonvolatile': 4096}] * 6},
    'ipc': {'schema': 2, 'passed': True, 'platform': 'macOS-NSXPC-two-process',
            'iphoneExtensionValidated': False, 'hostPID': 501, 'donorPID': 502,
            'capacityBytes': 128 * 1024 * 1024, 'donorResidentBytes': 128 * 1024 * 1024,
            'donorCompressedBytes': 0, 'hostNonvolatileDelta': 0,
            'verifiedChunkCount': 2, 'distinctChunkRights': True, 'priorBorrowedDataPreserved': True,
            'machHandleCleanupRetried': True,
            'rejectedArchive': True, 'rejectedScenarios': [
                {'scenario': name, 'rejected': True}
                for name in ('BadNonceSession', 'BadGenerationSession', 'WaitOnlySession', 'LateSession')
            ]},
    'simulator': {'schema': 2, 'passed': True, 'platform': 'iOS18Simulator',
                  'transport': 'real-NSExtension-auxiliary-NSXPC',
                  'realIPhoneValidated': False, 'physicalIphoneValidated': False,
                  'hostPID': 501, 'donorCount': 2, 'capacityBytes': 64 * 1024 * 1024,
                  'donorResidentBytes': 64 * 1024 * 1024, 'donorCompressedBytes': 0,
                  'abiVersion': 1, 'realDonationLoanBytes': 64 * 1024 * 1024, 'donationDiskBytes': 0,
                  'verifiedChunkCount': 4,
                  'donorBundleCount': 1, 'requestCount': 2,
                  'rpcs3DonatedLiveBytes': 64*1024*1024, 'rpcs3LiveBytes': 64*1024*1024,
                  'retainedDataAfterClose': True, 'newLoansBlockedAfterClose': True,
                  'survivingDonorNewLoanPassed': True, 'explicitFileFallbackPassed': True,
                  'releasePassed': True, 'kernelMappingCleanupPassed': True,
                  'unverifiedDonorErrorRetained': True, 'lateDonorSessionIgnored': True,
                  'verifiedDonorErrorCleared': True, 'currentDonorErrorRetained': True,
                  'closedDonorErrorRetained': True,
                  'donors': [
                      {'helperIdentifier': 'com.neogamelab.neostation.neoswap-simulator-proof.neoswapdonor',
                       'helperIndex': '0', 'poolIndex': i, 'pid': 502+i,
                       'generation': 100+i, 'capacityBytes': 32*1024*1024,
                       'residentBytes': 32*1024*1024, 'compressedBytes': 0, 'verifiedChunkCount': 2,
                       'chunks': [{'index': j, 'capacityBytes': 16*1024*1024} for j in range(2)]}
                      for i in range(2)
                  ],
                  'sourceSHA256': {'native/neoswap-donation/Broker.cpp': hashlib.sha256(
                      (ROOT/'native/neoswap-donation/Broker.cpp').read_bytes()).hexdigest()}},
    'stress': {'schema': 2, 'passed': False, 'platform': 'macOS-NSXPC-two-process',
               'iphoneExtensionValidated': False, 'targetBytes': 8589934592,
               'stage': 'stress_system_headroom_guard', 'preparedBytes': 0,
               'technicalError': 'Fixture runner lacks the measured headroom for 8 GiB; no donation claimed'},
}
# Fixtures exercise exact-SHA artifact handling only. The native workflow must
# independently produce these counters before any candidate IPA can build.
relay_inputs = list((ROOT/'native/neoswap-relay').glob('*')) + [ROOT/path for path in (
    'packages/neo_swap/ios/Classes/NeoSwapRelay.h',
    'packages/neo_swap/ios/Classes/NeoSwapRelayService.h',
    'packages/neo_swap/ios/Classes/NeoSwapRelayService.mm',
    'build-utils/configure_neoswap_relay.py','test/relay_backend_test.cpp',
    'test/neoswap_relay_extension_test.py','test/neoswap_relay_simulator_test.py',
    '.github/workflows/neoswap-relay-check.yml')]
relay_identity = {'schema':1, 'source':sha, 'realIPhoneValidated':False,
    'realRPCS3GameplayValidated':False, 'macOSWrittenTargetBytes':1024**3,
    'simulatorWrittenTargetBytes':32*1024**2, 'productionManagerCapacityTargetBytes':8*1024**3,
    'macOSCapacityTargetBytes':8*1024**3, 'macOSCapacitySampleWrittenTargetBytes':1024**2,
    'inputsSHA256':{str(path.relative_to(ROOT)):hashlib.sha256(path.read_bytes()).hexdigest()
                   for path in relay_inputs if path.is_file()}}
relay_native = {'schema':1, 'passed':True, 'platform':'macOS-real-NSXPC-creator-exit',
    'iphoneExtensionValidated':False, 'realRPCS3GameValidated':False, 'hostPID':501,
    'creatorPID':510, 'creatorExitObserved':True, 'aliasesMatched':True,
    'capacityBytes':1024**3, 'actualWrittenBytes':1024**3, 'residentBytesMeasured':1024**3,
    'hostFootprintDelta':1024**2, 'hostNonvolatileDelta':0, 'reservedVirtualBytesClaimedAsRAM':0,
    'liveBytesAfterRelease':0, 'aliasesAfterRelease':0, 'reusedIntervalZeroed':True,
    'relaunchSucceeded':True, 'negativeScenarios':[{'passed':True} for _ in range(5)]}
relay_native['capacity8GiB'] = {'passed':True, 'requestedCapacityBytes':8*1024**3,
    'capacityBytes':8*1024**3, 'entryCount':16, 'segmentBytes':512*1024**2,
    'creatorExitObserved':True, 'actualWrittenBytes':1024**2, 'perSegmentWrittenBytes':65536,
    'aliasesMatched':True, 'residentBytesForSample':1024**2, 'fullCapacityResidentValidated':False,
    'liveBytesAfterRelease':0, 'retainedBytesAfterShutdown':0}
relay_preflight = {'hostLauncherAbsentFromExtension':True,
                  'sourceSHA256':relay_identity['inputsSHA256']}
relay_arm64 = {'source':sha, 'passed':True, 'platform':'iOS18-arm64-compile-only',
    'realIPhoneValidated':False, 'realRPCS3GameplayValidated':False,
    'buildPreflight':{**relay_preflight, 'deviceArm64Linked':True}}
relay_simulator = {'schema':1, 'platform':'iOS18Simulator', 'passed':True,
    'source':sha, 'buildPreflight':relay_preflight,
    'transport':'real-NSExtension-auxiliary-NSXPC', 'realIPhoneValidated':False,
    'realRPCS3GameplayValidated':False, 'hostPID':51, 'creatorPID':67,
    'creatorExitObserved':True, 'capacityBytes':32*1024**2,
    'writtenBytes':32*1024**2, 'aliasCountDuringUse':2,
    'liveBytesDuringUse':32*1024**2, 'aliasedBytesDuringUse':64*1024**2,
    'retainedBytesAfterRelease':32*1024**2, 'liveBytesAfterRelease':0,
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
    'productionManagerWrittenBytes':32*1024**2,
    'productionManager':{'ready':True, 'creatorExitObserved':True, 'state':'ready',
        'capacityBytes':8*1024**3, 'residentBytes':None, 'liveBackingBytes':0,
        'objectCount':0, 'aliasCount':0, 'pendingCleanupEntries':0,
        'capabilityCheck':{'kind':'post_creator_exit_cpu_capability_check',
            'requestedBytes':16*1024**2, 'aliasDataVerified':True, 'result':0,
            'cleanupResult':0, 'gameplayValidated':False, 'hostFootprintBeforeBytes':100000,
            'hostFootprintAfterBytes':200000, 'hostFootprintDeltaBytes':100000}}}
retained_commands = [
    ['python3', 'test/stikjit_scoped_host_test.py'],
    ['python3', 'test/dolphin_phone_shake_test.py'],
    ['python3', 'test/dolphin_phone_shake_routing_test.py'],
]


def exercise(*, bad_source=None, bad_device_claim=None, failed_phase=None, export=False,
             bad_vulkan_digest=False, bad_vulkan_lifetime=False, bad_vulkan_charge=False,
             bad_relay_digest=False, bad_relay_exit=False, bad_relay_simulator=False, bad_relay_arm64=False,
             bad_relay_capacity=False, false_relay_resident_claim=False):
    api_workflows, executed_commands = [], []

    def api(command):
        assert command[:2] == ['gh', 'api']
        endpoint = command[2]
        assert 'head_sha=' + sha in endpoint
        name = endpoint.split('/workflows/', 1)[1].split('/runs?', 1)[0]
        assert name in WORKFLOW_IDS, 'Unexpected prerequisite workflow'
        api_workflows.append(name)
        return json.dumps({'workflow_runs': [{'head_sha': sha, 'status': 'completed',
                          'conclusion': 'success', 'id': WORKFLOW_IDS[name]}]}).encode()

    def run(command, *, check):
        assert check is True
        executed_commands.append(command)
        if command[:3] == ['gh', 'run', 'download']:
            artifact = command[command.index('-n') + 1]
            destination = Path(command[command.index('-D') + 1])
            destination.mkdir(parents=True, exist_ok=True)
            if artifact == 'NeoSwap-checks-' + sha:
                assert command[3] == str(WORKFLOW_IDS['neoswap-check.yml'])
                assert destination.name == 'neoswap-evidence'
                (destination / 'capacity-8GiB-macOS.txt').write_text(json.dumps(report) + '\n')
            elif artifact == 'NeoSwap-Vulkan-' + sha:
                assert command[3] == str(WORKFLOW_IDS['neoswap-vulkan-proof.yml'])
                assert destination.parts[-2:] == ('neoswap-evidence', 'vulkan')
                identity = copy.deepcopy(vulkan_identity)
                fixture = copy.deepcopy(vulkan_report)
                if bad_source == 'vulkan': identity['source'] = 'c'*40
                if failed_phase == 'vulkan': fixture['vulkanDonation']['passed'] = False
                if bad_device_claim == 'vulkan': fixture['vulkanDonation']['realIPhoneValidated'] = True
                if bad_vulkan_digest: identity['productionImportSHA256'] = 'b'*64
                if bad_vulkan_lifetime: fixture['vulkanDonation']['retiredLiveBytes'] = 4096
                if bad_vulkan_charge: fixture['vulkanDonation']['hostNonvolatileDeltaBytes'] = 134217728
                (destination/'identity.json').write_text(json.dumps(identity))
                (destination/'report.json').write_text(json.dumps(fixture))
            elif artifact == 'NeoSwap-Relay-' + sha:
                assert command[3] == str(WORKFLOW_IDS['neoswap-relay-check.yml'])
                assert destination.parts[-2:] == ('neoswap-evidence','relay')
                identity = copy.deepcopy(relay_identity)
                native = copy.deepcopy(relay_native)
                simulator = copy.deepcopy(relay_simulator)
                arm64 = copy.deepcopy(relay_arm64)
                if bad_source == 'relay': identity['source'] = 'c'*40
                if failed_phase == 'relay': native['passed'] = False
                if bad_device_claim == 'relay': identity['realIPhoneValidated'] = True
                if bad_relay_digest: identity['inputsSHA256']['native/neoswap-relay/Backend.cpp'] = 'a'*64
                if bad_relay_exit: native['creatorExitObserved'] = False
                if bad_relay_simulator: simulator['secondPreparationPassed'] = False
                if bad_relay_arm64: arm64['buildPreflight']['deviceArm64Linked'] = False
                if bad_relay_capacity: native['capacity8GiB']['capacityBytes'] = 1024**3
                if false_relay_resident_claim: native['capacity8GiB']['fullCapacityResidentValidated'] = True
                for relative, value in (('identity.json',identity),('macos/report.json',native),
                                        ('simulator/report.json',simulator),('simulator/arm64-report.json',arm64)):
                    path = destination/relative
                    path.parent.mkdir(exist_ok=True)
                    path.write_text(json.dumps(value))
            else:
                phase = next((name for name in donation_reports
                              if artifact == 'NeoSwap-donation-' + name + '-' + sha), None)
                assert phase is not None, 'Unexpected donation artifact'
                assert command[3] == str(WORKFLOW_IDS['neoswap-donation-check.yml'])
                assert destination.parts[-3:] == ('neoswap-evidence', 'donation', phase)
                (destination / 'source.txt').write_text(('c' * 40 if bad_source == phase else sha) + '\n')
                fixture = copy.deepcopy(donation_reports[phase])
                if failed_phase == phase:
                    fixture['passed'] = False
                if bad_device_claim == phase:
                    fixture['iphoneExtensionValidated' if phase in ('ipc','stress') else 'realIPhoneValidated'] = True
                (destination / 'report.json').write_text(json.dumps(fixture))
        else:
            assert command in retained_commands, 'Unexpected independent verification command'
            if command[-1] == 'test/dolphin_phone_shake_test.py':
                destination = Path('build/dolphin-motion/tests.json')
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_text(json.dumps(motion_report))
        return subprocess.CompletedProcess(command, 0)

    with tempfile.TemporaryDirectory() as temporary:
        base = Path(temporary)
        checkout = base / 'checkout'
        checkout.mkdir()
        for relative in ('build-utils/rpcs3/canonical-source.json', vulkan_input):
            destination = checkout/relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT/relative, destination)
        runner_temp = base / 'runner-temp'
        runner_temp.mkdir()
        environment = dict(os.environ, GITHUB_SHA=sha, RUNNER_TEMP=str(runner_temp), GITHUB_WORKSPACE=str(ROOT))
        previous = Path.cwd()
        try:
            os.chdir(checkout)
            with patch.dict(os.environ, environment), patch.object(subprocess, 'check_output', api), patch.object(subprocess, 'run', run):
                exec(compile(script, '.github/workflows/neoswap-ipa.yml', 'exec'), {})
            assert api_workflows == list(WORKFLOW_IDS), 'All seven exact-SHA gates must execute'
            assert executed_commands[-3:] == retained_commands
            assert len([command for command in executed_commands if command[:3] == ['gh', 'run', 'download']]) == 7
            if export:
                # Flutter clean removes build/ after the producer. Execute the
                # actual export commands extracted from the workflow afterward.
                (checkout / 'build').mkdir(exist_ok=True)
                shutil.rmtree(checkout / 'build')
                (checkout / 'build/private-test').mkdir(parents=True)
                for command in copy_commands:
                    subprocess.run(['bash', '-c', command], check=True, env=environment)
                exported = checkout / 'build/private-test'
                assert json.loads((exported / 'capacity-8GiB-macOS.json').read_text()) == report
                assert json.loads((exported / 'phone-shake-tests.json').read_text()) == motion_report
                assert json.loads((exported/'vulkan-evidence/report.json').read_text()) == vulkan_report
                assert json.loads((exported/'vulkan-evidence/identity.json').read_text()) == vulkan_identity
                assert json.loads((exported/'relay-evidence/identity.json').read_text()) == relay_identity
                assert json.loads((exported/'relay-evidence/macos/report.json').read_text()) == relay_native
                assert json.loads((exported/'relay-evidence/simulator/report.json').read_text()) == relay_simulator
                assert json.loads((exported/'relay-evidence/simulator/arm64-report.json').read_text()) == relay_arm64
                donation = exported / 'donation-evidence'
                for phase, expected in donation_reports.items():
                    assert (donation / phase / 'source.txt').read_text().strip() == sha
                    assert json.loads((donation / phase / 'report.json').read_text()) == expected
                assert json.loads((donation / 'identity.json').read_text()) == {
                    'source': sha, 'realIPhoneValidated': False,
                    'validatedPlatforms': ['macOS kernel', 'macOS NSXPC', 'iOS18Simulator'],
                }
        finally:
            os.chdir(previous)


exercise(export=True)
for phase in [*donation_reports, 'vulkan', 'relay']:
    for argument in ('bad_source', 'bad_device_claim', 'failed_phase'):
        if phase == 'stress' and argument == 'failed_phase':
            continue  # An explicit stress refusal is retained, never counted as 8 GiB.
        try:
            with redirect_stdout(io.StringIO()):
                exercise(**{argument: phase})
        except (AssertionError, RuntimeError):
            pass
        else:
            raise AssertionError('Actual workflow accepted invalid ' + argument + ' in ' + phase)

for argument in ('bad_vulkan_digest', 'bad_vulkan_lifetime', 'bad_vulkan_charge',
                 'bad_relay_digest', 'bad_relay_exit', 'bad_relay_simulator', 'bad_relay_arm64',
                 'bad_relay_capacity', 'false_relay_resident_claim'):
    try:
        with redirect_stdout(io.StringIO()): exercise(**{argument: True})
    except (AssertionError, RuntimeError):
        pass
    else:
        raise AssertionError('Actual workflow accepted invalid '+argument)

print('PASS: seven actual exact-SHA gates and all five evidence exports survive Flutter clean; '
      'wrong source/failed phase/device claims rejected; Vulkan source/lifetime/host-charge and relay source/exit/Simulator/arm64 refusals; runtime proofs are mocked here')
