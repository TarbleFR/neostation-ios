#!/usr/bin/env python3
"""Executable regressions for the final selective v0.9 backport.

Policy, reservation and progress tests run on any C++20 host. The Apple ARM64
check executes and rewrites actual native instructions through the final V5
alias, but remains a macOS test, not iOS/debugserver/game validation.
"""
from __future__ import annotations
import hashlib
import importlib.util
import json
import platform
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = Path(sys.argv.pop(1)).resolve()
spec = importlib.util.spec_from_file_location('patch266', ROOT / 'build-utils/patch_rpcs3_build266_v09_core.py')
patcher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(patcher)
function = patcher.function


class Core266Tests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='neostation-266-')
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)

    def run_cpp(self, text: str, name: str = 'test') -> str:
        path = self.work / (name + '.cpp')
        path.write_text(text)
        output = self.work / name
        subprocess.run(['c++', '-std=c++20', '-Wall', '-Wextra', '-Werror',
                        '-pthread', '-I', str(SOURCE), '-I', str(SOURCE / 'rpcs3'),
                        '-I', str(self.work), str(path), '-o', str(output)],
                       check=True, timeout=60)
        return subprocess.check_output([str(output)], text=True, timeout=30)

    def test_final_hashes_and_patch_idempotence(self):
        manifest = json.loads(patcher.MANIFEST.read_text())
        for name, hashes in manifest['targets'].items():
            self.assertEqual(hashlib.sha256((SOURCE / name).read_bytes()).hexdigest(), hashes['after'], name)
        patcher.patch(SOURCE)  # No fetch or rewrite on an already-verified result.
        api = (SOURCE / 'rpcs3/ios/RPCS3IOS.cpp').read_text()
        info = json.loads(self.run_cpp('#include <cstdio>\n' + function(
            api, 'extern "C" const char* rpcs3_ios_build_info(void) noexcept') +
            '\nint main() { std::puts(rpcs3_ios_build_info()); }'))
        self.assertEqual(info['abi'], 30)
        self.assertEqual(info['neostation_jit'], 'NEOSTATION_DYNAMIC_JIT_V5')
        self.assertEqual(info['jit_backport'], patcher.REVISION)
        self.assertEqual(info['build266'], 'NEOSTATION_BUILD266_JIT_V09_SHADER_V1')

    def test_corrupted_preimage_fails_without_partial_writes(self):
        manifest = json.loads(patcher.MANIFEST.read_text())
        for name in manifest['targets']:
            target = self.work / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(SOURCE / name, target)
        target = self.work / 'Utilities/JITIOS.cpp'
        target.write_text(target.read_text() + '\n// unexpected drift\n')
        before = {name: (self.work / name).read_bytes() for name in manifest['targets']}
        with self.assertRaisesRegex(RuntimeError, 'preimage mismatch'):
            patcher.patch(self.work)
        self.assertEqual(before, {name: (self.work / name).read_bytes() for name in before})

    def test_upstream_capacity_allocator_cases(self):
        test = (SOURCE / 'rpcs3/ios/tests/JITArenaAllocatorTests.cpp').read_text()
        test = test.replace('"../../../Utilities/', '"Utilities/')
        self.run_cpp(test, 'upstream_allocator')

    def test_exact_progress_completion_block(self):
        source = (SOURCE / 'rpcs3/Emu/system_progress.cpp').read_text()
        start = source.index('const auto [text_new, ftotal_new, fdone_new, ftotal_bits_new, fknown_bits_new, ptotal_new, pdone_new] = get_state();')
        end = source.index('// Force-update every 20 seconds', start)
        (self.work / 'ProgressCompletionUnderTest.inc').write_text(source[start:end])
        self.run_cpp((SOURCE / 'rpcs3/ios/tests/NativeProgressCompletionTests.cpp').read_text(), 'progress')

    def test_real_reservation_search_with_simulated_mach_holes(self):
        source = (SOURCE / 'Utilities/JITIOS.cpp').read_text()
        constants = source[source.index('constexpr vm_address_t arena_address_begin'):source.index('u8* reserve_arena_layout')]
        text = RESERVATION_STUBS + constants
        text += function(source, 'u8* reserve_arena_layout(') + '\n'
        text += function(source, 'u8* reserve_code_data_layout(') + '\n' + RESERVATION_CASES
        self.run_cpp(text, 'reservation')

    def test_v5_reservation_has_no_forbidden_load_time_import_sources(self):
        source = (SOURCE / 'Utilities/JITIOS.cpp').read_text()
        self.assertNotIn('#include <os/log.h>', source)
        self.assertNotIn('os_log_error(', source)
        self.assertNotIn('::vm_map(', source)
        reservation = function(source, 'u8* reserve_arena_layout(')
        self.assertIn('MAP_PRIVATE | MAP_ANON', reservation)
        self.assertNotIn('MAP_FIXED | MAP_PRIVATE', reservation)
        self.assertIn('mapping == reinterpret_cast<void*>(candidate)', reservation)
        self.assertIn('::munmap(mapping, size)', reservation)

    def test_shader_checkpoint_order_optout_and_stop(self):
        render = (SOURCE / 'rpcs3/Emu/RSX/VK/VKGSRender.cpp').read_text()
        body = function(render, 'void VKGSRender::on_init_thread()')
        start = body.index('if (!Emu.IsStopped() && !g_cfg.video.disable_on_disk_shader_cache')
        end = body.index('\n#endif', start)
        self.assertLess(body.rindex('m_shaders_cache->load('), start)
        cache = (SOURCE / 'rpcs3/Emu/RSX/VK/VKProgramBuffer.h').read_text()
        self.assertIn('props, false, false,', function(cache, 'void add_pipeline_entry('))
        self.run_cpp(CHECKPOINT_STUBS + '\nvoid checkpoint() {\n' + body[start:end] + '\n}\n' + CHECKPOINT_CASES, 'checkpoint')
        disk = (SOURCE / 'rpcs3/Emu/RSX/VK/vkutils/device.cpp').read_text()
        saved = function(disk, 'void render_device::save_pipeline_cache() const')
        self.assertIn('fs::pending_file pending{path}', saved)
        self.assertIn('pending.commit()', saved)
        self.assertIn('pipelineCacheUUID', saved)
        self.assertIn('maximum_pipeline_cache_data_size', saved)

    @unittest.skipUnless(platform.system() == 'Darwin' and platform.machine() == 'arm64',
                         'Actual V5 Apple ARM64 executable-alias check runs in macOS CI')
    def test_native_v5_low_address_alias_write_execute_rewrite(self):
        source = (SOURCE / 'Utilities/JITIOS.cpp').read_text()
        state = function(source, 'struct arena_state') + ';\n'
        constants = source[source.index('constexpr int jit_vm_tag'):source.index('u8* reserve_arena_layout')]
        constants = '\n'.join(line for line in constants.splitlines()
                              if 'expanded_jit_arena_environment' not in line) + '\n'
        text = NATIVE_PREAMBLE + state + '\narena_state g_arena;\n' + constants
        for signature in ('u8* reserve_arena_layout(', 'u8* reserve_code_data_layout(',
                          'bool map_arena_region(', 'bool contains(', 'void discard_layout('):
            text += function(source, signature) + '\n'
        text += 'namespace rpcs3::ios::jit {\n'
        for signature in ('bool prepare_arena(u32', 'void* writable(', 'void flush('):
            text += function(source, signature) + '\n'
        text += '}\n' + NATIVE_CASES
        self.run_cpp(text, 'native_v5')


