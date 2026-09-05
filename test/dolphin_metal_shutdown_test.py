"""Exercise the shipped Metal teardown against asynchronous completion callbacks.

The C++ harness executes the production patch's methods. Its command-buffer
stand-in runs real worker threads, but this is not an iPhone/Metal GPU test.
"""
from __future__ import annotations

import importlib.util
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]

# Relevant methods from pinned Dolphin 7cac54161659421ed95c2cd1c0b0746539a4cd38.
# SPDX-License-Identifier: GPL-2.0-or-later
PINNED_BACKEND = """void Metal::VideoBackend::Shutdown()
{
  ShutdownShared();

  g_state_tracker.reset();
  ObjectCache::Shutdown();
}
"""
PINNED_TRACKER = """Metal::StateTracker::~StateTracker()
{
  FlushEncoders();
  std::lock_guard<std::mutex> lock(m_backref->mtx);
  m_backref->state_tracker = nullptr;
}

void Metal::StateTracker::WaitForFlushedEncoders()
{
  [m_last_render_cmdbuf waitUntilCompleted];
}
"""


def method(source: str, signature: str) -> str:
    start = source.index(signature)
    return source[start:source.index('\n}', start) + 2]


def patch_fixture(directory: Path):
    folder = directory / 'Source/Core/VideoBackends/Metal'
    folder.mkdir(parents=True)
    (folder / 'MTLMain.mm').write_text(PINNED_BACKEND)
    (folder / 'MTLStateTracker.h').write_text('  void WaitForFlushedEncoders();\n')
    (folder / 'MTLStateTracker.mm').write_text(PINNED_TRACKER)
    spec = importlib.util.spec_from_file_location(
        'dolphin_metal_patch', ROOT / 'build-utils/patch_dolphin_internal_core_v2.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    module.patch_metal_shutdown(directory)
    return folder, module


HARNESS = r'''
#include <atomic>
#include <cassert>
#include <future>
#include <memory>
#include <mutex>
#include <thread>

std::atomic<bool> owners_alive{false};
std::atomic<int> calls{0};
bool inject_late_callback = false;
bool inject_active_older_callback = false;
std::promise<void> older_callback_entered;
std::promise<void> release_older_callback;
auto older_callback_entered_future = older_callback_entered.get_future().share();
std::thread older_worker;

namespace Metal {
class StateTracker;
struct Backref { std::mutex mtx; StateTracker* state_tracker; };
void Complete(const std::shared_ptr<Backref>&);
class StateTracker {
public:
  StateTracker() : m_backref(std::make_shared<Backref>()) {
    m_backref->state_tracker = this;
  }
  ~StateTracker();
  void PrepareForShutdown();
  void FlushEncoders() {
    if (!queued) return;
    queued = false;
    // A completion enters while the GPU drain is running. Holding the backref
    // mutex across WaitForFlushedEncoders would deadlock this actual worker.
    worker = std::thread([ref = m_backref] { Complete(ref); });
  }
  void WaitForFlushedEncoders() {
    if (worker.joinable()) worker.join();
    // Models another older completion queued just as the GPU wait returns.
    older_completion = m_backref;
    if (inject_active_older_callback) {
      older_worker = std::thread([ref = m_backref] {
        std::lock_guard<std::mutex> lock(ref->mtx);
        assert(ref->state_tracker && owners_alive.load());
        older_callback_entered.set_value();
        release_older_callback.get_future().wait();
        assert(owners_alive.load());
        ++calls;
      });
      older_callback_entered_future.wait();
    }
  }
  bool queued = false;
  std::thread worker;
  std::shared_ptr<Backref> m_backref;
  std::shared_ptr<Backref> older_completion;
};
std::unique_ptr<StateTracker> g_state_tracker;
std::shared_ptr<Backref> previous_backref;

void Complete(const std::shared_ptr<Backref>& ref) {
  if (!ref) return;
  std::lock_guard<std::mutex> lock(ref->mtx);
  if (ref->state_tracker) {
    // The real callback accesses PerfQuery::ReturnResults and its framebuffer.
    assert(owners_alive.load());
    ++calls;
  }
}

class VideoBackend {
public:
  void Shutdown();
  void ShutdownShared() {
    owners_alive = false;
    if (inject_late_callback) {
      // Force the exact old interleaving: query/framebuffer destroyed while
      // an older completion is entering and the tracker still exists.
      Complete(previous_backref);
    }
  }
};
struct ObjectCache {
  static void Shutdown() { assert(!g_state_tracker && !owners_alive.load()); }
};
}
'''

EXERCISE = r'''
int main() {
  Metal::VideoBackend backend;
  for (int console = 0; console < 40; ++console) {
    owners_alive = true;
    Metal::g_state_tracker = std::make_unique<Metal::StateTracker>();
    auto ref = Metal::g_state_tracker->m_backref;
    Metal::previous_backref = ref;
    Metal::g_state_tracker->queued = true;
    inject_late_callback = true;
    int before = calls.load();
    backend.Shutdown();
    assert(calls.load() == before + 1);
    assert(!Metal::g_state_tracker && !ref->state_tracker);
    // A callback from the previous console must not touch the next session's
    // query objects, even when their globals are populated again.
    owners_alive = true;
    Metal::Complete(ref);
    assert(calls.load() == before + 1);
    owners_alive = false;
  }
  // A partial initialization can have no tracker at all.
  inject_late_callback = false;
  backend.Shutdown();
  // A callback from an older buffer can already hold the backref when the
  // final buffer's wait returns. Teardown must wait for that callback too.
  owners_alive = true;
  Metal::g_state_tracker = std::make_unique<Metal::StateTracker>();
  inject_active_older_callback = true;
  int before = calls.load();
  auto shutdown = std::async(std::launch::async, [&] { backend.Shutdown(); });
  // WaitForFlushedEncoders signals only after the older callback holds the
  // mutex. Its owner cannot be destroyed until we let that callback finish.
  older_callback_entered_future.wait();
  assert(owners_alive.load());
  assert(shutdown.wait_for(std::chrono::seconds(0)) != std::future_status::ready);
  release_older_callback.set_value();
  shutdown.get();
  older_worker.join();
  assert(calls.load() == before + 1 && !owners_alive.load());
}
'''


class DolphinMetalShutdownTests(unittest.TestCase):
    def test_patch_is_idempotent_for_the_pinned_backend(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            folder, module = patch_fixture(directory)
            expected = {p.name: p.read_text() for p in folder.iterdir()}
            module.patch_metal_shutdown(directory)
            self.assertEqual(expected, {p.name: p.read_text() for p in folder.iterdir()})

    def test_callbacks_finish_before_owner_destruction_and_late_callbacks_are_ignored(self):
        compiler = shutil.which('c++') or shutil.which('clang++')
        if not compiler:
            self.skipTest('C++ compiler required')
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            folder, _ = patch_fixture(directory)
            tracker = (folder / 'MTLStateTracker.mm').read_text()
            shutdown = (folder / 'MTLMain.mm').read_text()
            common = HARNESS + '\n' + method(tracker, 'Metal::StateTracker::~StateTracker()')
            common += '\n' + method(tracker, 'void Metal::StateTracker::PrepareForShutdown()')
            for name, implementation in (('patched', shutdown), ('old', PINNED_BACKEND)):
                cpp = directory / f'{name}.cpp'
                executable = directory / name
                cpp.write_text(common + '\n' + implementation + EXERCISE)
                result = subprocess.run(
                    [compiler, '-std=c++17', '-pthread', str(cpp), '-o', str(executable)],
                    capture_output=True, text=True, timeout=60)
                self.assertEqual(result.returncode, 0, result.stderr)
                result = subprocess.run([str(executable)], capture_output=True, text=True, timeout=10)
                if name == 'patched':
                    self.assertEqual(result.returncode, 0, result.stderr)
                else:
                    # The unpatched backend must fail this same controlled
                    # interleaving, so the test demonstrates the actual race.
                    self.assertNotEqual(result.returncode, 0)


if __name__ == '__main__':
    unittest.main()
