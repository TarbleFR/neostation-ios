"""Execute the production virtual-memory preflight, including denial cleanup."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class MemoryPreflightTests(unittest.TestCase):
    def test_production_layout_and_failures(self):
        compiler = shutil.which('c++')
        self.assertIsNotNone(compiler, 'C++ compiler required')
        source = r'''
#include "Rpcs3MemoryPreflight.h"
#include <cassert>
#include <map>
#include <utility>
using neostation::rpcs3::probe_virtual_layout;
constexpr std::uintptr_t gib = UINT64_C(1) << 30;
int main() {
  // Run the real mapper as well: reserve virtual addresses, never physical RAM.
  assert(probe_virtual_layout());
  for (int fail_at = 0; fail_at <= 3; ++fail_at) {
    std::map<std::uintptr_t, std::size_t> live;
    unsigned accepted = 0, calls = 0;
    auto map = [&](void* target, std::size_t size) -> void* {
      ++calls;
      assert(calls < 100); // Missing entitlement must not scan 128 TiB.
      auto address = reinterpret_cast<std::uintptr_t>(target);
      assert(address >= 12 * gib && address % (4 * gib) == 0);
      if (accepted >= static_cast<unsigned>(fail_at)) return MAP_FAILED;
      for (auto [other, length] : live) {
        if (address < other + length && other < address + size) return MAP_FAILED;
      }
      live[address] = size;
      ++accepted;
      return target;
    };
    auto unmap = [&](void* target, std::size_t size) {
      auto address = reinterpret_cast<std::uintptr_t>(target);
      assert(live.at(address) == size);
      live.erase(address);
    };
    assert(probe_virtual_layout(map, unmap) == (fail_at == 3));
    assert(live.empty()); // Including failure after one or two reservations.
  }
  unsigned released = 0;
  // mmap can return a different address when the hint is unavailable. Never
  // mistake that for success, and never leak or replace the existing mapping.
  assert(!probe_virtual_layout(
      [](void*, std::size_t) { return reinterpret_cast<void*>(4 * gib); },
      [&](void* ptr, std::size_t) { assert(ptr == reinterpret_cast<void*>(4 * gib)); ++released; }));
  assert(released > 0 && released < 100);
}
'''
        with tempfile.TemporaryDirectory(prefix='rpcs3-vm-') as directory:
            path = Path(directory)
            (path / 'test.cpp').write_text(source)
            subprocess.run([compiler, '-std=c++17', '-Wall', '-Wextra', '-Werror',
                            '-I', str(ROOT / 'packages/rpcs3_internal_bridge/ios/Classes'),
                            str(path / 'test.cpp'), '-o', str(path / 'test')], check=True, timeout=60)
            subprocess.run([str(path / 'test')], check=True, timeout=15)


if __name__ == '__main__':
    unittest.main()
