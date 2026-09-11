"""Compile actual patched JIT functions; exercise native MAP_JIT on macOS arm64.

Linux probes use VM/pthread substitutes to cover failures and per-thread scopes.
CI additionally writes, executes and rewrites ARM64 instructions in a real arena.
"""
import importlib.util
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

FILES = ('Utilities/JITIOS.cpp', 'Utilities/JITIOS.h', 'Utilities/JIT.h',
         'Utilities/JITLLVM.cpp', 'Utilities/JITASM.cpp',
         'rpcs3/Emu/Cell/SPUCommonRecompiler.cpp', 'rpcs3/Emu/System.cpp',
         'rpcs3/ios/RPCS3IOS.cpp')


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
        self.temp = tempfile.TemporaryDirectory(prefix='neostation-jit-test-')
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
        subprocess.run(['c++', '-std=c++20', '-Wall', '-Wextra', '-Werror',
                        '-pthread', str(source), '-o', str(binary)], check=True, timeout=60)
        subprocess.run([str(binary)], check=True, timeout=30)

    def code(self, native=False):
        text = (self.root / 'Utilities/JITIOS.cpp').read_text()
        header = (self.root / 'Utilities/JITIOS.h').read_text()
        prefix = r'''
#include <algorithm>
#include <atomic>
#include <cassert>
#include <cerrno>
#include <cstdint>
#include <cstring>
#include <limits>
#include <mutex>
#include <stdexcept>
#include <string>
#include <thread>
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
 u8* code = nullptr; u8* write_view = nullptr; u8* data = nullptr; usz capacity = 0;
 allocator code_allocator, data_allocator;
 u32 preparation_chunks = 0;
 arena_backend backend = arena_backend::legacy_debugger;
 bool expanded = false, prepared = false;
} g_arena;
std::mutex g_arena_mutex;
std::string last_error;
void set_error(std::string s) { last_error = s; }
u64 physical_memory_size() { return 0; }
usz choose_arena_capacity(u64, bool) { return test_capacity; }
usz page_size() { return 4096; }
bool legacy_debugger_is_ready() { return true; }
bool use_universal = false, protocol_fails = false;
arena_backend current_backend() {
 return use_universal ? arena_backend::universal_mirrored : arena_backend::legacy_debugger;
}
u64 protocol_call(u64 command, const void* address, usz size) {
 assert(command == 1 && address && size == test_capacity);
 return protocol_fails ? 0 : reinterpret_cast<uptr>(address);
}
'''
        if native:
            prefix += '#include <sys/mman.h>\n#include <dlfcn.h>\n#include <libkern/OSCacheControl.h>\n#include <mach/mach.h>\n'
        else:
            prefix += r'''
constexpr int PROT_READ = 1, PROT_WRITE = 2, PROT_EXEC = 4;
constexpr int MAP_PRIVATE = 2, MAP_ANON = 16, MAP_JIT = 128;
void* const MAP_FAILED = reinterpret_cast<void*>(-1);
void* const RTLD_DEFAULT = nullptr;
alignas(65536) u8 storage[test_capacity * 2];
alignas(65536) u8 detached_storage[test_capacity];
int maps = 0, unmaps = 0, fail_map = 0, view_deallocations = 0;
bool far_data = false, no_pthread = false, bad_view = false, remap_fails = false, protect_fails = false;
thread_local bool actual_executable = true;
thread_local int transitions = 0;
void pthread_switch(int executable) { actual_executable = executable; ++transitions; }
void* dlsym(void*, const char* name) {
 assert(std::string(name) == "pthread_jit_write_protect_np");
 return no_pthread ? nullptr : reinterpret_cast<void*>(&pthread_switch);
}
void* mmap(void* hint, usz size, int prot, int flags, int, int) {
 ++maps;
 assert(size == test_capacity);
 if (!hint) {
  if (fail_map == 1) { errno = EPERM; return MAP_FAILED; }
  if (flags & MAP_JIT) assert(prot == (PROT_READ | PROT_WRITE | PROT_EXEC));
  else assert(flags == (MAP_PRIVATE | MAP_ANON));
  return storage;
 }
 if (fail_map == 2) { errno = EPERM; return MAP_FAILED; }
 assert(maps == 2 && hint == storage + test_capacity);
 assert(flags == (MAP_PRIVATE | MAP_ANON) && prot == (PROT_READ | PROT_WRITE));
 return far_data ? reinterpret_cast<void*>(reinterpret_cast<uptr>(storage) + 0x200000000ull)
                 : storage + test_capacity;
}
int munmap(void*, usz size) { assert(size == test_capacity); ++unmaps; return 0; }
void sys_dcache_flush(void*, usz) {}
void sys_icache_invalidate(void*, usz) {}
using vm_address_t = uptr;
using vm_prot_t = int;
constexpr int VM_PROT_NONE = 0, VM_PROT_READ = 1, VM_PROT_WRITE = 2;
constexpr int VM_FLAGS_ANYWHERE = 1, VM_INHERIT_DEFAULT = 1, KERN_SUCCESS = 0;
int mach_task_self() { return 1; }
int vm_remap(int, vm_address_t* address, usz size, int, int flags, int,
             vm_address_t source, bool copy, vm_prot_t*, vm_prot_t*, int) {
 assert(size == test_capacity && source == reinterpret_cast<uptr>(storage));
 assert(!copy && flags == VM_FLAGS_ANYWHERE);
 *address = reinterpret_cast<uptr>(bad_view ? detached_storage : storage);
 return remap_fails ? 1 : 0;
}
int vm_protect(int, vm_address_t, usz, bool, int) { return protect_fails ? 1 : 0; }
int vm_deallocate(int, vm_address_t, usz) { ++view_deallocations; return 0; }
int mprotect(void*, usz, int) { return 0; }
'''
        prefix += 'using write_protect_fn = void (*)(int);\n'
        prefix += function(text, 'write_protect_fn write_protect_function()') + '\n'
        prefix += 'thread_local bool g_jit_executable = true;\n'
        for sig in ('bool write_protected()', 'void write_protect(bool',
                    'bool contains(', 'bool prepare_arena(bool', 'void* writable(', 'void flush('):
            prefix += function(text, sig) + '\n'
        prefix += function(header, 'class write_guard') + ';\n'
        return prefix

    def test_mapping_identity_cleanup_and_thread_scopes(self):
        self.run_cpp(self.code() + r'''
int main() {
 for (int failure = 1; failure <= 4; ++failure) {
  maps = unmaps = 0;
  fail_map = failure <= 2 ? failure : 0;
  far_data = failure == 3;
  use_universal = protocol_fails = failure == 4;
  assert(!prepare_arena(false));
  assert(!g_arena.prepared && g_arena.code == nullptr);
  assert(unmaps == (failure <= 2 ? failure - 1 : 2));
 }
 maps = unmaps = fail_map = 0; far_data = protocol_fails = false;
 assert(prepare_arena(false));
 assert(prepare_arena(false) && maps == 2);
 assert(!prepare_arena(true));
 assert(g_arena.preparation_chunks == 1);
 assert(writable(g_arena.code + 64, 8) == g_arena.code + 64);
 assert(writable(g_arena.code + test_capacity, 1) == nullptr);
 assert(writable(g_arena.code, test_capacity + 1) == nullptr);
 assert(writable(nullptr, 1) == nullptr);
 assert(writable(g_arena.code, 0) == nullptr);
 {
  write_guard outer;
  assert(!actual_executable);
  { write_guard inner; assert(!actual_executable); }
  assert(!actual_executable); // inner destruction must not enable execution
  std::thread worker([] {
   assert(actual_executable);
   try { write_guard guard; assert(!actual_executable); throw std::runtime_error("test"); }
   catch (...) {}
   assert(actual_executable);
  });
  worker.join();
  assert(!actual_executable);
 }
 assert(actual_executable && write_protected());
 actual_executable = false; // another runtime reused this thread
 int previous = transitions;
 write_protect(true);
 assert(actual_executable && transitions == previous + 1);
}
''')

    def test_ios_without_pthread_validates_shared_views(self):
        self.run_cpp(self.code() + r'''
int main() {
 no_pthread = true; use_universal = true;
 for (int failure = 0; failure < 3; ++failure) {
  maps = unmaps = view_deallocations = 0;
  bad_view = failure == 0;
  remap_fails = failure == 1;
  protect_fails = failure == 2;
  assert(!prepare_arena(false));
  assert(!g_arena.prepared);
  assert(unmaps == 2);
  assert(view_deallocations == (remap_fails ? 0 : 1));
 }
 maps = unmaps = 0; bad_view = remap_fails = protect_fails = false;
 assert(prepare_arena(false));
 assert(g_arena.code == storage && g_arena.write_view == storage);
 assert(g_arena.preparation_chunks == 1);
 { write_guard outer; { write_guard inner; } assert(!write_protected()); }
 assert(write_protected());
 assert(transitions == 0); // iOS must not depend on an absent macOS SPI
}
''')

    @unittest.skipUnless(platform.system() == 'Darwin' and platform.machine() == 'arm64',
                         'native Apple arm64 JIT execution runs in macOS CI')
    def test_native_arm64_write_execute_rewrite(self):
        self.run_cpp(self.code(native=True) + r'''
int main() {
 assert(prepare_arena(false));
 auto* entry = static_cast<u32*>(writable(g_arena.code, 12));
 assert(entry == reinterpret_cast<u32*>(g_arena.code));
 using fn = u64 (*)(u64);
 auto run = reinterpret_cast<fn>(g_arena.code);
 for (u32 add = 7; add <= 9; ++add) {
  {
   write_guard outer;
   { write_guard inner; entry[0] = 0x8b000400; } // add x0, x0, x0, lsl #1
   entry[1] = 0x91000000 | (add << 10);         // add x0, x0, #add
   entry[2] = 0xd65f03c0;                      // ret
   flush(entry, 12);
  }
  write_protect(true);
  assert(run(11) == 33 + add);
  std::thread executor([&] { write_protect(true); assert(run(11) == 33 + add); });
  executor.join();
 }
 munmap(g_arena.data, g_arena.capacity);
 munmap(g_arena.code, g_arena.capacity);
}
''')

    def test_patch_is_idempotent_and_has_no_fixed_or_tagged_address(self):
        before = {f: (self.root / f).read_bytes() for f in FILES}
        patcher.patch(self.root)
        self.assertEqual(before, {f: (self.root / f).read_bytes() for f in FILES})
        jit = (self.root / 'Utilities/JITIOS.cpp').read_text()
        for forbidden in ('0x7000000000', 'writable_code', 'MAP_FIXED |'):
            self.assertNotIn(forbidden, jit)
        arena = function(jit, 'bool prepare_arena(bool')
        self.assertNotIn('jit_vm_tag', arena)


if __name__ == '__main__':
    unittest.main()
