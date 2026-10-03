#!/usr/bin/env python3
"""Reject incomplete or wrong-source owned GLSL/pixel archive evidence."""
import hashlib
import json
from pathlib import Path
import sys
ROOT=Path(__file__).resolve().parents[1]
REQUIRED_INPUTS=frozenset({
    'native/neoswap-storage/Store.cpp','native/neoswap-storage/Store.h',
    'native/neoswap-storage/ManagedSwap.cpp','native/neoswap-storage/ManagedSwap.h',
    'native/neoswap-storage/SourceArchive.cpp','native/neoswap-storage/SourceArchive.h',
    'native/neoswap-storage/SourceABI.h','native/neoswap-storage/SourceClient.h',
    'native/neoswap-storage/SourceClient.cpp',
    'native/neoswap-storage/FrameClient.h',
    'native/neoswap-storage/Metrics.cpp',
    'native/neoswap-storage/tests/source_archive_test.cpp',
    'native/neoswap-storage/tests/frame_archive_test.cpp',
    'native/neoswap-storage/tests/source_work_test.cpp',
    'native/neoswap-storage/run_source_validation.py',
    'build-utils/validate_source_archive_evidence.py',
    'build-utils/configure_neoswap_storage.py',
    'packages/neo_swap/ios/Classes/SourceABI.h',
    'packages/neo_swap/ios/Classes/NeoSwapStorageService.h',
    'packages/neo_swap/ios/Classes/NeoSwapStorageService.mm',
    'packages/neo_swap/ios/Classes/NeoSwapSourceWork.h',
    'packages/neo_swap/ios/neo_swap.podspec',
    'packages/rpcs3_internal_bridge/ios/Classes/Rpcs3InternalBridgePlugin.mm',
    'build-utils/rpcs3/canonical-source.json','build-utils/rpcs3/embedded-core.patch',
    'test/rpcs3_source_archive_test.py','test/native/rpcs3_source_archive_client_test.cpp',
    'test/neoswap_source_work_test.py',
    'test/neoswap_source_archive_host_test.py',
})
def validate(report,commit,require_apple=False):
    assert report['schema']==1 and report['sourceCommit']==commit
    assert report['passed'] is True
    for field in ('physicalIPhoneValidated','realRPCS3GameplayValidated','kernelSwapPorted','automaticGuestPagingActivated'):
        assert report[field] is False,field
    assert report['sanitizers']=={'address':True,'undefined':True}
    core=report['core']
    for field in ('passed','coreClientExecuted','ramStorageRamCycleVerified','byteIdentityVerified','admissionNoDiskIO',
                  'pressureAndQuotaVerified','persistenceFailureRetainsSnapshot','failedRestoreClearsOutput',
                  'staleEpochRejected','sharedRetirementVerified'):
        assert core[field] is True,field
    assert core['logicalTouchedBytes']>=64*1024**2 and core['restoredBytes']>=core['logicalTouchedBytes']
    assert core['coreReleasedCapacityBytes']>=core['logicalTouchedBytes']
    assert 0<core['stagingPeakBytes']<=core['stagingLimitBytes']==4*1024**2
    assert 0<core['managedMappedPeakBytes']<=core['managedMappedLimitBytes']==8*1024**2
    assert core['diskReadBytes']>0 and core['diskWriteBytes']>0
    assert report['c11HeaderVerified'] is True
    frames=report['frames']
    for field in ('passed','softwarePixelBytesSimulated','byteIdentityVerified','transactionalAdmissionVerified',
                  'partialRestoreNeverConsumed','oldHostFallbackVerified','warmAndReferencedPixelsRetained',
                  'throttledProgressResumed'):
        assert frames[field] is True,field
    for field in ('realDecoderExecuted','physicalIPhoneValidated','gameplayValidated'):
        assert frames[field] is False,field
    assert frames['logicalPixelBytes']>=48*1280*720*3//2
    assert frames['returnedPixelBytes']==frames['logicalPixelBytes']
    assert 0<frames['stagingPeakBytes']<=4*1024**2
    work=report['sourceWork']
    for field in ('passed','actualPrivateFileCheckpointAndRestore','wholeRecordFifoBacklogReproduced',
                  'demandPrecedesContinuation','maintenanceCoalesced','ramDemandNoDiskIO',
                  'partialQuantumRetainsFullSnapshot','pressureResumeExact','invalidMemoryFailsClosed'):
        assert work[field] is True,field
    for field in ('physicalIPhoneValidated','realRPCS3GameplayValidated'):
        assert work[field] is False,field
    if require_apple:assert report['platform']=='Darwin'
    expected={path:hashlib.sha256((ROOT/path).read_bytes()).hexdigest() for path in sorted(REQUIRED_INPUTS)}
    assert report['inputSHA256']==expected,'Wrong exact-source archive inputs'
if __name__=='__main__':
    validate(json.loads(Path(sys.argv[1]).read_text()),sys.argv[2],require_apple=True)
    print('PASS exact-source owned GLSL archive evidence; no physical/gameplay claim')
