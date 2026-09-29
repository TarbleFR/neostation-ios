// Compile against the exact materialized RPCS3 allocator, not a replacement.
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
    // Heap -> mapped growth preserves every initialized old byte.
    p=rsx::aligned_allocator::malloc<64>(128); assert(p && !stats().live_bytes);
    memset(p,0x31,128);
    p=rsx::aligned_allocator::realloc<64>(p,128,2*MiB); assert(p);
    for(size_t n=0;n<128;n++) assert(((unsigned char*)p)[n]==0x31);
    assert(stats().live_bytes==2*MiB);
    memset(p,0xa6,2*MiB);
    // Mapped -> mapped, then mapped -> ordinary heap on quota exhaustion.
    p=rsx::aligned_allocator::realloc<64>(p,2*MiB,3*MiB); assert(p);
    for(size_t n=0;n<2*MiB;n++) assert(((unsigned char*)p)[n]==0xa6);
    assert(stats().live_blocks==1 && stats().live_bytes==3*MiB);
    p=rsx::aligned_allocator::realloc<64>(p,3*MiB,9*MiB); assert(p);
    for(size_t n=0;n<2*MiB;n++) assert(((unsigned char*)p)[n]==0xa6);
    assert(stats().live_blocks==0);
    rsx::aligned_allocator::free(p);
    // Preallocation/mapping failure falls back before any pointer is published.
    for(int stage=1;stage<=3;stage++) {
        NeoSwap_TestFailNext(stage);
        p=rsx::aligned_allocator::malloc<64>(MiB);
        assert(p && !stats().live_bytes); memset(p,0x72,MiB);
        rsx::aligned_allocator::free(p);
    }
    for(int cycle=0;cycle<20;cycle++) {
        p=rsx::aligned_allocator::malloc<65536>(MiB+64);
        assert(p && (reinterpret_cast<uintptr_t>(p)%65536)==0 && stats().live_bytes>0);
        assert(NeoSwap_Configure(nullptr,&c)==NEOSWAP_BUSY);
        rsx::aligned_allocator::free(p);
        assert(!stats().live_blocks);
    }
    c.capacity_bytes=0; assert(!NeoSwap_Configure(nullptr,&c));
    p=rsx::aligned_allocator::malloc<64>(2*MiB);
    assert(p && !stats().live_bytes); rsx::aligned_allocator::free(p);
    assert(rmdir(dir)==0);
    puts("PASS RPCS3 actual allocator: disabled, heap/mapped growth, quota/IO fallback, 20 release cycles");
}
