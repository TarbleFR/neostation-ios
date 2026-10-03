"""Independent source ABI, host ownership and strict exact-source evidence refusal."""
import copy
import hashlib
from pathlib import Path
import sys
import subprocess
ROOT=Path(__file__).resolve().parents[1];sys.path.insert(0,str(ROOT/'build-utils'))
from configure_neoswap_storage import materialize
from validate_source_archive_evidence import REQUIRED_INPUTS,validate
materialize()
assert (ROOT/'packages/neo_swap/ios/Classes/SourceABI.h').read_bytes()==(ROOT/'native/neoswap-storage/SourceABI.h').read_bytes()
service=(ROOT/'packages/neo_swap/ios/Classes/NeoSwapStorageService.mm').read_text()
bridge=(ROOT/'packages/rpcs3_internal_bridge/ios/Classes/Rpcs3InternalBridgePlugin.mm').read_text()
assert 'sourceArchive.try_load()' in service and 'source->maintain(1,4)' in service
assert 'source->try_read_staging(object,output' in service
assert 'requestSourceWork(s)' in service and 'sourceWork.demand_begin()' in service
subprocess.run([sys.executable,str(ROOT/'test/neoswap_source_work_test.py')],check=True)
assert 'dispatch_sync(state().queue,operation)' in service and 'dispatch_get_specific(&utilityQueueKey)' in service
assert 'source->pressure(level)' in service and 'source->pause(s.background)' in service
assert bridge.index('rpcs3_ios_set_source_archive_api')<bridge.index('self->_api.initialize(&options)')
workflow=(ROOT/'.github/workflows/neoswap-ipa.yml').read_text()
assert "assert identity['neoswap_source_archive_abi'] == 1" in workflow
assert "source-archive.json" in workflow and 'validate_source(source,sha,require_apple=True)' in workflow
assert workflow.index('validate_source(source,sha,require_apple=True)')<workflow.index('      - name: Configure release host')
fixture={'schema':1,'sourceCommit':'a'*40,'platform':'Darwin','passed':True,'physicalIPhoneValidated':False,
    'realRPCS3GameplayValidated':False,'kernelSwapPorted':False,'automaticGuestPagingActivated':False,
    'sanitizers':{'address':True,'undefined':True},'c11HeaderVerified':True,
    'core':{field:True for field in ('passed','coreClientExecuted','ramStorageRamCycleVerified','byteIdentityVerified',
        'admissionNoDiskIO','pressureAndQuotaVerified','persistenceFailureRetainsSnapshot','failedRestoreClearsOutput',
        'staleEpochRejected','sharedRetirementVerified')},
    'inputSHA256':{p:hashlib.sha256((ROOT/p).read_bytes()).hexdigest() for p in sorted(REQUIRED_INPUTS)}}
fixture['core'].update(logicalTouchedBytes=64*1024**2,restoredBytes=64*1024**2,coreReleasedCapacityBytes=64*1024**2,
    stagingPeakBytes=1024**2,stagingLimitBytes=4*1024**2,managedMappedPeakBytes=65536,managedMappedLimitBytes=8*1024**2,
    diskReadBytes=1,diskWriteBytes=1)
fixture['frames']={field:True for field in ('passed','softwarePixelBytesSimulated','byteIdentityVerified',
    'transactionalAdmissionVerified','partialRestoreNeverConsumed','oldHostFallbackVerified',
    'warmAndReferencedPixelsRetained','throttledProgressResumed')}
fixture['frames'].update(realDecoderExecuted=False,physicalIPhoneValidated=False,gameplayValidated=False,
    logicalPixelBytes=48*1280*720*3//2,returnedPixelBytes=48*1280*720*3//2,stagingPeakBytes=2*1024**2)
work_fields=('passed','actualPrivateFileCheckpointAndRestore','wholeRecordFifoBacklogReproduced',
    'demandPrecedesContinuation','maintenanceCoalesced','ramDemandNoDiskIO',
    'partialQuantumRetainsFullSnapshot','pressureResumeExact','invalidMemoryFailsClosed')
fixture['sourceWork']={field:True for field in work_fields}
fixture['sourceWork'].update(physicalIPhoneValidated=False,realRPCS3GameplayValidated=False)
validate(fixture,'a'*40,require_apple=True)
for field in ('passed','coreClientExecuted','ramStorageRamCycleVerified','byteIdentityVerified','admissionNoDiskIO',
              'pressureAndQuotaVerified','persistenceFailureRetainsSnapshot','failedRestoreClearsOutput','staleEpochRejected','sharedRetirementVerified'):
    for invalid in (False,1,'true'):
        bad=copy.deepcopy(fixture);bad['core'][field]=invalid
        try:validate(bad,'a'*40,require_apple=True)
        except AssertionError:pass
        else:raise AssertionError('Accepted incomplete evidence: '+field)
for field,invalid in (('sourceCommit','b'*40),('inputSHA256',{}),('physicalIPhoneValidated',True),('platform','Linux')):
    bad=copy.deepcopy(fixture);bad[field]=invalid
    try:validate(bad,'a'*40,require_apple=True)
    except AssertionError:pass
    else:raise AssertionError('Accepted wrong provenance: '+field)
for field in ('passed','byteIdentityVerified','transactionalAdmissionVerified','partialRestoreNeverConsumed',
              'oldHostFallbackVerified','throttledProgressResumed'):
    for invalid in (False,1,'true'):
        bad=copy.deepcopy(fixture);bad['frames'][field]=invalid
        try:validate(bad,'a'*40,require_apple=True)
        except AssertionError:pass
        else:raise AssertionError('Accepted incomplete pixel evidence: '+field)
for field in work_fields:
    for invalid in (False,1,'true',None):
        bad=copy.deepcopy(fixture);bad['sourceWork'][field]=invalid
        try:validate(bad,'a'*40,require_apple=True)
        except AssertionError:pass
        else:raise AssertionError('Accepted incomplete scheduler evidence: '+field)
    bad=copy.deepcopy(fixture);del bad['sourceWork'][field]
    try:validate(bad,'a'*40,require_apple=True)
    except (AssertionError,KeyError):pass
    else:raise AssertionError('Accepted absent scheduler evidence: '+field)
for field in ('physicalIPhoneValidated','realRPCS3GameplayValidated'):
    for invalid in (True,0,'false'):
        bad=copy.deepcopy(fixture);bad['sourceWork'][field]=invalid
        try:validate(bad,'a'*40,require_apple=True)
        except AssertionError:pass
        else:raise AssertionError('Accepted unverified scheduler hardware inference: '+field)
for field in ('packages/neo_swap/ios/Classes/NeoSwapSourceWork.h',
              'native/neoswap-storage/tests/source_work_test.cpp',
              'test/neoswap_source_work_test.py','test/neoswap_source_archive_host_test.py'):
    bad=copy.deepcopy(fixture);del bad['inputSHA256'][field]
    try:validate(bad,'a'*40,require_apple=True)
    except AssertionError:pass
    else:raise AssertionError('Accepted missing exact scheduler input: '+field)
assert 'sourceConfig.domain_mask=15' in service
assert 'videoPixelLiveArchivedBytes' in service and 'budgetIsProcessFootprint":@NO' in service
print('PASS exact source ABI/host contract, simulator proof required and fail-closed owned archive evidence')
