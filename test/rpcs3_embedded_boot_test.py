"""Execute regression probes from the pinned Core's actual C++ source.

Usage: python3 test/rpcs3_embedded_boot_test.py /path/to/rpcs3
No Apple SDK is needed: OS mapping calls are outside the tested functions.
"""
import importlib.util
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = Path(sys.argv.pop(1)).resolve()
FILES = ('rpcs3/Emu/Cell/SPUCommonRecompiler.cpp',
         'rpcs3/Emu/Cell/PPUThread.cpp', 'rpcs3/ios/RPCS3IOS.cpp',
         'Utilities/JITIOS.cpp', 'Utilities/JITArenaAllocator.h')
spec = importlib.util.spec_from_file_location('boot_patch', ROOT / 'build-utils/patch_rpcs3_embedded_boot.py')
patcher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(patcher)


def function(text, signature):
    start = text.index(signature)
    opening = text.index('{', start)
    depth = 1
    index = opening + 1
    while depth:
        depth += (text[index] == '{') - (text[index] == '}')
        index += 1
    return text[start:index]


class EmbeddedBootTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='rpcs3-boot-test-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for name in FILES:
            target = self.root / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(SOURCE / name, target)

    def run_cpp(self, body):
        source = self.root / 'probe.cpp'
        source.write_text(body)
        binary = self.root / 'probe'
        subprocess.run([shutil.which('c++') or 'c++', '-std=c++20', '-Wall',
                        '-Wextra', '-Werror', '-I', str(self.root), str(source),
                        '-o', str(binary)], check=True, timeout=60)
        subprocess.run([str(binary)], check=True, timeout=15)

    def test_temporary_allocations_reclaimed_across_sessions(self):
        text = (self.root / 'Utilities/JITIOS.cpp').read_text()
        types = self.root / 'util/types.hpp'
        types.parent.mkdir()
        types.write_text('#include <cstddef>\n#include <cstdint>\nusing usz = std::size_t; using uptr = std::uintptr_t; using u8 = unsigned char;\n')
        body = r'''
#include "Utilities/JITArenaAllocator.h"
#include <cassert>
#include <mutex>
#include <string>
using rpcs3::ios::jit::arena_allocator;
struct arena_state {
 u8* code; u8* data; usz capacity;
 arena_allocator code_allocator, data_allocator;
 usz runtime_code_bytes = 0, runtime_data_bytes = 0;
 usz live_code_bytes = 0, live_data_bytes = 0;
};
std::mutex g_arena_mutex;
u8 code[4096], data[4096];
arena_state g_arena{code, data, 4096, arena_allocator(4096), arena_allocator(4096)};
void set_error(std::string) { assert(false && "unexpected allocator error"); }
'''
        body += function(text, 'bool contains(') + '\n'
        body += function(text, 'void release_allocation(') + '\n'
        body += function(text, 'void reset_runtime(') + '\n'
        body += r'''
int main() {
 using rpcs3::ios::jit::arena_range;
 arena_range permanent{};
 assert(g_arena.code_allocator.allocate_highest(128, 16, permanent));
 g_arena.live_code_bytes = 128;
 for (int session = 0; session < 1000; ++session) {
  arena_range runtime{}, temporary{}, temp_data{};
  assert(g_arena.code_allocator.allocate_lowest(512, 1, runtime));
  assert(runtime.offset == 0);
  g_arena.runtime_code_bytes = 512;
  g_arena.live_code_bytes += 512;
  assert(g_arena.code_allocator.allocate_highest(768, 16, temporary));
  assert(g_arena.data_allocator.allocate_highest(512, 16, temp_data));
  g_arena.live_code_bytes += 768;
  g_arena.live_data_bytes += 512;
  release_allocation(true, code + temporary.offset, temporary.size);
  release_allocation(false, data + temp_data.offset, temp_data.size);
  reset_runtime();
  assert(g_arena.code_allocator.free_bytes() == 4096 - 128);
  assert(g_arena.data_allocator.free_bytes() == 4096);
  assert(g_arena.live_code_bytes == 128);
  assert(g_arena.live_data_bytes == 0);
 }
}
'''
        self.run_cpp(body)

    def test_warm_cache_respects_on_demand_policy(self):
        patcher.patch(self.root)
        text = (self.root / FILES[0]).read_text()
        block = text[text.index('\t// NEOSTATION_EMBEDDED_SPU_ON_DEMAND'):text.index('\tatomic_t<usz> fnext{};', text.index('\t// NEOSTATION_EMBEDDED_SPU_ON_DEMAND'))]
        condition = 'g_cfg.core.spu_cache && !spu_precompilation_enabled && cache && !defer_existing_spu_cache'
        self.assertIn(condition, text)
        body = r'''
#define RPCS3_IOS 1
#include <cassert>
#include <deque>
struct spu_program {};
struct { struct { bool llvm_precompilation, spu_cache; } core; } g_cfg;
struct { void notice(const char*) {} } spu_log;
struct Cache {
 int reads = 0;
 std::deque<spu_program> get() { ++reads; return std::deque<spu_program>(83); }
 explicit operator bool() const { return true; }
};
void probe(bool precompile) {
 g_cfg.core.llvm_precompilation = precompile;
 g_cfg.core.spu_cache = true;
 Cache cache;
 bool spu_precompilation_enabled = false;
'''
        body += block
        body += f'bool records_cache = {condition};\n'
        body += r'''
 assert(cache.reads == (precompile ? 1 : 0));
 assert(func_list.size() == (precompile ? 83 : 0));
 assert(records_cache == precompile);
}
int main() { probe(false); probe(true); }
'''
        self.run_cpp(body)

    def test_universal_arena_is_allocated_by_debugserver(self):
        patcher.patch(self.root)
        jit_text = (self.root / 'Utilities/JITIOS.cpp').read_text()
        prepare = function(jit_text, 'bool prepare_arena(bool expanded) noexcept')
        self.assertIn('NEOSTATION_UNIVERSAL_DEBUGSERVER_RX', prepare)
        self.assertIn('protocol_call(command_prepare_region, nullptr, capacity)', prepare)
        self.assertIn('static_cast<vm_address_t>(prepared_address)', prepare)
        self.assertIn('VM_INHERIT_DEFAULT', prepare)
        self.assertIn('VM_PROT_READ | VM_PROT_WRITE', prepare)
        self.assertIn('g_arena.code = code;', prepare)
        self.assertIn('g_arena.data = data;', prepare)
        self.assertIn('g_arena.preparation_chunks = 1;', prepare)
        self.assertNotIn('arena_prepare_chunk_count(capacity)', prepare)
        api_text = (self.root / 'rpcs3/ios/RPCS3IOS.cpp').read_text()
        self.assertIn('RPCS3 LLVM JIT self-test entry=%p', api_text)

    def test_patch_is_idempotent(self):
        patcher.patch(self.root)
        first = {f: (self.root / f).read_bytes() for f in FILES}
        patcher.patch(self.root)
        self.assertEqual(first, {f: (self.root / f).read_bytes() for f in FILES})

    def test_source_drift_rejected_before_any_write(self):
        ppu = self.root / FILES[1]
        ppu.write_text('Unexpected upstream implementation')
        first = {f: (self.root / f).read_bytes() for f in FILES}
        with self.assertRaises(ValueError):
            patcher.patch(self.root)
        self.assertEqual(first, {f: (self.root / f).read_bytes() for f in FILES})


if __name__ == '__main__':
    unittest.main()
