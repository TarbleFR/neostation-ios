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
# Flutter's generated Objective-C registrar imports the public pod module.
# Keep its research header valid outside Objective-C++ as well.
for defines in ([],['-D__OBJC__=1']):
    subprocess.run([compiler,'-x','c','-std=c11','-Wall','-Wextra','-Werror','-fsyntax-only',
        '-I',str(ROOT/'packages/neo_swap/ios/Classes')]+defines+['-'],
        input='#include "NeoSwapExperiment.h"\n',text=True,check=True)
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
    # Build409: the target takes its floor and reserve from the global budget
    # controller accessors. Execute their exact production bodies too; the two
    # Objective-C message sends become calls of the extracted C++ functions.
    floor=plugin.split('- (uint64_t)donorFloorBytes {',1)[1].split('\n}',1)[0]
    reserve=plugin.split('- (uint64_t)donorReserveBytes {',1)[1].split('\n}',1)[0]
    target=target.replace('[self donorFloorBytes]','donorFloorBytes()').replace('[self donorReserveBytes]','donorReserveBytes()')
    assert '[self' not in target+floor+reserve, 'Unexpected Objective-C in the extracted donation policy'
    admission=plugin.split('- (void)startDonors {',1)[1].split('    if (self.donorEpoch',1)[0]
    admission=admission[admission.index('    if (NeoSwapExperimentProfile().configured)'):]
    warm=re.search(r'const BOOL warmEligible = (.*?);',bridge,re.S).group(1).replace('titleId.UTF8String ?: ""','title')
    includes=work/'include';includes.mkdir();(includes/'neo_swap').symlink_to(ROOT/'packages/neo_swap/ios/Classes')
    policy=work/'policy.cpp';policy_exe=work/'policy'
    policy.write_text('''#include <cassert>
#include "NeoSwapBudget.h"
#include "NeoSwapExperiment.h"
#include "NeoSwapHost.h"
#include "NeoSwapUsagePolicy.h"
#include "Pool.h"
constexpr uint64_t kMiB=1024*1024,kDonationWarmFloorBytes=512*kMiB,
    kDonationReserveBytes=128*kMiB,kDonationGrowthQuantumBytes=128*kMiB,kDonationHardLimitBytes=7*1024*kMiB;
static neostation::experiment::Profile selected;
static neostation::donation::PoolSnapshot observed{};
static bool active=true;
static bool cpu_enabled=true;
static NeoSwapHostStats host{};
static unsigned starts=0;
// The plugin instance variables written by applyBudget; zero until a decision exists.
static neostation::budget::Decision _budgetDecision{};
static uint64_t _budgetDecisionCount=0;
const auto& NeoSwapExperimentProfile(){return selected;}
extern "C" int NeoSwap_OwnerSessionActive(uint32_t){return active;}
extern "C" int NeoSwap_CPUBufferSnapshot(NeoSwapCPUBufferStats* out){out->enabled=cpu_enabled;return NEOSWAP_OK;}
extern "C" int NeoSwap_HostSnapshot(NeoSwapHostStats* out){*out=host;return NEOSWAP_OK;}
namespace neostation::donation {void pool_snapshot(PoolSnapshot& out) noexcept{out=observed;}}
uint64_t donorFloorBytes(){'''+floor+'''}
uint64_t donorReserveBytes(){'''+reserve+'''}
uint64_t actualTarget(){'''+target+'''}
void actualStartAdmission(){'''+admission+''';++starts;}
bool actualWarm(std::string_view title){return '''+warm+''';}
int main(){
    selected=neostation::experiment::parse("integrated");
    cpu_enabled=false;actualStartAdmission();assert(starts==0);
    host.donor_pending_demand_bytes=65536;actualStartAdmission();assert(starts==1);host={};
    cpu_enabled=true;actualStartAdmission();assert(starts==2);
    assert(!actualWarm("BLES00113"));assert(actualWarm("BCES00510"));
    assert(actualTarget()==32*kMiB);observed.live_bytes=64*kMiB;assert(actualTarget()==96*kMiB);
    cpu_enabled=false;assert(actualTarget()==96*kMiB);observed.live_bytes=0;assert(actualTarget()==0);cpu_enabled=true;
    observed.live_bytes=kDonationHardLimitBytes;assert(actualTarget()==kDonationHardLimitBytes);
    active=false;assert(actualTarget()==0);active=true;observed.live_bytes=0;
    selected=neostation::experiment::parse(nullptr);assert(actualTarget()==512*kMiB);
    assert(actualWarm("BLES00113"));
    selected=neostation::experiment::parse("baseline");assert(!actualWarm("BCES00510"));assert(actualTarget()==0);
    selected=neostation::experiment::parse("relay");assert(!actualWarm("BCES00510"));assert(actualTarget()==0);
    observed.last_stage=neostation::donation::Stage::snapshot_busy;assert(actualTarget()==0);
    // Build409: before any decision the production path keeps the fixed values;
    // after one, the controller's floor and reserve drive the target (relay
    // host loans admitted: floor 0, 64 MiB reserve rounded to the 128 MiB
    // quantum; pressure: floor and reserve 0 so an idle pool never grows).
    observed={};selected=neostation::experiment::parse(nullptr);
    assert(donorFloorBytes()==kDonationWarmFloorBytes&&donorReserveBytes()==kDonationReserveBytes);
    _budgetDecision.donor_floor_bytes=0;_budgetDecision.donor_reserve_bytes=64*kMiB;_budgetDecisionCount=1;
    assert(donorFloorBytes()==0&&donorReserveBytes()==64*kMiB);
    assert(actualTarget()==128*kMiB);observed.live_bytes=200*kMiB;assert(actualTarget()==384*kMiB);
    _budgetDecision.donor_reserve_bytes=0;observed.live_bytes=0;assert(actualTarget()==0);
    observed.live_bytes=64*kMiB;assert(actualTarget()==128*kMiB);
    _budgetDecision.donor_floor_bytes=neostation::budget::legacy_donor_floor_bytes;
    _budgetDecision.donor_reserve_bytes=neostation::budget::legacy_donor_reserve_bytes;observed.live_bytes=0;
    assert(actualTarget()==512*kMiB);
    // Research profiles keep their small fixed values whatever the controller decided.
    selected=neostation::experiment::parse("integrated");assert(donorFloorBytes()==16*kMiB&&donorReserveBytes()==32*kMiB);
    _budgetDecision={};_budgetDecisionCount=0;
}
''')
    subprocess.run([compiler,'-std=c++20','-Wall','-Wextra','-Werror','-I',str(ROOT/'packages/neo_swap/ios/Classes'),
        '-I',str(includes),'-I',str(ROOT/'packages/rpcs3_internal_bridge/ios/Classes'),
        '-I',str(ROOT/'native/neoswap-donation'),str(policy),'-o',str(policy_exe)],check=True)
    subprocess.run([str(policy_exe)],check=True)
    report['productionStartupPredicateExecuted']=True
    report['productionAdaptiveDonationTargetExecuted']=True
    report['productionDonorAdmissionAndBootWaitExecuted']=True
    report['publicProfileHeaderCAndObjCCompatible']=True
    print(json.dumps(report))
