"""Public C boundary/materialization and strict negative evidence contracts."""
import copy
import hashlib
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'build-utils'))
from configure_neoswap_storage import materialize
from validate_managed_swap_evidence import REQUIRED_INPUTS, validate

materialize()
public = ROOT / 'packages/neo_swap/ios/Classes/ManagedSwapABI.h'
assert public.read_bytes() == (ROOT / 'native/neoswap-storage/ManagedSwapABI.h').read_bytes()
assert "'Classes/ManagedSwapABI.h'" in (ROOT / 'packages/neo_swap/ios/neo_swap.podspec').read_text()
compiler = shutil.which('clang') or shutil.which('cc')
assert compiler, 'A real C compiler is required'
with tempfile.TemporaryDirectory(prefix='managed-public-header-') as directory:
    probe = Path(directory) / 'public.c'
    probe.write_text('#include "ManagedSwapABI.h"\n#include "StorageABI.h"\n'
                     '_Static_assert(NEOSWAP_MANAGED_ABI_VERSION == 1, "managed ABI");\n'
                     '_Static_assert(NEOSWAP_STORAGE_ABI == 1, "shader ABI unchanged");\n')
    subprocess.run([compiler, '-std=c11', '-Wall', '-Wextra', '-Werror', '-fsyntax-only',
                    '-I', str(public.parent), str(probe)], check=True)

# These fixtures verify the evidence gate, not memory or hardware behavior.
fixture = {
    'schema': 1, 'passed': True, 'sourceCommit': 'a' * 40,
    'physicalIPhoneValidated': False, 'realRPCS3GameplayValidated': False,
    'kernelSwapPorted': False, 'automaticGuestPagingActivated': False,
    'iosARM64Linked': True, 'swiftInteropExecuted': True, 'swiftIOSInteropTypechecked': True,
    'sanitizers': {'address': True, 'undefined': True},
    'core': {
        'passed': True, 'byteIdentityVerified': True, 'ramStorageRamCycleVerified': True,
        'logicalTouchedBytes': 64 * 1024**2, 'releasedOwnedBytes': 64 * 1024**2,
        'restoredBytes': 64 * 1024**2, 'diskReadBytes': 64 * 1024**2,
        'diskWriteBytes': 64 * 1024**2, 'residentAfterEvictionBytes': 0,
        'managedMappedPeakBytes': 2 * 1024**2, 'managedMappedLimitBytes': 8 * 1024**2,
        'leaseAfterClose': True, 'pressurePreservesDirtyAndPinned': True,
        'boundedBackpressureRetryVerified': True,
        'faultCases': {field: True for field in ('write', 'sync', 'read', 'corrupt', 'truncate', 'quota', 'allocationException')},
    },
    'abi': {field: True for field in ('passed', 'cABIExecuted', 'contentVerified',
                                    'leaseAfterContextDestroy', 'staleGenerationRejected', 'invalidArgumentsRejected')},
    'swift': {field: True for field in ('passed', 'swiftABIExecuted', 'restoredContentVerified', 'leaseAfterContextDestroy')},
    'inputSHA256': {path: hashlib.sha256((ROOT / path).read_bytes()).hexdigest() for path in REQUIRED_INPUTS},
}
validate(fixture, 'a' * 40)

def rejects(report):
    try:
        validate(report, 'a' * 40)
    except AssertionError:
        return
    raise AssertionError('Accepted incomplete or wrong owned-swap evidence')

for field in ('passed', 'iosARM64Linked', 'swiftInteropExecuted', 'swiftIOSInteropTypechecked'):
    bad = copy.deepcopy(fixture)
    bad[field] = False
    rejects(bad)
for field in ('physicalIPhoneValidated', 'kernelSwapPorted', 'automaticGuestPagingActivated'):
    bad = copy.deepcopy(fixture)
    bad[field] = True
    rejects(bad)
for field, value in (('diskReadBytes', 0), ('releasedOwnedBytes', 0), ('restoredBytes', 0),
                     ('residentAfterEvictionBytes', 1), ('managedMappedPeakBytes', 9 * 1024**2),
                     ('boundedBackpressureRetryVerified', False)):
    bad = copy.deepcopy(fixture)
    bad['core'][field] = value
    rejects(bad)
for field in ('write', 'sync', 'read', 'corrupt', 'truncate', 'quota', 'allocationException'):
    bad = copy.deepcopy(fixture)
    bad['core']['faultCases'][field] = False
    rejects(bad)
for section, fields in (
        ('core', ('passed', 'byteIdentityVerified', 'ramStorageRamCycleVerified',
                  'leaseAfterClose', 'pressurePreservesDirtyAndPinned',
                  'boundedBackpressureRetryVerified')),
        ('swift', ('passed', 'swiftABIExecuted', 'restoredContentVerified',
                   'leaseAfterContextDestroy')),
        ('sanitizers', ('address', 'undefined'))):
    for field in fields:
        for value in ('false', 1):
            bad = copy.deepcopy(fixture)
            bad[section][field] = value
            rejects(bad)
bad = copy.deepcopy(fixture)
bad['sourceCommit'] = 'b' * 40
rejects(bad)
bad = copy.deepcopy(fixture)
bad['inputSHA256'].pop('native/neoswap-storage/ManagedSwap.cpp')
rejects(bad)
workflow = (ROOT / '.github/workflows/neoswap-storage-prototype.yml').read_text()
assert 'run_managed_validation.py' in workflow and '--ios-sdk' in workflow
packaging = (ROOT / '.github/workflows/neoswap-ipa.yml').read_text()
assert 'managed-swap.json' in packaging and 'validate_managed(managed,sha)' in packaging
assert packaging.index('validate_managed(managed,sha)') < packaging.index('Package and validate NeoStation IPA')
print('PASS public C ABI/canonical host copies and strict owned-swap SDK/Swift/source evidence refusal')
