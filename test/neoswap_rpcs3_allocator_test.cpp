// Execute the exact materialized RPCS3 allocator. Fast acquisition has no file
// backing fallback: the original aligned heap owns refused allocations.
#include <algorithm>
#include <cassert>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstddef>
#include <unistd.h>
using usz = std::size_t;
#define ensure(condition, ...) assert(condition)
#define RPCS3_IOS 1
#include "rpcs3/Emu/RSX/Common/aligned_malloc.hpp"
static NeoSwapStats stats() {
    NeoSwapStats s{}; s.struct_size=sizeof(s); assert(!NeoSwap_Snapshot(&s)); return s;
}
int main() {
    constexpr size_t MiB=1024*1024;
    char dir[]="/tmp/neoswap-rpcs3-XXXXXX"; assert(mkdtemp(dir));
    const auto* api=NeoSwap_GetAPI(1);
    NeoSwapAPI bad=*api; bad.abi_version=99;
    assert(neostation::swap::install(&bad)==NEOSWAP_INVALID);
    assert(neostation::swap::install(api)==0);
    assert(neostation::swap::install(api)==0);
    NeoSwapConfig c{sizeof(c),1,8*MiB,0,MiB,1,0};
    void* p=rsx::aligned_allocator::malloc<64>(MiB);
    assert(p && !stats().live_bytes); rsx::aligned_allocator::free(p);
    assert(!NeoSwap_Configure(dir,&c));
    p=rsx::aligned_allocator::malloc<64>(128); assert(p);
    memset(p,0x31,128);
    p=rsx::aligned_allocator::realloc<64>(p,128,2*MiB); assert(p);
    for(size_t n=0;n<128;n++) assert(((unsigned char*)p)[n]==0x31);
    assert(!stats().live_bytes && !stats().allocated_disk_bytes);
    memset(p,0xa6,2*MiB);
    p=rsx::aligned_allocator::realloc<64>(p,2*MiB,3*MiB); assert(p);
    for(size_t n=0;n<2*MiB;n++) assert(((unsigned char*)p)[n]==0xa6);
    p=rsx::aligned_allocator::realloc<64>(p,3*MiB,9*MiB); assert(p);
    for(size_t n=0;n<2*MiB;n++) assert(((unsigned char*)p)[n]==0xa6);
    assert(!stats().live_blocks); rsx::aligned_allocator::free(p);
    // A file fault remains unconsumed by FAST; a subsequent explicit legacy
    // request consumes it. This proves no open/preallocation/map was attempted.
    for(int stage=1;stage<=3;stage++) {
        NeoSwap_TestFailNext(stage);
        p=rsx::aligned_allocator::malloc<64>(MiB);
        assert(p && !stats().live_bytes); memset(p,0x72,MiB);
        rsx::aligned_allocator::free(p);
        void* legacy=nullptr;
        assert(api->allocate(0,NEOSWAP_CPU_DATA,MiB,64,&legacy)!=NEOSWAP_OK && !legacy);
    }
    // Legacy ownership remains strict while the fast caller uses ordinary RAM.
    void* legacy=nullptr;
    assert(!api->allocate(0,NEOSWAP_CPU_DATA,MiB,64,&legacy) && legacy);
    memset(legacy,0x55,MiB);
    for(int cycle=0;cycle<20;cycle++) {
        p=rsx::aligned_allocator::malloc<65536>(MiB+64);
        assert(p && (reinterpret_cast<uintptr_t>(p)%65536)==0);
        assert(stats().live_blocks==1 && stats().live_bytes==MiB);
        rsx::aligned_allocator::free(p);
        assert(((unsigned char*)legacy)[0]==0x55);
    }
    assert(api->release(legacy)==NEOSWAP_OK && !stats().live_blocks);
    c.capacity_bytes=0; assert(!NeoSwap_Configure(nullptr,&c));
    p=rsx::aligned_allocator::malloc<64>(2*MiB);
    assert(p && !stats().live_bytes); rsx::aligned_allocator::free(p);
    assert(rmdir(dir)==0);
    puts("PASS RPCS3 actual allocator: ordinary growth/data/alignment, fast file refusal without IO, legacy ownership isolated, 20 allocation/free cycles");
}
