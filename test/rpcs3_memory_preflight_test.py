"""Guard the RPCS3 firmware path against false virtual-memory preflight failures."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class MemoryPreflightTests(unittest.TestCase):
    def test_preflight_is_non_invasive_and_never_reserves_core_layout(self):
        compiler = shutil.which('c++')
        self.assertIsNotNone(compiler, 'C++ compiler required')
        source = r'''
#include "Rpcs3MemoryPreflight.h"
#include <cassert>
#include <cstddef>
using neostation::rpcs3::probe_virtual_layout;

int main() {
  unsigned map_calls = 0;
  unsigned unmap_calls = 0;
  auto map = [&](void*, std::size_t) -> void* {
    ++map_calls;
    return nullptr;
  };
  auto unmap = [&](void*, std::size_t) {
    ++unmap_calls;
  };

  // The compatibility preflight must not reserve or scan RPCS3's huge address
  // space before dlopen. The real Core initialization is the authoritative test.
  assert(probe_virtual_layout(map, unmap));
  assert(map_calls == 0);
  assert(unmap_calls == 0);
  assert(probe_virtual_layout());
}
'''
        with tempfile.TemporaryDirectory(prefix='rpcs3-vm-') as directory:
            path = Path(directory)
            (path / 'test.cpp').write_text(source)
            subprocess.run([
                compiler,
                '-std=c++17',
                '-Wall',
                '-Wextra',
                '-Werror',
                '-I',
                str(ROOT / 'packages/rpcs3_internal_bridge/ios/Classes'),
                str(path / 'test.cpp'),
                '-o',
                str(path / 'test'),
            ], check=True, timeout=60)
            subprocess.run([str(path / 'test')], check=True, timeout=15)


if __name__ == '__main__':
    unittest.main()
