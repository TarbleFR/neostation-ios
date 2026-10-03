#!/usr/bin/env python3
"""Execute real archive operations and the production startup fallback decision."""
from pathlib import Path
import importlib.util
import json
import platform
import re
import shutil
import subprocess
import tempfile
ROOT=Path(__file__).resolve().parents[1]
HERE=ROOT/'native/neoswap-storage'
compiler=shutil.which('clang++') or shutil.which('c++')
assert compiler, 'C++ compiler required'
spec=importlib.util.spec_from_file_location('research_config',ROOT/'build-utils/configure_neoswap_research.py')
config=importlib.util.module_from_spec(spec);spec.loader.exec_module(config)
import plistlib
with tempfile.TemporaryDirectory(prefix='neoswap-research-') as temporary:
    work=Path(temporary);cache=work/'cache';cache.mkdir()
    plist=work/'Info.plist';original={'sentinel':'preserved','CFBundleIdentifier':'test'}
    for mode in config.MODES:
        plist.write_bytes(plistlib.dumps(original));config.configure(plist,mode,'a'*40)
        value=plistlib.loads(plist.read_bytes());assert value['sentinel']=='preserved' and value['NeoSwapResearchMode']==mode
    previous=plist.read_bytes()
    try:config.configure(plist,'bad','a'*40)
    except ValueError:pass
    else:raise AssertionError('Invalid profile accepted')
    assert plist.read_bytes()==previous
    common=[compiler,'-std=c++20','-pthread','-Wall','-Wextra','-Werror','-O1','-g',
        '-fsanitize=address,undefined','-fno-omit-frame-pointer','-DNEOSWAP_STORAGE_TESTING',
        '-I',str(HERE),'-I',str(ROOT/'packages/neo_swap/ios/Classes')]
    version=subprocess.check_output([compiler,'--version'],text=True)
    legacy=[] if 'clang' in version.lower() else ['-Wno-error=misleading-indentation','-Wno-error=unused-result']
    store=work/'store.o'
    subprocess.run(common+legacy+['-c',str(HERE/'Store.cpp'),'-o',str(store)],check=True)
    exe=work/'research'
    libs=['-lcompression','-lz'] if platform.system()=='Darwin' else ['-llz4','-lz']
    subprocess.run(common+[str(HERE/n) for n in ('ManagedSwap.cpp','SourceArchive.cpp','Metrics.cpp')]+
        [str(store),str(ROOT/'test/neoswap_swap_research_test.cpp')]+libs+['-o',str(exe)],check=True)
    report=json.loads(subprocess.check_output([str(exe),str(cache)],text=True));assert report['passed']
    # Evaluate the exact production rejection expression. Both binders must
    # still succeed; unavailable preparation must permit the normal Core path.
    bridge=(ROOT/'packages/rpcs3_internal_bridge/ios/Classes/Rpcs3InternalBridgePlugin.mm').read_text()
    predicate=re.search(r'if \((swapResult != NEOSWAP_OK[^\n]+)\) \{\n    if \(error\)',bridge).group(1)
    src=work/'startup.cpp';startup=work/'startup'
    src.write_text('''#include <cassert>
constexpr int NEOSWAP_OK=0,NEOSWAP_RELAY_OK=0;
bool rejects(int swapResult,int relayResult){return '''+predicate+''';}
int main(){assert(!rejects(0,0));assert(rejects(1,0));assert(rejects(0,1));assert(rejects(1,1));}
''')
    subprocess.run([compiler,'-std=c++20','-Wall','-Wextra','-Werror',str(src),'-o',str(startup)],check=True)
    subprocess.run([str(startup)],check=True)
    plugin=(ROOT/'packages/neo_swap/ios/Classes/NeoSwapPlugin.mm').read_text()
    target=plugin.split('- (uint64_t)adaptiveDonationTarget {',1)[1].split('\n}',1)[0]
    policy=work/'policy.cpp';policy_exe=work/'policy'
    policy.write_text('''#include <cassert>
#include "NeoSwapExperiment.h"
#include "Pool.h"
constexpr uint64_t kMiB=1024*1024,kDonationWarmFloorBytes=512*kMiB,
    kDonationReserveBytes=128*kMiB,kDonationGrowthQuantumBytes=128*kMiB,kDonationHardLimitBytes=5*1024*kMiB;
constexpr unsigned NEOSWAP_RPCS3=0;
static neostation::experiment::Profile selected;
static neostation::donation::PoolSnapshot observed{};
static bool active=true;
const auto& NeoSwapExperimentProfile(){return selected;}
bool NeoSwap_OwnerSessionActive(unsigned){return active;}
namespace neostation::donation {void pool_snapshot(PoolSnapshot& out) noexcept{out=observed;}}
uint64_t actualTarget(){'''+target+'''}
int main(){
    selected=neostation::experiment::parse("integrated");
    assert(actualTarget()==32*kMiB);observed.live_bytes=64*kMiB;assert(actualTarget()==96*kMiB);
    observed.live_bytes=kDonationHardLimitBytes;assert(actualTarget()==kDonationHardLimitBytes);
    active=false;assert(actualTarget()==0);active=true;observed.live_bytes=0;
    selected=neostation::experiment::parse(nullptr);assert(actualTarget()==512*kMiB);
    observed.last_stage=neostation::donation::Stage::snapshot_busy;assert(actualTarget()==0);
}
''')
    subprocess.run([compiler,'-std=c++20','-Wall','-Wextra','-Werror','-I',str(ROOT/'packages/neo_swap/ios/Classes'),
        '-I',str(ROOT/'native/neoswap-donation'),str(policy),'-o',str(policy_exe)],check=True)
    subprocess.run([str(policy_exe)],check=True)
    report['productionStartupPredicateExecuted']=True
    report['productionAdaptiveDonationTargetExecuted']=True
    print(json.dumps(report))
