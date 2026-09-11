# Exercise the Build 238 RPCS3 iOS JIT arena contract.
#
# The regression probe uses the actual patched prepare_arena/writable/flush
# functions. Simulated probes validate Universal debugserver ownership and
# cleanup. Apple arm64 CI also executes rewritten instructions through the
# legacy RX view to prove RW/RX alias coherence without MAP_JIT.
from pathlib import Path
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

FILES = ('Utilities/JITIOS.cpp',)


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
        self.temp = tempfile.TemporaryDirectory(prefix='neostation-jit-v3-test-')
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
        subprocess.run([str(binary)], check=True, timeout=30)

    def code(self, native=False):
        text = (self.root / 'Utilities/JITIOS.cpp').read_text()
        prefix = r'''
#include <algorithm>
#include <cassert>
#include <cerrno>
#include <cstdint>
#include <cstring>
#include <limits>
#include <mutex>
#include <string>
using u8 = unsigned char;
using u32 = std::uint32_t;
using u64 = std::uint64_t;
using uptr = std::uintptr_t;
using usz = std::size_t;
enum class arena_backend { legacy_debugger, universal_mirrored };
constexpr u64 command_prepare_region = 1;
constexpr usz test_capacity = 65536;
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
usz page_size() { return 4096; }
bool legacy_debugger_is_ready() { return true; }
bool use_universal = false;
bool protocol_fails = false;
'''
        if native:
            prefix += r'''
#include <libkern/OSCacheControl.h>
#include <mach/mach.h>
#include <sys/mman.h>
u64 protocol_call(u64, const void*, usz) { return 0; }
'''
        else:
            prefix += r'''
constexpr int PROT_READ = 1, PROT_WRITE = 2, PROT_EXEC = 4;
constexpr int MAP_PRIVATE = 2, MAP_ANON = 16;
void* const MAP_FAILED = reinterpret_cast<void*>(-1);
alignas(65536) u8 storage[test_capacity * 2];
alignas(65536) u8 detached_storage[test_capacity];
int maps = 0, unmaps = 0, code_deallocations = 0, alias_deallocations = 0;
int fail_map = 0;
bool far_data = false, bad_view = false, remap_fails = false, protect_fails = false;
void* mmap(void* hint, usz size, int prot, int flags, int, int) {
 ++maps;
 assert(size == test_capacity);
 assert(flags == (MAP_PRIVATE | MAP_ANON));
 if (!hint) {
  assert(!use_universal);
  if (fail_map == 1) { errno = EPERM; return MAP_FAILED; }
  assert(prot == (PROT_READ | PROT_WRITE));
  return storage;
 }
 if (fail_map == 2) { errno = EPERM; return MAP_FAILED; }
 assert(hint == storage + test_capacity);
 assert(prot == (PROT_READ | PROT_WRITE));
 return far_data
     ? reinterpret_cast<void*>(reinterpret_cast<uptr>(storage) + 0x200000000ull)
     : storage + test_capacity;
}
int munmap(void*, usz size) {
 assert(size == test_capacity);
 ++unmaps;
 return 0;
}
void sys_dcache_flush(void*, usz) {}
void sys_icache_invalidate(void*, usz) {}
using vm_address_t = uptr;
using vm_size_t = usz;
using vm_prot_t = int;
using kern_return_t = int;
constexpr int VM_PROT_NONE = 0, VM_PROT_READ = 1, VM_PROT_WRITE = 2;
constexpr int VM_FLAGS_ANYWHERE = 1, VM_INHERIT_DEFAULT = 1, KERN_SUCCESS = 0;
int mach_task_self() { return 1; }
int vm_remap(int, vm_address_t* address, vm_size_t size, int, int flags, int,
             vm_address_t source, bool copy, vm_prot_t*, vm_prot_t*, int inherit) {
 assert(size == test_capacity);
 assert(source == reinterpret_cast<uptr>(storage));
 assert(!copy && flags == VM_FLAGS_ANYWHERE && inherit == VM_INHERIT_DEFAULT);
 *address = reinterpret_cast<uptr>(bad_view ? detached_storage : storage);
 return remap_fails ? 1 : KERN_SUCCESS;
}
int vm_protect(int, vm_address_t, vm_size_t size, bool, int prot) {
 assert(size == test_capacity);
 assert(prot == (VM_PROT_READ | VM_PROT_WRITE));
 return protect_fails ? 1 : KERN_SUCCESS;
}
int vm_deallocate(int, vm_address_t address, vm_size_t size) {
 assert(size == test_capacity);
 if (address == reinterpret_cast<uptr>(storage)) ++code_deallocations;
 else ++alias_deallocations;
 return KERN_SUCCESS;
}
int mprotect(void*, usz size, int prot) {
 assert(size == test_capacity);
 assert(prot == (PROT_READ | PROT_EXEC));
 return 0;
}
u64 protocol_call(u64 command, const void* address, usz size) {
 assert(command == command_prepare_region);
 assert(use_universal);
 assert(address == nullptr);
 assert(size == test_capacity);
 return protocol_fails ? 0 : reinterpret_cast<uptr>(storage);
}
'''
        prefix += r'''
arena_backend current_backend() {
 return use_universal ? arena_backend::universal_mirrored : arena_backend::legacy_debugger;
}
'''
        for sig in ('bool contains(', 'bool prepare_arena(bool', 'void* writable(', 'void flush('):
            prefix += function(text, sig) + '\n'
        return prefix

    def test_universal_uses_debugserver_owned_rx_mapping(self):
        self.run_cpp(self.code() + r'''
int main() {
 use_universal = true;

 protocol_fails = true;
 assert(!prepare_arena(false));
 assert(!g_arena.prepared);
 protocol_fails = false;

 far_data = true;
 maps = unmaps = code_deallocations = alias_deallocations = 0;
 assert(!prepare_arena(false));
 assert(!g_arena.prepared);
 assert(unmaps == 1 && code_deallocations == 1);
 far_data = false;

 remap_fails = true;
 maps = unmaps = code_deallocations = alias_deallocations = 0;
 assert(!prepare_arena(false));
 assert(unmaps == 1 && code_deallocations == 1);
 remap_fails = false;

 protect_fails = true;
 maps = unmaps = code_deallocations = alias_deallocations = 0;
 assert(!prepare_arena(false));
 assert(unmaps == 1 && code_deallocations == 2 && alias_deallocations == 0);
 protect_fails = false;

 bad_view = true;
 maps = unmaps = code_deallocations = alias_deallocations = 0;
 assert(!prepare_arena(false));
 assert(unmaps == 1 && code_deallocations == 1 && alias_deallocations == 1);
 bad_view = false;

 maps = unmaps = code_deallocations = alias_deallocations = 0;
 assert(prepare_arena(false));
 assert(g_arena.prepared);
 assert(g_arena.code == storage);
 assert(g_arena.data == storage + test_capacity);
 assert(g_arena.preparation_chunks == 1);
 assert(writable(g_arena.code + 64, 8) == storage + 64);
 assert(writable(g_arena.code + test_capacity, 1) == nullptr);
 assert(!prepare_arena(true));
}
''')

    def test_legacy_mapping_is_dynamic_and_relocation_bounded(self):
        self.run_cpp(self.code() + r'''
int main() {
 use_universal = false;

 fail_map = 1;
 assert(!prepare_arena(false));
 assert(!g_arena.prepared);

 fail_map = 2;
 maps = unmaps = 0;
 assert(!prepare_arena(false));
 assert(unmaps == 1);

 fail_map = 0;
 far_data = true;
 maps = unmaps = 0;
 assert(!prepare_arena(false));
 assert(unmaps == 2);

 far_data = false;
 maps = unmaps = 0;
 assert(prepare_arena(false));
 assert(g_arena.prepared);
 assert(g_arena.code == storage);
 assert(g_arena.data == storage + test_capacity);
 assert(g_arena.preparation_chunks == 0);
 assert(maps == 2);
}
''')

    @unittest.skipUnless(
        platform.system() == 'Darwin' and platform.machine() == 'arm64',
        'native Apple arm64 execution runs in macOS CI',
    )
    def test_native_arm64_legacy_alias_write_execute_rewrite(self):
        self.run_cpp(self.code(native=True) + r'''
int main() {
 use_universal = false;
 assert(prepare_arena(false));
 auto* entry = static_cast<u32*>(writable(g_arena.code, 12));
 assert(entry != nullptr);
 using fn = u64 (*)(u64);
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
 munmap(g_arena.data, g_arena.capacity);
 munmap(g_arena.code, g_arena.capacity);
}
''')

    def test_patch_is_idempotent_and_isolated(self):
        before = {f: (self.root / f).read_bytes() for f in FILES}
        patcher.patch(self.root)
        self.assertEqual(before, {f: (self.root / f).read_bytes() for f in FILES})
        jit = (self.root / 'Utilities/JITIOS.cpp').read_text()
        arena = function(jit, 'bool prepare_arena(bool')
        self.assertIn('NEOSTATION_DYNAMIC_JIT_V3', arena)
        self.assertIn('protocol_call(command_prepare_region, nullptr, capacity)', arena)
        self.assertIn('g_arena.writable_code = writable_code;', arena)
        self.assertNotIn('MAP_FIXED', arena)
        self.assertNotIn('MAP_JIT', arena)
        self.assertNotIn('pthread_jit_write_protect_np', arena)
        self.assertNotIn('jit_vm_tag', arena)


if __name__ == '__main__':
    unittest.main()
