#!/usr/bin/env python3
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]

def read(path):
    return (ROOT / path).read_text()

host = read('packages/rpcs3_internal_bridge/ios/Classes/Rpcs3InternalBridgePlugin.mm')
diag_header = read('packages/rpcs3_internal_bridge/ios/Classes/Rpcs3Diagnostics.h')
diag = read('packages/rpcs3_internal_bridge/ios/Classes/Rpcs3Diagnostics.mm')
service = read('lib/services/rpcs3_internal_service.dart')

assert 'NEOSTATION_BUILD283_BOUNDED_CORE_LOG' in host
core_log = host.split('static void RPCS3Log(void* context, int32_t level, const char* message) {', 1)[1].split('\n}', 1)[0]
assert 'strstr(message, "COREPROF ") != nullptr' in core_log
assert 'strstr(message, "COREPROF_RESILIENCE ") != nullptr' in core_log
assert 'const BOOL videoArchive = strstr(message, "NEOSWAP_VDEC ") != nullptr;' in core_log
assert 'if (level > 2 && !profiler && !videoArchive) return;' in core_log
assert 'budgetCount >= 128' in host
# VDEC shares the ordinary budget: only profiler messages bypass it. The lock
# protects both the one-second window and its count; rejection precedes output.
assert 'if (!profiler) {' in core_log
assert core_log.index('os_unfair_lock_lock(&budgetLock);') < core_log.index('now - budgetWindow >= 1.0')
assert core_log.index('now - budgetWindow >= 1.0') < core_log.index('if (budgetCount >= 128) allowed = NO;')
assert core_log.index('if (budgetCount >= 128) allowed = NO;') < core_log.index('else budgetCount++;')
assert core_log.index('else budgetCount++;') < core_log.index('os_unfair_lock_unlock(&budgetLock);')
assert core_log.index('os_unfair_lock_unlock(&budgetLock);') < core_log.index('if (!allowed) return;')
assert core_log.index('if (!allowed) return;') < core_log.index('RPCS3Diagnostic(@"core_log", text);')
assert 'RPCS3Milestone(@"core_load_begin"' in host
assert 'RPCS3Milestone(@"core_initialize_begin"' in host
assert 'RPCS3Milestone(@"game_boot_begin"' in host
assert 'RPCS3-milestones.log' in diag
assert 'static inline' not in diag_header
assert 'RPCS3SharedDiagnosticsWriter' in diag
assert 'NSFileHandle* _diagnosticFile;' in diag
assert '[file synchronizeFile];' in diag

assert 'incomplete-boot-title.txt' not in service
assert '_consumePreviousIncompleteBootMarker' not in service
assert '_armBootCrashMarker' not in service
assert '_clearBootCrashMarkerWhenRunning' not in service
assert 'Rpcs3InternalBridge.clearPpuCache(titleId)' not in service

# Execute the production filter/budget body with a controlled clock. Only its
# void returns and Apple platform types are adapted; the admission logic is
# extracted unchanged, so an unbounded VDEC exception cannot pass this test.
logic = core_log[core_log.index('  const BOOL profiler ='):core_log.index('  NSString* text =')]
logic = logic.replace('return;', 'return false;')
native_source = r'''
#include <cassert>
#include <cstdint>
#include <cstring>
using BOOL = bool;
constexpr BOOL YES = true, NO = false;
using CFTimeInterval = double;
using os_unfair_lock = int;
#define OS_UNFAIR_LOCK_INIT 0
static double testNow = 1.0;
static unsigned lockDepth = 0, locks = 0, unlocks = 0;
double CACurrentMediaTime() { return testNow; }
void os_unfair_lock_lock(os_unfair_lock*) {
  assert(lockDepth++ == 0);
  ++locks;
}
void os_unfair_lock_unlock(os_unfair_lock*) {
  assert(lockDepth-- == 1);
  ++unlocks;
}
bool permitLog(int32_t level, const char* message) {
''' + logic + r'''
  return true;
}
int main() {
  // High-level noise and incomplete prefix lookalikes consume no budget.
  assert(!permitLog(3, "ordinary notice"));
  assert(!permitLog(5, "NEOSWAP_VDEC"));
  assert(!permitLog(5, "NEOSWAP_VDEC_OTHER detail"));
  assert(!permitLog(5, "COREPROFILING detail"));
  assert(permitLog(5, "COREPROF fps=30"));
  assert(permitLog(5, "COREPROF_RESILIENCE detail"));
  assert(locks == 0 && unlocks == 0);

  // Ordinary and VDEC lines share exactly 128 slots in the first second.
  for (unsigned i = 0; i < 128; ++i) {
    if (i % 2) assert(permitLog(5, "NEOSWAP_VDEC released=1"));
    else assert(permitLog(i % 3, "ordinary notice"));
  }
  assert(!permitLog(2, "ordinary notice"));
  assert(!permitLog(5, "NEOSWAP_VDEC released=1"));
  const unsigned budgetLocks = locks;
  assert(permitLog(5, "COREPROF fps=0"));
  assert(permitLog(5, "COREPROF_RESILIENCE detail"));
  assert(locks == budgetLocks);
  testNow = 1.999;
  assert(!permitLog(5, "NEOSWAP_VDEC released=1"));

  // At one second the shared budget renews; VDEC is never exempt from it.
  testNow = 2.0;
  for (unsigned i = 0; i < 128; ++i)
    assert(permitLog(5, "NEOSWAP_VDEC restored=1"));
  assert(!permitLog(5, "NEOSWAP_VDEC restored=1"));
  assert(!permitLog(0, "ordinary notice"));
  assert(lockDepth == 0 && locks == unlocks);
}
'''
compiler = shutil.which('clang++') or shutil.which('g++')
assert compiler is not None, 'C++ compiler required for production log budget behavior'
with tempfile.TemporaryDirectory(prefix='rpcs3-log-budget-') as temporary:
    source = Path(temporary) / 'log-budget.cpp'
    executable = Path(temporary) / 'log-budget'
    source.write_text(native_source)
    subprocess.run([compiler, '-std=c++20', '-Wall', '-Wextra', '-Werror', str(source), '-o', str(executable)], check=True)
    subprocess.run([str(executable)], check=True)

print('PASS: bounded centralized diagnostics, durable milestones, no launch-time cache deletion or boot polling')
