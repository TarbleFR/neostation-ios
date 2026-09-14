#!/usr/bin/env python3
"""Source contracts, exhaustive SHUFB selector model and executable wait tests.

The C++ harness compiles the two actual patched wait functions with fake
clock/driver objects. It tests ordering and cancellation, not iPhone performance.
"""
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile


def function(text: str, signature: str) -> str:
    start = text.index(signature)
    brace = text.index('{', start)
    depth = 0
    for end in range(brace, len(text)):
        depth += (text[end] == '{') - (text[end] == '}')
        if depth == 0:
            return text[start:end + 1]
    raise AssertionError('Unclosed function: ' + signature)


HARNESS = r'''
#include <cassert>
#include <cstdint>
#include <functional>
#include <iostream>
using u32 = uint32_t; using u64 = uint64_t; using RsxSemaphore = u32;
#define RPCS3_IOS 1
u64 now = 0;
u64 get_system_time() { return now; }
namespace cpu_flag { constexpr int again=1, dbg_global_pause=2, exit=4; }
namespace rsx {
namespace pipeline_state { constexpr int fragment_program_needs_rehash=1; }
constexpr int pipe_flush_interrupt=1;
namespace FIFO { enum class state { lock_wait }; }
}
namespace flush_queue_state { constexpr int flushing=1, deadlock=2; }
namespace flip_request { constexpr int emu_requested=1; }
template <class T> struct atomic_t { T value{}; T load() const { return value; } };
atomic_t<RsxSemaphore> label;
namespace vm { template <class T> const T& _ref(u32) { return label; } }
struct Config { struct Video { u64 driver_recovery_timeout=1000; } video; } g_cfg;
struct Log {
 int errors=0, warnings=0;
 template <class... T> void error(const char*, T...) { ++errors; }
 template <class... T> void warning(const char*, T...) { ++warnings; }
} rsx_log;
std::function<void()> step;
namespace utils {
template <class T> void spin_on_cacheline_once(const T&, u32, u64 interval) {
 now += interval; if (step) step(); assert(now < 100000);
}
}
namespace rpcs3::ios { void record_rsx_semaphore_wait(u64, bool) {} }
struct Release { void release(bool) {} };
struct context {
 Release sync_point_request;
 int m_graphics_state=0, state=0, syncs=0, services=0, wakes=0;
 bool external_interrupt_lock=false, stopped=false;
 u32 label_addr=0x60000000;
 struct Counters { u64 idle_time=0; } performance_counters;
 u32 semaphore_offset_406e() { return label_addr+0x10; }
 u32 semaphore_context_dma_406e() { return 0; }
 void flush_fifo() {}
 void fifo_wake_delay(int=0) { ++wakes; }
 bool test_stopped() { return stopped; }
 void sync() { ++syncs; }
 void on_semaphore_acquire_wait() { ++services; }
 void cpu_wait(int) { now+=100; if(step) step(); assert(now<100000); }
};
u32 get_address(u32 address, u32) { return address; }
#define RSX(ctx) (ctx)
#define REGS(ctx) (ctx)
// ACQUIRE
struct VKGSRender;
struct Zcull { int updates=0; bool reenter=false; void update(VKGSRender*); };
struct DMA { int updates=0; void update() { ++updates; } };
struct Pending { bool value=false; bool pending() const { return value; } };
struct VKGSRender {
 bool m_servicing_semaphore_wait=false;
 u32 m_eng_interrupt_mask=0, async_flip_requested=0, m_queue_status=0;
 u32 m_semaphore_wait_polls=0;
 u64 m_next_semaphore_service=0;
 int tasks=0;
 Pending m_flush_requests;
 Zcull* zcull_ctrl=nullptr;
 DMA* m_host_dma_ctrl=nullptr;
 void do_local_task(rsx::FIFO::state) { ++tasks; }
 void on_semaphore_acquire_wait();
};
void Zcull::update(VKGSRender* renderer) {
 ++updates; if (reenter) renderer->on_semaphore_acquire_wait();
}
// SERVICE
void reset() { now=0; label.value=10; step={}; rsx_log={}; g_cfg.video.driver_recovery_timeout=1000; }
int main() {
 // 1. Completed acquire does not wait or rewrite the label.
 reset(); context ready; label.value=11; semaphore_acquire(&ready,0,11);
 assert(now==0 && ready.services==0 && label.value==11);
 // 2. A delayed producer releases the actual label.
 reset(); context delayed; step=[&]{ if(now>=300) label.value=11; };
 semaphore_acquire(&delayed,0,11); assert(now>=300 && delayed.wakes==1);
 // 3. An expired driver deadline must not advance the guest FIFO.
 reset(); context late; step=[&]{ if(now>=5000) label.value=11; };
 semaphore_acquire(&late,0,11);
 assert(now>=5000 && label.value==11 && late.syncs==1 && rsx_log.errors>0);
 // 4. Permanently stalled producer remains cancellable.
 reset(); context cancelled; step=[&]{ if(now>=5000) cancelled.stopped=true; };
 semaphore_acquire(&cancelled,0,11);
 assert(label.value==10 && (cancelled.state & cpu_flag::again) && cancelled.wakes==0);
 // 5. External pause keeps progress and resumes without forging labels.
 reset(); context paused; paused.external_interrupt_lock=true;
 step=[&]{ if(now>=600) { paused.external_interrupt_lock=false; label.value=11; } };
 semaphore_acquire(&paused,0,11); assert(now>=600 && paused.wakes==1);
 // 6. Disabled driver timeout still observes a producer release.
 reset(); g_cfg.video.driver_recovery_timeout=0; context untimed;
 step=[&]{ if(now>=5000) label.value=11; };
 semaphore_acquire(&untimed,0,11); assert(untimed.syncs==0 && untimed.wakes==1);
 // 7. Vulkan servicing is reentrancy-safe, rate-limited and services flushes.
 reset(); VKGSRender renderer; Zcull z; DMA d;
 renderer.zcull_ctrl=&z; renderer.m_host_dma_ctrl=&d; z.reenter=true;
 renderer.m_eng_interrupt_mask=rsx::pipe_flush_interrupt;
 for(int i=0;i<64;++i) renderer.on_semaphore_acquire_wait();
 assert(z.updates==1 && d.updates==1 && renderer.tasks==64);
 now=1000; for(int i=0;i<16;++i) renderer.on_semaphore_acquire_wait();
 assert(z.updates==2 && d.updates==2 && !renderer.m_servicing_semaphore_wait);
 renderer.m_queue_status=flush_queue_state::flushing; now=2000;
 for(int i=0;i<64;++i) renderer.on_semaphore_acquire_wait();
 assert(z.updates==2 && d.updates==2);
 std::cout << "7 source-extracted C++ wait scenarios: OK\n";
}
'''


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit('usage: rpcs3_build265_core_test.py <rpcs3-source-root>')
    source = Path(sys.argv[1])
    read = lambda name: (source / name).read_text()
    sem = read('rpcs3/Emu/RSX/NV47/HW/nv406e.cpp')
    vk = read('rpcs3/Emu/RSX/VK/VKGSRender.cpp')
    vdec = read('rpcs3/Emu/Cell/Modules/cellVdec.cpp')
    spu = read('rpcs3/Emu/Cell/SPULLVMRecompiler.cpp')
    info = read('rpcs3/ios/RPCS3IOS.cpp')
    assert 'NEOSTATION_BUILD265_RSX_SPU_VIDEO_V1' in info
    assert 'FIFO preserved' in sem and 'atomic_sema.store' not in sem
    assert 'out_queue.size() < out_max' in vdec
    assert 'out_queue.size() + 1 >= vdec->out_max' in vdec
    assert 'std::lock_guard conversion_lock{vdec->conversion_mutex}' in vdec
    assert 'av_image_copy_to_buffer' in vdec
    assert 'in_f == AV_PIX_FMT_YUV420P && out_f == AV_PIX_FMT_YUV420P' in vdec
    assert 'perm_only && idx_selects_single' in spu
    # Independent scalar SPU semantics vs the emitted constant lookup/TBL1.
    lut = [0]*12 + [255,255,128,128]
    for seed in range(128):
        a = [(seed*7+i*13)&255 for i in range(16)]
        b = [(seed*17+i*3)&255 for i in range(16)]
        for selector in range(256):
            expected = ((0 if selector<0xc0 else 255 if selector<0xe0 else 128)
                        if selector&128 else (b if selector&16 else a)[15-(selector&15)])
            actual = lut[selector>>4] if selector&128 else (b if selector&16 else a)[(selector^15)&15]
            assert expected == actual
    print('32768 SPU selector model comparisons: OK')
    cpp = HARNESS.replace('// ACQUIRE', function(sem, 'void semaphore_acquire('))
    cpp = cpp.replace('// SERVICE', function(vk, 'void VKGSRender::on_semaphore_acquire_wait()'))
    compiler = shutil.which('clang++') or shutil.which('g++')
    assert compiler, 'C++ compiler required for wait regression tests'
    with tempfile.TemporaryDirectory(prefix='neostation-build265-') as temp:
        path = Path(temp)
        (path/'test.cpp').write_text(cpp)
        subprocess.run([compiler, '-std=c++17', '-O2', str(path/'test.cpp'), '-o', str(path/'test')], check=True)
        subprocess.run([str(path/'test')], check=True, timeout=10)
    print('RPCS3 Build 265 core contracts: OK')

if __name__ == '__main__':
    main()
