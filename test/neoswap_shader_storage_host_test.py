"""Narrow host integration contract, plus negative evidence validation tests."""
import copy,hashlib,json,sys
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'build-utils'))
from configure_neoswap_storage import materialize
from validate_shader_storage_evidence import validate
materialize()
# Compile the public ABI headers under the exact feature defines used by
# CocoaPods. A standalone service build does not exercise NeoSwapPlugin.mm's
# guarded branches; the Build396 macro/enum collision escaped that check.
import os, re, shlex, shutil, subprocess
pod=(ROOT/'packages/neo_swap/ios/neo_swap.podspec').read_text()
match=re.search(r"'GCC_PREPROCESSOR_DEFINITIONS'\s*=>\s*'([^']+)'",pod)
assert match, 'Missing production CocoaPods preprocessor configuration'
flags=[value for value in shlex.split(match[1]) if value!='$(inherited)']
compiler=shutil.which('clang++') or shutil.which('c++')
assert compiler, 'A native compiler is required for the actual feature-flag gate'
environment=dict(os.environ); environment.pop('SDKROOT',None)
probe=('#include "NeoSwap.h"\n#include "StorageABI.h"\n'
       'static_assert(NEOSWAP_STORAGE == -4, "Existing result ABI changed");\n'
       'static_assert(NEOSWAP_STORAGE_ABI == 1, "Storage ABI changed");\n')
command=[compiler,'-std=c++20','-fsyntax-only','-x','c++','-I',
         str(ROOT/'packages/neo_swap/ios/Classes')]
compiled=subprocess.run(command+['-D'+flag for flag in flags]+['-'],input=probe,
                        text=True,capture_output=True,env=environment,timeout=30)
assert compiled.returncode==0, 'Production CocoaPods defines break public ABI:\n'+compiled.stderr
assert 'NEOSWAP_SHADER_STORAGE=1' in flags, 'Shader feature must remain compiled in'
plugin=(ROOT/'packages/neo_swap/ios/Classes/NeoSwapPlugin.mm').read_text()
assert plugin.count('#if defined(NEOSWAP_SHADER_STORAGE)')==4
assert re.search(r'#if defined\(NEOSWAP_SHADER_STORAGE\)\s+NSDictionary\* operations = NeoSwapStorage_DrainOperations\(\);',plugin), 'Operation handoff must remain feature guarded'
assert '#if defined(NEOSWAP_STORAGE)' not in plugin
# Keep a negative compiler regression: the old flag really must fail, rather
# than merely checking a renamed string or suppressing a warning.
old_flags=[flag for flag in flags if flag!='NEOSWAP_SHADER_STORAGE=1']+['NEOSWAP_STORAGE=1']
rejected=subprocess.run(command+['-D'+flag for flag in old_flags]+['-'],input=probe,
                       text=True,capture_output=True,env=environment,timeout=30)
assert rejected.returncode!=0, 'Old feature flag unexpectedly accepted'
print('PASS actual CocoaPods defines, preserved -4 error ABI, enabled shader branches; old collision rejected')
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
keys={'storageToggle','storageDescription','storageApplied','storageActive','storageInactive','storageMetrics','storageVideoMetrics'}
for locale,values in labels.items():assert keys<=values.keys(),locale
assert set(labels)=={'en','es','ru','zh','zh_Hant','pt','fr','de','it','id','ja','ko'}
for locale,values in labels.items():
    assert set(re.findall(r'\{(\w+)\}',values['storageVideoMetrics']))=={'cold','returned'},locale
