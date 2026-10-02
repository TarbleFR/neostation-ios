// Behavioral tests of the production broker with injected donor operations.
// The fake pool is not a physical-memory/process-ownership proof. The separate
// macOS kernel probe covers the same small-request path with a real donor PID.
#include "NeoSwap.h"
#include "NeoSwapHost.h"
#include "Donation/Pool.h"
#include <algorithm>
#include <cassert>
#include <cstddef>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <thread>
#include <vector>
#include <unistd.h>
#ifdef NEOSWAP_CPU_WITH_CORE
using usz = std::size_t;
#define RPCS3_IOS 1
#define ensure(condition, ...) assert(condition)
#include "rpcs3/Emu/RSX/Common/aligned_malloc.hpp"
#endif

namespace fake {
bool ready = false, fail_release = false;
uint64_t serial = 0;
struct Allocation { void* pointer; uint64_t bytes; };
std::map<uint64_t, Allocation> live;
}
namespace neostation::donation {
void pool_snapshot(PoolSnapshot& out) noexcept {
    out = {};
    if (fake::ready) {
        out.state = PoolState::verified;
        out.prepared_bytes = 5ULL << 30;
        out.donor_count = 1;
    }
    for (const auto& [token, item] : fake::live) { (void)token; out.live_bytes += item.bytes; ++out.live_blocks; }
}
Result pool_acquire(uint64_t bytes, uint64_t alignment, void** out, uint64_t* token) noexcept {
    *out = nullptr; *token = 0;
    if (!fake::ready) return {Stage::pool_unready, -1};
    void* pointer = nullptr;
    if (posix_memalign(&pointer, alignment, bytes)) return {Stage::pool_limit, -1};
    *token = ++fake::serial; *out = pointer;
    fake::live.emplace(*token, fake::Allocation{pointer, bytes});
    return {};
}
Result pool_release(uint64_t token) noexcept {
    if (fake::fail_release) { fake::fail_release = false; return {Stage::unmap, -1}; }
    const auto found = fake::live.find(token);
    if (found == fake::live.end()) return {Stage::pool_not_owned, -1};
    free(found->second.pointer); fake::live.erase(found); return {};
}
}
static NeoSwapCPUBufferStats cpu() {
    NeoSwapCPUBufferStats s{}; assert(NeoSwap_CPUBufferSnapshot(&s) == NEOSWAP_OK); return s;
}
static NeoSwapStats totals() {
    NeoSwapStats s{}; s.struct_size = sizeof(s); assert(NeoSwap_Snapshot(&s) == NEOSWAP_OK); return s;
}
static void* allocate(uint64_t bytes, uint32_t kind = NEOSWAP_CPU_CACHE) {
    void* pointer = nullptr;
    const auto* api = NeoSwap_GetAPI(1);
    const int result = api->allocate(NEOSWAP_RPCS3, kind, bytes, 65536, &pointer);
    assert(result == NEOSWAP_OK || !pointer);
    return pointer;
}
int main() {
    constexpr uint64_t KiB = 1024, MiB = 1024 * KiB;
    char directory[] = "/tmp/neoswap-cpu-buffer-test-XXXXXX"; assert(mkdtemp(directory));
    NeoSwapConfig config{sizeof(config), NEOSWAP_ABI, 5ULL << 30, 0, MiB, 1, 0};
    assert(NeoSwap_Configure(directory, &config) == NEOSWAP_OK);
    const auto* api = NeoSwap_GetAPI(1);
    fake::ready = true;
    // Opt-in and pressure are separate. A large target is never an allocation.
    assert(!cpu().enabled && cpu().pressure_raised && !totals().live_bytes);
    assert(!allocate(64 * KiB));
    NeoSwap_SetCPUBufferExperiment(1);
    assert(!allocate(64 * KiB));
    NeoSwap_SetCPUBufferPressure(0);
    void* invalid = nullptr;
    assert(api->allocate(0, NEOSWAP_CPU_CACHE, 65536, 3, &invalid) == NEOSWAP_INVALID && !invalid);
    assert(!allocate(64 * KiB - 1));
    assert(!allocate(64 * KiB, NEOSWAP_CPU_DATA)); // Vulkan/generic threshold unchanged.
    const long page = sysconf(_SC_PAGESIZE); assert(page > 0);
    void* p = allocate(64 * KiB + 1); assert(p && reinterpret_cast<uintptr_t>(p) % 65536 == 0);
    const uint64_t rounded = (64 * KiB + page) & ~(static_cast<uint64_t>(page) - 1);
    assert(cpu().live_bytes == rounded && cpu().live_blocks == 1);
    memset(p, 0xA7, 64 * KiB + 1);
    assert(!totals().allocated_disk_bytes);
    NeoSwap_SetCPUBufferPressure(1);
    assert(!allocate(256 * KiB));
    assert(static_cast<unsigned char*>(p)[65536] == 0xA7); // Existing data still valid under pressure.
    fake::fail_release = true;
    assert(api->release(p) == NEOSWAP_MAPPING);
    assert(cpu().live_bytes == rounded && cpu().live_blocks == 1);
    assert(api->release(p) == NEOSWAP_OK && !cpu().live_bytes);
    assert(api->release(p) == NEOSWAP_NOT_OWNED);
    NeoSwap_SetCPUBufferPressure(0);
    // Small slots are independent from legacy large slots. They cannot make
    // all existing buffers fail or start allocating small files on saturation.
    std::vector<void*> small, large;
    for (unsigned i = 0; i < 768; ++i) { p = allocate(64 * KiB); assert(p); small.push_back(p); }
    assert(!allocate(64 * KiB) && cpu().live_blocks == 768);
    for (unsigned i = 0; i < 256; ++i) { p = allocate(MiB, NEOSWAP_CPU_DATA); assert(p); large.push_back(p); }
    assert(!allocate(MiB, NEOSWAP_CPU_DATA));
    assert(!totals().allocated_disk_bytes && totals().live_blocks == 1024);
    for (auto pointer : large) assert(api->release(pointer) == NEOSWAP_OK);
    for (auto pointer : small) assert(api->release(pointer) == NEOSWAP_OK);
    assert(fake::live.empty() && !cpu().live_bytes && !totals().live_bytes);
    // Byte budget is also bounded independently from the count budget.
    small.clear();
    while ((p = allocate(768 * KiB))) small.push_back(p);
    assert(small.size() == (512 * MiB) / (768 * KiB));
    assert(cpu().live_bytes <= 512 * MiB && !totals().allocated_disk_bytes);
    for (auto pointer : small) assert(api->release(pointer) == NEOSWAP_OK);
    // A pool miss queues a valid >=1 MiB preparation hint, not an invalid 64 KiB chunk.
    fake::ready = false;
    const auto disk_before = totals().allocated_disk_bytes;
    assert(!allocate(64 * KiB));
    NeoSwapDonationDemand demand{}; assert(NeoSwap_ClaimDonationDemand(&demand) == NEOSWAP_OK);
    assert(demand.bytes == MiB && !totals().live_blocks && totals().allocated_disk_bytes == disk_before);
    fake::ready = true;
#ifdef NEOSWAP_CPU_WITH_CORE
    // Execute the actual materialized RSX allocator, including heap fallbacks
    // and realloc copy/ownership. The Core/generic Vulkan ABI remains v1.
    assert(neostation::swap::install(api) == NEOSWAP_OK);
    p = rsx::aligned_allocator::malloc<64>(64 * KiB); assert(p && cpu().live_bytes == 64 * KiB);
    memset(p, 0xC3, 64 * KiB);
    void* grown = rsx::aligned_allocator::realloc<64>(p, 64 * KiB, 256 * KiB); assert(grown);
    for (size_t n = 0; n < 64 * KiB; ++n) assert(static_cast<unsigned char*>(grown)[n] == 0xC3);
    assert(cpu().live_bytes == 256 * KiB);
    NeoSwap_SetCPUBufferPressure(1);
    p = rsx::aligned_allocator::realloc<64>(grown, 256 * KiB, 512 * KiB); assert(p && !cpu().live_bytes);
    for (size_t n = 0; n < 64 * KiB; ++n) assert(static_cast<unsigned char*>(p)[n] == 0xC3);
    rsx::aligned_allocator::free(p);
    NeoSwap_SetCPUBufferPressure(0);
#endif
    assert(NeoSwap_SetOwnerSessionActive(NEOSWAP_RPCS3, 0) == NEOSWAP_OK);
    assert(!cpu().enabled && !allocate(64 * KiB));
    assert(!cpu().live_blocks && !totals().allocated_disk_bytes && fake::live.empty());
    assert(cpu().successful_allocations + cpu().fallback_count == cpu().requests);
    assert(cpu().request_bins[0] && cpu().donated_bins[0] && cpu().request_bins[3] && cpu().donated_bins[3]);
    assert(cpu().pressure_refusals && cpu().policy_refusals);
    assert(NeoSwap_CPUBufferSnapshot(nullptr) == NEOSWAP_INVALID);
    config.capacity_bytes = 0; assert(NeoSwap_Configure(nullptr, &config) == NEOSWAP_OK);
    assert(rmdir(directory) == 0);
    puts("PASS: production CPU broker: opt-in, pressure, alignment, zero small files, 768/256 slot isolation, 512MiB budget, release failure ownership, demand and lifecycle. Donor operations are injected; no physical RAM claim.");
}
