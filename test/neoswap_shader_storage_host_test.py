"""Narrow host integration contract, plus negative evidence validation tests."""
import copy,hashlib,json,sys
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'build-utils'))
from configure_neoswap_storage import materialize
from validate_shader_storage_evidence import validate
materialize()
service=(ROOT/'packages/neo_swap/ios/Classes/NeoSwapStorageService.mm').read_text()
bridge=(ROOT/'packages/rpcs3_internal_bridge/ios/Classes/Rpcs3InternalBridgePlugin.mm').read_text()
policy=(ROOT/'native/neoswap-storage/ShaderPolicy.h').read_text()
assert 'boolForKey:preferenceKey' in service and 'registerDefaults' not in service
assert 'requestedGeneration.fetch_add(1)' in service and 'active.try_load()' in service
assert 'std::atomic<std::shared_ptr' not in service, 'Unavailable Xcode libc++ API'
assert 's.retired.push_back(std::move(old))' in service
assert 'lastSessionCache' in service and 'NSFileProtectionCompleteUntilFirstUserAuthentication' in service
assert 'UIApplicationDidReceiveMemoryWarningNotification' in service and 'UIApplicationDidEnterBackgroundNotification' in service
assert bridge.count('NeoSwapStorage_BeginSession(titleId);')==1 and bridge.count('NeoSwapStorage_EndSession();')==2
assert bridge.index('rpcs3_ios_set_storage_cache_api') < bridge.index('self->_api.initialize(&options)')
assert 'NeoSwapStorage_SetBinderResult(storageResult)' in bridge
for title in ('BCES00510','BCES00799','BCUS98111','BCJS37001','BCAS25003','BCKS15003'):assert title in policy
assert 'BLES00113' not in policy
labels=json.loads((ROOT/'native/neoswap/localizations.json').read_text())
keys={'storageToggle','storageDescription','storageApplied','storageActive','storageInactive','storageMetrics'}
for locale,values in labels.items():assert keys<=values.keys(),locale
assert 'CFBooleanGetTypeID()' in (ROOT/'packages/neo_swap/ios/Classes/NeoSwapPlugin.mm').read_text()
workflow=(ROOT/'.github/workflows/neoswap-ipa.yml').read_text()
assert "assert identity['neoswap_storage_abi'] == 1" in workflow
assert 'Require exact shader storage host, simulator and GPU evidence' in workflow
assert workflow.index('python3 build-utils/configure_neoswap_storage.py')<workflow.index('pod install --project-directory=ios')
paths={str(p.relative_to(ROOT)) for p in (ROOT/'native/neoswap-storage').glob('*') if p.suffix in ('.h','.cpp','.py')}
paths|={str(p.relative_to(ROOT)) for p in (ROOT/'native/neoswap-storage/tests').glob('*') if p.suffix in ('.cpp','.mm')}
paths|={'build-utils/configure_neoswap_storage.py','packages/neo_swap/ios/Classes/NeoSwapStorageService.h','packages/neo_swap/ios/Classes/NeoSwapStorageService.mm','packages/neo_swap/ios/Classes/StorageABI.h'}
# Fixtures test refusal logic, never masquerade as a hardware result.
fixture={'passed':True,'sourceCommit':'d'*40,'productionClientExecuted':True,'productionHostServiceIOSLinked':True,
         'realIOSSimulatorServiceExecuted':True,'realVulkanModule':True,'physicalIPhoneValidated':False,
         'realRPCS3GameplayValidated':False,'kernelSwapPorted':False,
         'gpu':{'passed':True,'sourceBuilds':1,'sourceBuildsBeforeRestore':1,'realComputeDispatchCompleted':True,'cpuBytesReleasedBeforePipeline':True,'diskReadBytes':1,'diskWriteBytes':1},
         'simulator':{'passed':True,'epochIsolation':True,'leaseSurvivedSessionEnd':True,'privateFileRoundTrip':True},
         'inputSHA256':{p:hashlib.sha256((ROOT/p).read_bytes()).hexdigest() for p in paths}}
validate(fixture,'d'*40)
for key in ('passed','productionClientExecuted','productionHostServiceIOSLinked','realIOSSimulatorServiceExecuted','realVulkanModule'):
    bad=copy.deepcopy(fixture);bad[key]=False
    try:validate(bad,'d'*40)
    except AssertionError:pass
    else:raise AssertionError('Accepted missing evidence '+key)
for key in ('sourceCommit','inputSHA256'):
    bad=copy.deepcopy(fixture);bad[key]='e'*40 if key=='sourceCommit' else {}
    try:validate(bad,'d'*40)
    except AssertionError:pass
    else:raise AssertionError('Accepted wrong provenance '+key)
print('PASS optional host binding, title/epoch/lifecycle boundaries, generated source identity, locales and strict evidence refusal')
