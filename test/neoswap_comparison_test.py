#!/usr/bin/env python3
"""Reject mixed sessions and false gameplay/frametime conclusions."""
import copy
import importlib.util
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('comparison',ROOT/'tools/compare_neoswap_sessions.py')
module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
def fixture(mode,pid):
    rows=[]
    for index in range(3):
        rows.append({'pid':pid,'timestamp':index+100,'event':('rpcs3_memory_session_start','sample','rpcs3_memory_session_end')[index],
            'experiment':{'mode':mode,'sourceCommit':'a'*40,'configured':True,'valid':True,'storage':mode=='integrated'},
            'physicalMemoryBytes':8<<30,'osVersion':'same','processFootprintBytes':(index+1)*100,
            'processResidentBytes':200,'processAvailableBytes':500,'iosMemoryWarningCount':0,
            'memoryProfile':{'sessionSequence':1,'sampledSessionActive':index<2}})
    perf=[{'pid':pid,'timestamp':101,'stage':'performance_sample','message':'title=TEST00001 valid=0x1 fps=0.00 thermal=0'},
        {'pid':pid,'timestamp':100,'stage':'game_boot_begin','message':'TEST00001'},
        {'pid':pid,'timestamp':100.5,'stage':'game_boot_return','message':'TEST00001 status=0'}]
    return rows,perf
base,perf=fixture('baseline',10);candidate,other=fixture('integrated',11)
a=module.session(base,perf,[],'TEST00001');b=module.session(candidate,other,[],'TEST00001')
report=module.compare(a,b)
assert a['sampledFpsMean']==0 and a['zeroFpsSamples']==1 and a['frameTimeP95Ms'] is None
assert report['deviceValidationPassed'] is False and report['automaticPromotionAllowed'] is False
assert a['coreBootCallSeconds']==0.5 and a['completeSession']
bridge=(ROOT/'packages/rpcs3_internal_bridge/ios/Classes/Rpcs3InternalBridgePlugin.mm').read_text()
assert 'RPCS3Milestone(@"game_boot_begin", titleId);' in bridge and 'RPCS3Milestone(@"game_boot_return",' in bridge
failed=copy.deepcopy(perf);failed[-1]['message']='TEST00001 status=4'
assert module.session(base,failed,[],'TEST00001')['coreBootCallSeconds'] is None
missing=module.session(base[:-1],perf,[],'TEST00001');assert not missing['completeSession'] and missing['jetsamCause'] is None
for key,value in (('physicalMemoryBytes',4<<30),('sourceCommit','b'*40),('osVersion','different')):
    bad=copy.deepcopy(b);bad[key]=value
    try:module.compare(a,bad)
    except ValueError:pass
    else:raise AssertionError('Accepted incompatible '+key)
bad=copy.deepcopy(base);bad[0]['guestRelay']={'liveBackingBytes':65536}
try:module.session(bad,perf,[],'TEST00001')
except ValueError:pass
else:raise AssertionError('Accepted false baseline')
bad=base+[dict(base[0],pid=12)]
try:module.session(bad,perf,[],'TEST00001')
except ValueError:pass
else:raise AssertionError('Mixed processes accepted')
bad=copy.deepcopy(candidate);bad[1]['experiment']['mode']='relay'
try:module.session(bad,other,[],'TEST00001')
except ValueError:pass
else:raise AssertionError('Mixed profiles accepted')
assert module.counter_delta([1,3,2]) is None
bad=copy.deepcopy(base)+[dict(base[0],timestamp=1000),dict(base[1],timestamp=1001)]
try:module.session(bad,perf,[],'TEST00001')
except ValueError:pass
else:raise AssertionError('Reused PID across launches accepted')
bound=copy.deepcopy(candidate)
for row in bound:row['shaderStorage']={'sourceArchive':{'session':7}}
operations=[{'pid':11,'timestamp':101,'batch':{'events':[
    {'session':7,'operation':'restored_from_managed_chunks'},
    {'session':6,'operation':'restored_from_managed_chunks'}]}}]
selected=module.session(bound,other,operations,'TEST00001')
assert selected['operationCounts']=={'restored_from_managed_chunks':1} and selected['operationEventsExcluded']==1
print('PASS comparison: identities, sessions, real zero FPS, incomplete exits, counter resets, no invented frametimes/jetsam')
