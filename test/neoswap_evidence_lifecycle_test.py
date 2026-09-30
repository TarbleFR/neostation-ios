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
    ))
]
assert len(copy_commands) == 3
sha = 'd' * 40
WORKFLOW_IDS = {
    'neoswap-check.yml': 101,
    'neoswap-donation-check.yml': 102,
    'dolphin-pacing-check.yml': 103,
    'dolphin-motion-check.yml': 104,
    'cheats-media-check.yml': 105,
}
report = {'platform': 'macOS host', 'verifiedBytes': 8589934592,
          'footprintBefore': 1049280, 'footprintPeak': 5325504,
          'realIPhoneValidated': False}
motion_report = {'productionSwiftExecuted': True, 'sensor': 'mocked',
                 'realDeviceValidated': False, 'result': 'native test evidence'}
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
retained_commands = [
    ['python3', 'test/stikjit_scoped_host_test.py'],
    ['python3', 'test/dolphin_phone_shake_test.py'],
    ['python3', 'test/dolphin_phone_shake_routing_test.py'],
]


def exercise(*, bad_source=None, bad_device_claim=None, failed_phase=None, export=False):
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
        runner_temp = base / 'runner-temp'
        runner_temp.mkdir()
        environment = dict(os.environ, GITHUB_SHA=sha, RUNNER_TEMP=str(runner_temp), GITHUB_WORKSPACE=str(ROOT))
        previous = Path.cwd()
        try:
            os.chdir(checkout)
            with patch.dict(os.environ, environment), patch.object(subprocess, 'check_output', api), patch.object(subprocess, 'run', run):
                exec(compile(script, '.github/workflows/neoswap-ipa.yml', 'exec'), {})
            assert api_workflows == list(WORKFLOW_IDS), 'All five exact-SHA gates must execute'
            assert executed_commands[-3:] == retained_commands
            assert len([command for command in executed_commands if command[:3] == ['gh', 'run', 'download']]) == 5
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
for phase in donation_reports:
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

print('PASS: five actual exact-SHA gates and all three donation evidence exports survive Flutter clean; '
      'wrong source/failed phase/device claims rejected for each phase; runtime proofs are mocked here')