RESERVATION_STUBS = r'''
#include "Utilities/JITIOSLayoutPolicy.h"
#include <algorithm>
#include <cassert>
#include <vector>
using vm_address_t = std::uintptr_t;
using vm_size_t = std::size_t;
constexpr int PROT_NONE=0, MAP_PRIVATE=1, MAP_ANON=2, KERN_SUCCESS=0;
constexpr int jit_vm_tag=123;
void* const MAP_FAILED=reinterpret_cast<void*>(~std::uintptr_t{0});
int mach_task_self() { return 1; }
struct Range { vm_address_t a, b; };
std::vector<Range> holes, allocations;
unsigned maps=0, rollbacks=0;
void* mmap(void* hint, vm_size_t size, int prot, int flags, int fd, long offset) {
 assert(prot==PROT_NONE && flags==(MAP_PRIVATE|MAP_ANON));
 assert(fd==jit_vm_tag && offset==0);
 ++maps;
 const auto address=reinterpret_cast<vm_address_t>(hint);
 const Range want{address,address+size};
 bool allowed=false;
 for (auto h:holes) if (h.a<=want.a && want.b<=h.b) allowed=true;
 for (auto r:allocations) if (want.a<r.b && r.a<want.b) allowed=false;
 if (!allowed) return MAP_FAILED;
 allocations.push_back(want); return hint;
}
int release(vm_address_t address, vm_size_t size) {
 ++rollbacks;
 vm_size_t removed=0;
 allocations.erase(std::remove_if(allocations.begin(), allocations.end(), [&](Range r) {
   if (r.a>=address && r.b<=address+size) { removed+=r.b-r.a; return true; }
   return false;
 }),allocations.end());
 // The code must release only ranges it successfully reserved, never a hole,
 // an occupied foreign mapping, or an adjacent unrelated reservation.
 assert(removed==size); return KERN_SUCCESS;
}
int munmap(void* address, vm_size_t size) {
 return release(reinterpret_cast<vm_address_t>(address),size);
}
int vm_deallocate(int, vm_address_t address, vm_size_t size) {
 return release(address,size);
}
'''
RESERVATION_CASES = r'''
int main() {
 using namespace rpcs3::ios::jit;
 const auto B=arena_address_begin, E=arena_address_end;
 u8* data=nullptr; usz size=0;
 auto reset=[&](std::vector<Range> h) { holes=std::move(h); allocations.clear(); maps=rollbacks=0; };
 reset({{B,E}});
 auto code=reserve_code_data_layout(512*mib,data,size);
 assert(reinterpret_cast<vm_address_t>(code)==B);
 assert(data==code+512*mib && size==512*mib && maps==1);
 // Occupied initial address is skipped without overwriting it.
 reset({{B+64*mib,E}});
 code=reserve_code_data_layout(512*mib,data,size);
 assert(reinterpret_cast<vm_address_t>(code)==B+64*mib && size==512*mib);
 // No 1 GiB hole: retain 512 MiB RX, use a nearby separate 256 MiB data gap.
 reset({{B,B+512*mib},{B+768*mib,B+1024*mib}});
 code=reserve_code_data_layout(512*mib,data,size);
 assert(reinterpret_cast<vm_address_t>(code)==B);
 assert(reinterpret_cast<vm_address_t>(data)==B+768*mib && size==256*mib);
 auto total=vm_size_t{0}; for(auto r:allocations) total+=r.b-r.a;
 assert(total==768*mib);
 // A distant data hole outside ADRP reach is NOT accepted; no partial leak.
 reset({{B,B+512*mib},{B+8ull*1024*mib,B+8ull*1024*mib+256*mib}});
 code=reserve_code_data_layout(512*mib,data,size);
 assert(code==nullptr && data==nullptr && size==0 && allocations.empty());
 // Exhaustion and invalid windows fail closed without overriding foreign VM.
 reset({});
 assert(reserve_code_data_layout(256*mib,data,size)==nullptr && allocations.empty());
 maps=0;
 assert(reserve_arena_layout(0)==nullptr);
 assert(reserve_arena_layout(256*mib,B-1,E)==nullptr);
 assert(reserve_arena_layout(256*mib,B,E+1)==nullptr);
 assert(reserve_code_data_layout(2048*mib,data,size)==nullptr && maps==0);
}
'''
CHECKPOINT_STUBS = r'''
#include <cassert>
enum class shader_mode { recompiler, interpreter_only };
struct Emulator { bool stopped=false; bool IsStopped() const { return stopped; } } Emu;
struct Config { struct Video { bool disable_on_disk_shader_cache=false; shader_mode shadermode=shader_mode::recompiler; } video; } g_cfg;
struct Device { int checkpoints=0; void checkpoint_pipeline_cache() { ++checkpoints; } } device;
Device* m_device=&device;
struct Log { void notice(const char*) {} } rsx_log;
'''
CHECKPOINT_CASES = r'''
int main() {
 checkpoint(); assert(device.checkpoints==1);
 Emu.stopped=true; checkpoint(); assert(device.checkpoints==1);
 Emu.stopped=false; g_cfg.video.disable_on_disk_shader_cache=true;
 checkpoint(); assert(device.checkpoints==1);
 g_cfg.video.disable_on_disk_shader_cache=false; g_cfg.video.shadermode=shader_mode::interpreter_only;
 checkpoint(); assert(device.checkpoints==1);
 g_cfg.video.shadermode=shader_mode::recompiler;
 checkpoint(); assert(device.checkpoints==2);
}
'''
NATIVE_PREAMBLE = r'''
#include "Utilities/JITIOS.h"
#include "Utilities/JITArenaAllocator.h"
#include "Utilities/JITIOSLayoutPolicy.h"
#include <algorithm>
#include <cassert>
#include <cerrno>
#include <cstring>
#include <mutex>
#include <string>
#include <libkern/OSCacheControl.h>
#include <mach/mach.h>
#include <mach/vm_statistics.h>
#include <sys/mman.h>
#include <unistd.h>
using namespace rpcs3::ios::jit;
std::mutex g_arena_mutex;
std::string native_test_last_error;
void set_error(std::string message) { native_test_last_error=std::move(message); }
u64 physical_memory_size() { return 4ull*1024*1024*1024; }
usz page_size() { return static_cast<usz>(::getpagesize()); }
bool legacy_debugger_is_ready() { return true; }
arena_backend current_backend() { return arena_backend::legacy_debugger; }
u64 protocol_call(u64, const void*, usz) { assert(false); return 0; }
'''
NATIVE_CASES = r'''
int main() {
 assert(rpcs3::ios::jit::prepare_arena(0u));
 assert(g_arena.prepared && g_arena.capacity==256*mib);
 assert(reinterpret_cast<vm_address_t>(g_arena.code)>=arena_address_begin);
 assert(reinterpret_cast<vm_address_t>(g_arena.code)+g_arena.capacity<=arena_address_end);
 assert(g_arena.writable_code && g_arena.data && g_arena.data_capacity>=256*mib);
 using fn=u64(*)(u64);
 auto* entry=static_cast<u32*>(rpcs3::ios::jit::writable(g_arena.code,12));
 auto run=reinterpret_cast<fn>(g_arena.code);
 for (u32 add=7;add<=9;++add) {
  entry[0]=0x8b000400; entry[1]=0x91000000|(add<<10); entry[2]=0xd65f03c0;
  rpcs3::ios::jit::flush(g_arena.code,12);
  assert(run(11)==33+add);
 }
 // A different capacity cannot silently replace live executable memory.
 assert(!rpcs3::ios::jit::prepare_arena(1024u));
 discard_layout(g_arena.code,g_arena.capacity,g_arena.data,g_arena.data_capacity,
                reinterpret_cast<vm_address_t>(g_arena.writable_code));
}
'''

if __name__ == '__main__':
    unittest.main()
