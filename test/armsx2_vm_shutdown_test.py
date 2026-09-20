#!/usr/bin/env python3
"""Execute the production ARMSX2 worker's VM-cleanup block in a C++ harness.

This is a lifecycle test, NOT an iPhone/JIT/GPU test. Device backends are stubs;
the cleanup block is extracted unchanged from ARMSX2Core.mm. The VM state enum,
HasValidVM and Initialize rejection guard are taken from the pinned upstream
checkout in CI (the exact inspected snippets below permit an offline run).

The negative control executes the old cleanup and must reproduce the actual
reported error. The production cleanup must close resources exactly once,
before CPU-thread release, and permit consecutive game boots.
"""
from __future__ import annotations
import argparse
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
REVISION = '8b5fad23dc290660aa394e75b0fd23e31099eaec'
STATE_ENUM = '''enum class VMState
{
    Shutdown,
    Initializing,
    Running,
    Paused,
    Resetting,
    Stopping,
};'''
HAS_VALID_VM = '''bool VMManager::HasValidVM()
{
    const VMState state = s_state.load(std::memory_order_acquire);
    return (state >= VMState::Running && state <= VMState::Resetting);
}'''
INIT_GUARD = '''if (s_state.load(std::memory_order_acquire) != VMState::Shutdown)
{
    Error::SetString(error, TRANSLATE_STR("VMManager", "The virtual machine is already running."));
    return VMBootResult::StartupFailure;
}'''
OLD_CLEANUP = '''if (VMManager::HasValidVM()) {
  const VMState current=VMManager::GetState();
  if (current!=VMState::Stopping && current!=VMState::Shutdown)
    VMManager::SetState(VMState::Stopping);
  VMManager::Shutdown(false);
}'''


def braced(text: str, marker: str, *, start: int = 0) -> str:
    """Extract a balanced source block at a unique, known signature."""
    pos = text.index(marker, start)
    opening = text.index('{', pos)
    depth = 0
    for end in range(opening, len(text)):
        if text[end] == '{':
            depth += 1
        elif text[end] == '}':
            depth -= 1
            if depth == 0:
                return text[pos:end + 1]
    raise AssertionError(f'Unbalanced source block: {marker}')


def compact(text: str) -> str:
    return re.sub(r'\s+', '', text)


def upstream_contract(source: Path | None) -> tuple[str, str, str]:
    if source is None:
        print('Upstream contract: offline snippets from ' + REVISION)
        return STATE_ENUM, HAS_VALID_VM, INIT_GUARD
    revision = subprocess.check_output(
        ['git', '-C', str(source), 'rev-parse', 'HEAD'], text=True).strip()
    assert revision == REVISION, f'Unexpected upstream revision: {revision}'
    h = (source / 'pcsx2/VMManager.h').read_text()
    cpp = (source / 'pcsx2/VMManager.cpp').read_text()
    enum = braced(h, 'enum class VMState') + ';'
    valid = braced(cpp, 'bool VMManager::HasValidVM()')
    init = braced(cpp, 'VMBootResult VMManager::Initialize(')
    guard = braced(init, 'if (s_state.load(std::memory_order_acquire) != VMState::Shutdown)')
    for actual, expected in ((enum, STATE_ENUM), (valid, HAS_VALID_VM), (guard, INIT_GUARD)):
        assert compact(actual) == compact(expected), 'Upstream lifecycle contract changed'
    shutdown = braced(cpp, 'void VMManager::Shutdown(bool save_resume_state)')
    for required in ('SPU2::Close();', 'DoCDVDclose();', 'FileMcd_EmuClose();',
                     's_state.store(VMState::Shutdown, std::memory_order_release);'):
        assert required in shutdown, f'Upstream Shutdown lost {required}'
    thread_shutdown = braced(cpp, 'void VMManager::Internal::CPUThreadShutdown()')
    assert 'SysMemory::Release();' in thread_shutdown
    assert 's_state.store' not in thread_shutdown
    assert not re.search(r'(?<!::)\bShutdown\(', thread_shutdown)
    print('Upstream contract: verified against live pinned checkout ' + revision)
    return enum, valid, guard