assert 'CFBooleanGetTypeID()' in (ROOT/'packages/neo_swap/ios/Classes/NeoSwapPlugin.mm').read_text()
workflow=(ROOT/'.github/workflows/neoswap-ipa.yml').read_text()
assert "assert identity['neoswap_storage_abi'] == 1" in workflow
assert 'Require exact shader storage host, simulator and GPU evidence' in workflow
assert workflow.index('python3 build-utils/configure_neoswap_storage.py')<workflow.index('pod install --project-directory=ios')
paths={str(p.relative_to(ROOT)) for p in (ROOT/'native/neoswap-storage').glob('*') if p.suffix in ('.h','.cpp','.py')}
paths|={str(p.relative_to(ROOT)) for p in (ROOT/'native/neoswap-storage/tests').glob('*') if p.suffix in ('.cpp','.mm')}
paths|={'build-utils/configure_neoswap_storage.py','packages/neo_swap/ios/Classes/NeoSwapStorageService.h','packages/neo_swap/ios/Classes/NeoSwapStorageService.mm','packages/neo_swap/ios/Classes/StorageABI.h'}
paths.add('packages/neo_swap/ios/Classes/SourceABI.h')
paths.add('packages/neo_swap/ios/Classes/NeoSwapSourceWork.h')
paths.add('packages/neo_swap/ios/Classes/NeoSwapExperiment.h')
# Fixtures test refusal logic, never masquerade as a hardware result.
fixture={'passed':True,'sourceCommit':'d'*40,'productionClientExecuted':True,'productionHostServiceIOSLinked':True,
         'realIOSSimulatorServiceExecuted':True,'realVulkanModule':True,'physicalIPhoneValidated':False,
         'realRPCS3GameplayValidated':False,'kernelSwapPorted':False,
         'gpu':{'passed':True,'sourceBuilds':1,'sourceBuildsBeforeRestore':1,'realComputeDispatchCompleted':True,'cpuBytesReleasedBeforePipeline':True,'diskReadBytes':1,'diskWriteBytes':1},
         'simulator':{'passed':True,'epochIsolation':True,'leaseSurvivedSessionEnd':True,'privateFileRoundTrip':True,
                      'sourceArchiveRoundTrip':True,'sourceEpochIsolation':True,'sourcePressureRefusal':True,
                      'videoPixelRoundTrip':True,'videoPixelEpochIsolation':True,'videoPixelPressureRefusal':True,
                      'videoMemoryNeedGate':True,'videoMemoryRecoveryStopsArchival':True,
                      'warningRecoveryReactivatesPixels':True,'memoryInputsAreInjected':True,
                      'immediateDemandDuringAdmissionBurst':True,
                      'pixelDiagnostics':{'videoPixelLiveArchivedBytes':1280*720*3//2,
                          'videoPixelReturnedArchiveBytesCumulative':1280*720*3//2,'stagingRamBytes':0},
                      'sourceDiagnostics':{'archivedSourceBytesCumulative':1,'stagingRamBytes':0,'diskReadBytes':1,'diskWriteBytes':1}},
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
for key in ('videoMemoryNeedGate','videoMemoryRecoveryStopsArchival','warningRecoveryReactivatesPixels',
            'memoryInputsAreInjected','immediateDemandDuringAdmissionBurst'):
    for value in (False,1,'true',None):
        bad=copy.deepcopy(fixture);bad['simulator'][key]=value
        try:validate(bad,'d'*40)
        except AssertionError:pass
        else:raise AssertionError('Accepted missing/invalid simulator behavior '+key)
    bad=copy.deepcopy(fixture);del bad['simulator'][key]
    try:validate(bad,'d'*40)
    except (AssertionError,KeyError):pass
    else:raise AssertionError('Accepted absent simulator behavior '+key)
bad=copy.deepcopy(fixture);del bad['inputSHA256']['packages/neo_swap/ios/Classes/NeoSwapSourceWork.h']
try:validate(bad,'d'*40)
except AssertionError:pass
else:raise AssertionError('Accepted unbound host scheduling policy')
# Simulator-only memory injection must never enter the production iOS link.
import ast
runner=ast.parse((ROOT/'native/neoswap-storage/run_shader_validation.py').read_text())
flags_by_name={}
for node in ast.walk(runner):
    if isinstance(node,ast.Assign) and isinstance(node.value,ast.List):
        for target in node.targets:
            if isinstance(target,ast.Name) and target.id in ('command','ios'):
                flags_by_name[target.id]={item.value for item in node.value.elts
                    if isinstance(item,ast.Constant) and isinstance(item.value,str)}
assert '-DNEOSWAP_STORAGE_TESTING' in flags_by_name['command']
assert '-DNEOSWAP_STORAGE_TESTING' not in flags_by_name['ios']
print('PASS optional host binding, title/epoch/lifecycle boundaries, generated source identity, locales and strict evidence refusal')
