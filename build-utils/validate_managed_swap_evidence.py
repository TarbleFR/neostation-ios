#!/usr/bin/env python3
"""Require exact owned-swap source and executed native/Swift/SDK evidence."""
import hashlib
import json
import os
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
REQUIRED_INPUTS = frozenset({
    'native/neoswap-storage/Store.cpp', 'native/neoswap-storage/Store.h',
    'native/neoswap-storage/Metrics.cpp',
    'native/neoswap-storage/ManagedSwap.cpp', 'native/neoswap-storage/ManagedSwap.h',
    'native/neoswap-storage/ManagedSwapABI.cpp', 'native/neoswap-storage/ManagedSwapABI.h',
    'native/neoswap-storage/StorageABI.h',
    'native/neoswap-storage/run_managed_validation.py', 'native/neoswap-storage/run_validation.py',
    'native/neoswap-storage/tests/managed_swap_test.cpp',
    'native/neoswap-storage/tests/managed_swap_abi_test.cpp',
    'native/neoswap-storage/tests/managed_swap_swift_test.swift',
    'build-utils/configure_neoswap_storage.py', 'build-utils/validate_managed_swap_evidence.py',
    'packages/neo_swap/ios/Classes/ManagedSwapABI.h',
    'packages/neo_swap/ios/Classes/StorageABI.h',
    'packages/neo_swap/ios/neo_swap.podspec',
    '.github/workflows/neoswap-storage-prototype.yml',
})


def validate(report, sha, root=ROOT, require_apple=True):
    assert report['schema'] == 1 and report['passed'] is True
    assert report['sourceCommit'] == sha, 'Wrong candidate revision'
    for field in ('physicalIPhoneValidated', 'realRPCS3GameplayValidated',
                  'kernelSwapPorted', 'automaticGuestPagingActivated'):
        assert report[field] is False, field
    core = report['core']
    for field in ('passed', 'byteIdentityVerified', 'ramStorageRamCycleVerified',
                  'leaseAfterClose', 'pressurePreservesDirtyAndPinned',
                  'boundedBackpressureRetryVerified'):
        assert core[field] is True, field
    assert core['logicalTouchedBytes'] >= 64 * 1024**2
    assert core['releasedOwnedBytes'] >= core['logicalTouchedBytes']
    assert core['restoredBytes'] >= core['logicalTouchedBytes']
    assert core['diskReadBytes'] > 0 and core['diskWriteBytes'] > 0
    assert core['residentAfterEvictionBytes'] == 0
    assert 0 < core['managedMappedPeakBytes'] <= core['managedMappedLimitBytes']
    for field in ('write', 'sync', 'read', 'corrupt', 'truncate', 'quota', 'allocationException'):
        assert core['faultCases'][field] is True, field
    abi = report['abi']
    for field in ('passed', 'cABIExecuted', 'contentVerified', 'leaseAfterContextDestroy',
                  'staleGenerationRejected', 'invalidArgumentsRejected'):
        assert abi[field] is True, field
    for field in ('address', 'undefined'):
        assert report['sanitizers'][field] is True, field
    if require_apple:
        for field in ('iosARM64Linked', 'swiftInteropExecuted', 'swiftIOSInteropTypechecked'):
            assert report[field] is True, field
        swift = report['swift']
        for field in ('passed', 'swiftABIExecuted', 'restoredContentVerified',
                      'leaseAfterContextDestroy'):
            assert swift[field] is True, field
    assert set(report['inputSHA256']) == REQUIRED_INPUTS, 'Incomplete/extraneous input identity'
    for path, expected in report['inputSHA256'].items():
        assert hashlib.sha256((root / path).read_bytes()).hexdigest() == expected, path


if __name__ == '__main__':
    import sys
    validate(json.loads(Path(sys.argv[1]).read_text()), os.environ['GITHUB_SHA'])
    print('PASS exact owned CPU swap, C/Swift lifetime and iOS SDK proof; no gameplay inference')
