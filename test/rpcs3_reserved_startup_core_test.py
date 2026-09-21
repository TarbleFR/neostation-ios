"""Test canonical Core ownership/reset behavior with injected native outcomes."""
from pathlib import Path
import subprocess, sys, tempfile
ROOT = Path(__file__).resolve().parents[1]
if len(sys.argv) != 2: raise SystemExit('usage: test <materialized-core-source>')
source = Path(sys.argv[1]); api = (source/'rpcs3/ios/RPCS3IOS.cpp').read_text()
jit = (source/'Utilities/JITIOS.cpp').read_text()
assert 'reserve_arena_layout(' not in jit
assert 'physical_memory_size(' not in jit
assert 'rpcs3::ios::jit::is_ready()' not in api
assert 'g_host_layout = {}; // ownership moves' in jit
assert (source/'Utilities/NeoStationArenaLayout.h').read_bytes() == (ROOT/'packages/rpcs3_internal_bridge/ios/Classes/Rpcs3ArenaLayout.h').read_bytes()
assert 'bool g_runtime_pointers_published = false' in api

def body(signature):
    start=api.index(signature); at=api.index('{',start); depth=1; end=at+1
    while depth:
        depth += (api[end]=='{')-(api[end]=='}'); end+=1
    return api[start:end]
reset=body('extern "C" rpcs3_ios_status neostation_rpcs3_reset_failed_startup(')
adopt=body('extern "C" rpcs3_ios_status neostation_rpcs3_adopt_jit_layout(')
harness=r'''
#include "RPCS3IOSContract.h"
#include <cassert>
#include <cstdint>
#include <mutex>
#include <string>
using u64 = uint64_t;
std::mutex g_api_mutex;
rpcs3::ios::lifecycle g_lifecycle;
bool g_initialization_attempted=false, g_runtime_pointers_published=false, g_emu_started=false;
rpcs3_ios_config g_config{};
std::string error;
void set_error(std::string value) { error=value; }
namespace rpcs3::ios::jit {
bool clean=true, adoptable=true; unsigned resets=0;
bool reset_failed_layout() noexcept { ++resets; return clean; }
const char* last_error() noexcept { return "actual native failure"; }
void set_diagnostic_callback(void*) noexcept {}
bool accept_host_layout(u64,u64,u64,u64) noexcept { return adoptable; }
}
'''
harness += reset + '\n' + adopt + r'''
int main() {
  g_lifecycle.begin_initialize(); g_initialization_attempted=true;
  g_lifecycle.finish_initialize(false);
  assert(neostation_rpcs3_reset_failed_startup()==RPCS3_IOS_OK);
  assert(!g_initialization_attempted);
  assert(g_lifecycle.begin_initialize()==RPCS3_IOS_OK);
  g_lifecycle.finish_initialize(false); g_initialization_attempted=true;
  rpcs3::ios::jit::clean=false;
  assert(neostation_rpcs3_reset_failed_startup()!=RPCS3_IOS_OK);
  assert(g_initialization_attempted);
  rpcs3::ios::jit::clean=true; g_runtime_pointers_published=true;
  const auto resets=rpcs3::ios::jit::resets;
  assert(neostation_rpcs3_reset_failed_startup()!=RPCS3_IOS_OK);
  assert(rpcs3::ios::jit::resets==resets); // never free published runtime
  assert(neostation_rpcs3_adopt_jit_layout(0,0,0,0)!=RPCS3_IOS_OK);
}
'''
with tempfile.TemporaryDirectory() as temp:
    src=Path(temp)/'lifecycle.cpp'; src.write_text(harness)
    exe=str(Path(temp)/'lifecycle')
    subprocess.run(['c++','-std=c++20','-Wall','-Wextra','-Werror','-I',str(source/'rpcs3/ios'),str(src),'-o',exe],check=True)
    subprocess.run([exe],check=True)
print('PASS actual Core reset: retry before publication, preservation after publication, failure retained')
import re
host=(ROOT/'packages/rpcs3_internal_bridge/ios/Classes/Rpcs3InternalBridgePlugin.mm').read_text()
selftest=api[api.index('extern "C" rpcs3_ios_status rpcs3_ios_run_llvm_self_test('):]
assert 'CreateMul(argument, llvm::ConstantInt::get(argument->getType(), 3))' in selftest
assert 'CreateAdd(multiplied, llvm::ConstantInt::get(argument->getType(), 7))' in selftest
probe=host[host.index('isEqualToString:@"verifyJitExecution"'):host.index('isEqualToString:@"diagnostics"')]
input_value=int(re.search(r'status = test\((\d+), &output\);', probe).group(1))
expected=int(re.search(r'status == 0 && output == (\d+)', probe).group(1))
assert input_value*3+7 == expected, (input_value,expected)
assert host.count('dlsym(self->_api.handle, "rpcs3_ios_run_llvm_self_test")') == 1
print('PASS static host/Core LLVM probe contract: f(%d)=%d; one execution proof' % (input_value,expected))
