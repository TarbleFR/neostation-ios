# Exercise the Build 240 RPCS3 iOS JIT arena contract.
#
# Build 240 restores a contiguous code/data reservation and prepares the exact
# RX code pages through Universal StikJIT. Apple arm64 CI also executes rewritten
# instructions through the final RX view to prove RW/RX alias coherence.
from pathlib import Path
import json
import platform
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = Path(sys.argv.pop(1)).resolve()
sys.path.insert(0, str(ROOT / 'build-utils'))
import patch_rpcs3_jit_memory as patcher

FILES = ('Utilities/JITIOS.cpp', 'rpcs3/ios/RPCS3IOS.cpp')


def function(text, signature):
    start = text.index(signature)
    end = text.index('{', start) + 1
    depth = 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[start:end]


class JitMemoryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='neostation-jit-v4-test-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for name in FILES:
            dest = self.root / name
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(SOURCE / name, dest)
        patcher.patch(self.root)

    def run_cpp(self, body):
        source = self.root / 'probe.cpp'
        source.write_text(body)
        binary = self.root / 'probe'
        subprocess.run(
            ['c++', '-std=c++20', '-Wall', '-Wextra', '-Werror',
             '-pthread', str(source), '-o', str(binary)],
            check=True,
            timeout=60,
        )
        return subprocess.run([str(binary)], check=True, timeout=30,
                              capture_output=True, text=True).stdout

    def test_patch_id_survives_compilation_and_existing_abi(self):
        api = (self.root / 'rpcs3/ios/RPCS3IOS.cpp').read_text()
        body = '#include <cstdio>\n'
        body += function(api, 'extern "C" const char* rpcs3_ios_build_info(void) noexcept')
        body += '\nint main() { std::puts(rpcs3_ios_build_info()); }\n'
        info = json.loads(self.run_cpp(body))
        self.assertEqual(info['neostation_jit'], patcher.PATCH_ID)
        self.assertEqual(info['abi'], 30)
        self.assertEqual(info['jit'], 'sealed-arena')

    def test_universal_contract_is_contiguous_and_prepares_exact_rx_pages(self):
        jit = (self.root / 'Utilities/JITIOS.cpp').read_text()
        arena = function(jit, 'bool prepare_arena(bool')
        self.assertIn('NEOSTATION_DYNAMIC_JIT_V4', arena)
        self.assertIn('const usz total_size = capacity * 2;', arena)
        self.assertIn('MAP_FIXED | MAP_PRIVATE | MAP_ANON', arena)
        self.assertIn('layout + capacity', arena)
        self.assertIn('arena_prepare_chunk_count(capacity)', arena)
        self.assertIn('protocol_call(command_prepare_region, chunk, chunk_length)', arena)
        self.assertIn('g_arena.writable_code = writable_code;', arena)
        self.assertIn('VM_INHERIT_SHARE', arena)
        self.assertNotIn('protocol_call(command_prepare_region, nullptr, capacity)', arena)
        self.assertNotIn('MAP_JIT', arena)
        self.assertNotIn('pthread_jit_write_protect_np', arena)

    @unittest.skipUnless(
        platform.system() == 'Darwin' and platform.machine() == 'arm64',
        'native Apple arm64 execution runs in macOS CI',
    )
    def test_native_arm64_legacy_alias_write_execute_rewrite(self):
        text = (self.root / 'Utilities/JITIOS.cpp').read_text()
        body = r'''
#include <algorithm>
#include <cassert>
#include <cerrno>
#include <cstdint>
#include <cstring>
#include <limits>
#include <mutex>
#include <string>
#include <libkern/OSCacheControl.h>
#include <mach/mach.h>
#include <sys/mman.h>
#include <unistd.h>
using u8 = unsigned char;
using u32 = std::uint32_t;
using u64 = std::uint64_t;
using uptr = std::uintptr_t;
using usz = std::size_t;
enum class arena_backend { legacy_debugger, universal_mirrored };
constexpr u64 command_prepare_region = 1;
constexpr usz test_capacity = 65536;
constexpr usz arena_prepare_chunk_size = 16384;
struct allocator { void reset(usz) {} };
struct arena_state {
 u8* code = nullptr;
 u8* writable_code = nullptr;
 u8* data = nullptr;
 usz capacity = 0;
 u32 preparation_chunks = 0;
 allocator code_allocator, data_allocator;
 arena_backend backend = arena_backend::legacy_debugger;
 bool expanded = false, prepared = false;
} g_arena;
std::mutex g_arena_mutex;
std::string last_error;
void set_error(std::string s) { last_error = std::move(s); }
u64 physical_memory_size() { return 0; }
usz choose_arena_capacity(u64, bool) { return test_capacity; }
usz page_size() { return static_cast<usz>(::getpagesize()); }
bool legacy_debugger_is_ready() { return true; }
arena_backend current_backend() { return arena_backend::legacy_debugger; }
u32 arena_prepare_chunk_count(usz capacity) {
 return static_cast<u32>((capacity + arena_prepare_chunk_size - 1) / arena_prepare_chunk_size);
}
usz arena_prepare_chunk_length(usz capacity, u32 chunk) {
 const usz offset = static_cast<usz>(chunk) * arena_prepare_chunk_size;
 return offset < capacity ? std::min(arena_prepare_chunk_size, capacity - offset) : 0;
}
u64 protocol_call(u64, const void*, usz) { return 0; }
'''
        for sig in ('bool contains(', 'bool prepare_arena(bool', 'void* writable(', 'void flush('):
            body += function(text, sig) + '\n'
        body += r'''
int main() {
 assert(prepare_arena(false));
 assert(g_arena.prepared);
 assert(g_arena.data == g_arena.code + g_arena.capacity);
 assert(g_arena.writable_code != nullptr);
 using fn = u64 (*)(u64);
 auto* entry = static_cast<u32*>(writable(g_arena.code, 12));
 assert(entry != nullptr);
 auto run = reinterpret_cast<fn>(g_arena.code);
 for (u32 add = 7; add <= 9; ++add) {
  entry[0] = 0x8b000400;                // add x0, x0, x0, lsl #1
  entry[1] = 0x91000000 | (add << 10);  // add x0, x0, #add
  entry[2] = 0xd65f03c0;                // ret
  flush(g_arena.code, 12);
  assert(run(11) == 33 + add);
 }
 vm_deallocate(mach_task_self(),
               reinterpret_cast<vm_address_t>(g_arena.writable_code),
               g_arena.capacity);
 munmap(g_arena.code, g_arena.capacity * 2);
}
'''
        self.run_cpp(body)

    def test_patch_is_idempotent_and_isolated(self):
        before = {name: (self.root / name).read_bytes() for name in FILES}
        patcher.patch(self.root)
        self.assertEqual(before, {name: (self.root / name).read_bytes() for name in FILES})
        arena = function(
            (self.root / 'Utilities/JITIOS.cpp').read_text(),
            'bool prepare_arena(bool',
        )
        self.assertNotIn('jit_vm_tag', arena)
        self.assertNotIn('write_protect_function', arena)


if __name__ == '__main__':
    unittest.main()