def harness(cleanup: str, contract: tuple[str, str, str], negative: bool) -> str:
    enum, valid, guard = contract
    return r'''
#include <atomic>
#include <iostream>
#include <stdexcept>
#include <string>
#define TRANSLATE_STR(context, text) text
struct Error {
  std::string message;
  static void SetString(Error* e, const char* s) { e->message = s; }
};
enum class VMBootResult { StartupSuccess, StartupFailure };
''' + enum + r'''
static std::atomic<VMState> s_state{VMState::Shutdown};
static int resources=0, closes=0, cpu_releases=0, early_releases=0;
namespace VMManager {
  VMState GetState() { return s_state.load(std::memory_order_acquire); }
  void SetState(VMState s) { s_state.store(s, std::memory_order_release); }
  bool HasValidVM();
  VMBootResult Initialize(Error* error) {
''' + guard + r'''
    resources=1;
    s_state.store(VMState::Paused, std::memory_order_release);
    return VMBootResult::StartupSuccess;
  }
  void Shutdown(bool) {
    if (!resources) throw std::runtime_error("Duplicate/uninitialized VM shutdown");
    // Backend stand-in: upstream Shutdown closes the game devices then stores Shutdown.
    ++closes;
    resources=0;
    s_state.store(VMState::Shutdown, std::memory_order_release);
  }
  namespace Internal {
    void CPUThreadShutdown() {
      if (resources || GetState()!=VMState::Shutdown) ++early_releases;
      ++cpu_releases;
      // Matches upstream: releasing CPU resources does not reset s_state.
    }
  }
}
''' + valid + r'''
void production_cleanup() {
''' + cleanup + r'''
}
void require(bool condition, const char* message) {
  if (!condition) throw std::runtime_error(message);
}
int main() {
  try {
    s_state=VMState::Stopping;
    require(!VMManager::HasValidVM(), "Stopping must be excluded by upstream HasValidVM");
    s_state=VMState::Shutdown;
    Error error;
''' + (r'''
    require(VMManager::Initialize(&error)==VMBootResult::StartupSuccess, "First boot failed");
    VMManager::SetState(VMState::Running);
    VMManager::SetState(VMState::Stopping);
    production_cleanup();
    VMManager::Internal::CPUThreadShutdown();
    require(closes==0 && resources==1 && early_releases==1, "Old skip not reproduced");
    require(VMManager::Initialize(&error)==VMBootResult::StartupFailure, "Old second boot unexpectedly succeeded");
    require(error.message=="The virtual machine is already running.", "Wrong reproduced error");
    std::cout << "NEGATIVE CONTROL: ARMSX2 boot failed: " << error.message << "\n";
''' if negative else r'''
    production_cleanup();
    require(closes==0, "Shutdown without a boot is not allowed");
    // Each source state is completed, including a stop already raised by the core.
    for (VMState state : {VMState::Running, VMState::Paused, VMState::Resetting, VMState::Stopping}) {
      require(VMManager::Initialize(&error)==VMBootResult::StartupSuccess, "Boot rejected");
      VMManager::SetState(state);
      const int before=closes;
      production_cleanup();
      require(closes==before+1 && !resources && VMManager::GetState()==VMState::Shutdown,
              "VM shutdown skipped or incomplete");
      VMManager::Internal::CPUThreadShutdown();
      production_cleanup();
      require(closes==before+1, "Duplicate stop closed the VM twice");
    }
    // Same game or another game follows the same VM entry contract.
    for (int game=0; game<100; ++game) {
      require(VMManager::Initialize(&error)==VMBootResult::StartupSuccess, "Consecutive boot refused");
      VMManager::SetState(game%2 ? VMState::Paused : VMState::Running);
      VMManager::SetState(VMState::Stopping);
      production_cleanup();
      require(VMManager::GetState()==VMState::Shutdown && !resources, "Stopping was not finalized");
      VMManager::Internal::CPUThreadShutdown();
    }
    // An initialization rejected before game resources exist must not call Shutdown.
    const int before=closes;
    s_state=VMState::Initializing;
    production_cleanup();
    require(closes==before, "Initializing VM was incorrectly destroyed");
    s_state=VMState::Shutdown;
    production_cleanup();
    require(closes==104 && cpu_releases==104 && early_releases==0, "Cleanup order/count violated");
    std::cout << "PASS: 100 consecutive boots; running/paused/resetting/stopping exits; "
                 "idle/initializing guards; duplicate stop; VM-before-CPU teardown\n";
''') + r'''
    return 0;
  } catch (const std::exception& e) {
    std::cerr << "FAIL: " << e.what() << "\n";
    return 1;
  }
}
'''


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--upstream', type=Path)
    parser.add_argument('--core', type=Path, default=ROOT / 'packages/armsx2_internal_bridge/core/ARMSX2Core.mm')
    args = parser.parse_args()
    assert json.loads((ROOT / 'build-utils/armsx2/source.json').read_text())['revision'] == REVISION
    text = args.core.read_text()
    start = text.index('catch (...) { fail("Unknown ARMSX2 native exception."); }')
    start = text.index('\n', start) + 1
    end = text.index('    s_vmThreadActive.store(false', start)
    cleanup = text[start:end]
    assert 'VMManager::Shutdown(false)' in cleanup
    # The real worker must finish VM teardown before freeing its CPU arena.
    cpu_release = text.index('VMManager::Internal::CPUThreadShutdown();', end)
    assert end < cpu_release
    contract = upstream_contract(args.upstream)
    compiler = shutil.which('clang++') or shutil.which('g++')
    if not compiler:
        raise SystemExit('C++ compiler required; do not silently skip lifecycle tests')
    with tempfile.TemporaryDirectory(prefix='armsx2-vm-lifecycle-') as directory:
        root = Path(directory)
        for name, code, negative in [('old', OLD_CLEANUP, True), ('production', cleanup, False)]:
            src = root / (name + '.cpp')
            binary = root / name
            src.write_text(harness(code, contract, negative))
            subprocess.run([compiler, '-std=c++17', '-Wall', '-Wextra', '-Werror', str(src), '-o', str(binary)], check=True)
            subprocess.run([str(binary)], check=True, timeout=10)


if __name__ == '__main__':
    main()
