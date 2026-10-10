// Executes the production host broker (NeoSwap.cpp) together with the
// production relay backend (Backend.cpp) over a real shared-file OS fixture.
// It proves routing, quotas, reuse, kinds, release ownership and the address
// index. It is NOT Darwin named-entry, footprint or iPhone residency evidence.
#include "NeoSwap.h"
#include "NeoSwapHost.h"
#include "NeoSwapRelay.h"
#include "Relay/Backend.h"
#include "NeoSwapClient.h"
#include <algorithm>
#include <cassert>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <chrono>
#include <thread>
#include <map>
#include <random>
#include <vector>
#include <fcntl.h>
#include <sys/mman.h>
#include <unistd.h>

static_assert(static_cast<int>(NEOSWAP_GPU_HOST_VISIBLE) == static_cast<int>(NEOSWAP_HOST_KIND_GPU_HOST_VISIBLE));
static_assert(static_cast<int>(NEOSWAP_VIDEO_FRAME) == static_cast<int>(NEOSWAP_HOST_KIND_VIDEO_FRAME));
static_assert(static_cast<int>(NEOSWAP_CPU_DATA) == static_cast<int>(NEOSWAP_HOST_KIND_CPU_DATA) &&
              static_cast<int>(NEOSWAP_CPU_CACHE) == static_cast<int>(NEOSWAP_HOST_KIND_CPU_CACHE));

namespace {
constexpr uint64_t KiB = 1024, MiB = 1024 * KiB;
constexpr uint64_t page = NEOSWAP_RELAY_ALIGNMENT;
// A real shared-file "named object" fixture: every map is a MAP_SHARED view of
// the same descriptor so aliases, windows and scrubbing use actual memory.
struct RealOS {
    std::map<std::uint32_t, int> files;
    std::map<std::uintptr_t, std::uint64_t> mappings;
    std::uint64_t budget = neostation::relay::maximum_capacity;
    int fail_map = 0, fail_unmap = 0, fail_zero = 0;
    int maps = 0, unmaps = 0, zeros = 0;
    bool test_address_reuse = false;
    static bool take(int& remaining) { if (!remaining) return false; --remaining; return true; }
    void add(std::uint32_t port, std::uint64_t bytes) {
        char name[] = "/tmp/neoswap-relay-loans-XXXXXX";
        const int fd = ::mkstemp(name);
        assert(fd >= 0 && ::unlink(name) == 0 && ::ftruncate(fd, static_cast<off_t>(bytes)) == 0);
        files[port] = fd;
    }
    static int retain(void*, std::uint32_t) { return 0; }
    static int drop(void*, std::uint32_t) { return 0; }
    static int map(void* context, std::uint32_t port, std::uint64_t offset, std::uint64_t bytes,
                   std::uintptr_t target, std::uint32_t protection, std::uintptr_t* mapped) {
        auto& self = *static_cast<RealOS*>(context);
        ++self.maps;
        if (take(self.fail_map)) return 104;
        int prot = protection == NEOSWAP_RELAY_NONE ? PROT_NONE : PROT_READ;
        if (protection == NEOSWAP_RELAY_READ_WRITE) prot |= PROT_WRITE;
        if (!target) {
            // Darwin's vm_map honors the 64 KiB alignment mask for ANYWHERE
            // mappings; emulate it by trimming an over-reserved anonymous range.
            void* raw = ::mmap(nullptr, static_cast<size_t>(bytes + page), PROT_NONE, MAP_ANON | MAP_PRIVATE, -1, 0);
            if (raw == MAP_FAILED) return errno;
            const auto start = reinterpret_cast<std::uintptr_t>(raw);
            const auto aligned = (start + page - 1) & ~(page - 1);
            if (aligned > start) assert(::munmap(raw, aligned - start) == 0);
            if (aligned + bytes < start + bytes + page)
                assert(::munmap(reinterpret_cast<void*>(aligned + bytes), start + bytes + page - aligned - bytes) == 0);
            target = aligned;
        }
        void* address = ::mmap(reinterpret_cast<void*>(target), static_cast<size_t>(bytes), prot,
                               MAP_SHARED | MAP_FIXED, self.files.at(port), static_cast<off_t>(offset));
        if (address == MAP_FAILED) return errno;
        assert(reinterpret_cast<std::uintptr_t>(address) == target);
        self.mappings[reinterpret_cast<std::uintptr_t>(address)] = bytes;
        *mapped = reinterpret_cast<std::uintptr_t>(address);
        return 0;
    }
    static int unmap(void* context, std::uintptr_t address, std::uint64_t bytes, bool fixed) {
        auto& self = *static_cast<RealOS*>(context);
        ++self.unmaps;
        if (take(self.fail_unmap)) return 107;
        assert(self.mappings.count(address) && self.mappings.at(address) == bytes);
        if (fixed) {
            assert(::mmap(reinterpret_cast<void*>(address), static_cast<size_t>(bytes), PROT_NONE,
                          MAP_FIXED | MAP_ANON | MAP_PRIVATE, -1, 0) == reinterpret_cast<void*>(address));
        } else {
            assert(::munmap(reinterpret_cast<void*>(address), static_cast<size_t>(bytes)) == 0);
            if (self.test_address_reuse) {
                self.test_address_reuse = false;
                // The OS may reissue this VA before the backend returns.
                void* ordinary = ::mmap(reinterpret_cast<void*>(address), bytes, PROT_READ | PROT_WRITE,
                    MAP_ANON | MAP_PRIVATE | MAP_FIXED, -1, 0);
                assert(ordinary == reinterpret_cast<void*>(address));
                assert(NeoSwap_GetAPI(NEOSWAP_ABI)->release(ordinary) == NEOSWAP_NOT_OWNED);
                assert(::munmap(ordinary, bytes) == 0);
            }
        }
        self.mappings.erase(address);
        return 0;
    }
    static int zero(void* context, std::uintptr_t address, std::uint64_t bytes) {
        auto& self = *static_cast<RealOS*>(context);
        ++self.zeros;
        if (take(self.fail_zero)) return 109;
        std::memset(reinterpret_cast<void*>(address), 0, static_cast<size_t>(bytes));
        return 0;
    }
    static std::uint64_t headroom(void* context) { return static_cast<RealOS*>(context)->budget; }
    static neostation::relay::Operations operations() { return {retain, drop, map, unmap, zero, headroom}; }
};
RealOS os;
NeoSwapRelayLoanStats loans() {
    NeoSwapRelayLoanStats s{}; assert(NeoSwap_RelayLoanSnapshot(&s) == NEOSWAP_OK); return s;
}
NeoSwapHostStats host() { NeoSwapHostStats s{}; assert(NeoSwap_HostSnapshot(&s) == NEOSWAP_OK); return s; }
NeoSwapStats totals() { NeoSwapStats s{}; s.struct_size = sizeof(s); assert(NeoSwap_Snapshot(&s) == NEOSWAP_OK); return s; }
NeoSwapRelayStats relay() {
    NeoSwapRelayStats s{}; s.struct_size = sizeof(s); s.abi_version = NEOSWAP_RELAY_ABI;
    assert(NeoSwap_GetRelayAPI(NEOSWAP_RELAY_ABI)->snapshot(&s) == NEOSWAP_RELAY_OK); return s;
}
void* allocate(uint32_t kind, uint64_t bytes, uint64_t alignment = 65536) {
    void* p = nullptr;
    const int result = NeoSwap_GetAPI(NEOSWAP_ABI)->allocate(NEOSWAP_RPCS3, kind, bytes, alignment, &p);
    assert(result == NEOSWAP_OK || !p);
    return p;
}
int allocate_result(uint32_t kind, uint64_t bytes) {
    void* p = nullptr;
    return NeoSwap_GetAPI(NEOSWAP_ABI)->allocate(NEOSWAP_RPCS3, kind, bytes, 65536, &p);
}
}

int main() {
    const auto* api = NeoSwap_GetAPI(NEOSWAP_ABI);
    neostation::relay::install_operations_for_test(RealOS::operations(), &os);
    // Two 16 MiB "named objects" retained by the relay backend.
    os.add(1, 16 * MiB); os.add(2, 16 * MiB);
    assert(neostation::relay::configure(neostation::relay::supported_owner_mask, 32 * MiB) == NEOSWAP_RELAY_OK);
    assert(neostation::relay::adopt(1, 16 * MiB, 4321, 1) == NEOSWAP_RELAY_OK);
    assert(neostation::relay::adopt(2, 16 * MiB, 4321, 1) == NEOSWAP_RELAY_OK);
    assert(relay().capacity_bytes == 32 * MiB);
    char directory[] = "/tmp/neoswap-relay-loans-dir-XXXXXX"; assert(::mkdtemp(directory));

    // Without a file policy and without admission the broker is disabled.
    assert(!api->enabled(NEOSWAP_RPCS3) && allocate_result(NEOSWAP_CPU_DATA, MiB) == NEOSWAP_DISABLED);
    assert(loans().available && !loans().admitted && !loans().live_bytes);
    // Admission without a file policy makes the relay the only backing.
    assert(NeoSwap_SetRelayHostLoanPolicy(8 * MiB, 1, 1) == NEOSWAP_OK);
    assert(api->enabled(NEOSWAP_RPCS3));
    assert(allocate_result(NEOSWAP_CPU_DATA, 512 * KiB) == NEOSWAP_TOO_SMALL); // 1 MiB minimum keeps the file contract
    assert(allocate_result(NEOSWAP_CPU_CACHE, 64 * KiB) == NEOSWAP_DISABLED); // small CPU gate closed by default
    assert(allocate_result(999, MiB) == NEOSWAP_INVALID && allocate_result(0, MiB) == NEOSWAP_INVALID);
    void* a = allocate(NEOSWAP_CPU_DATA, MiB + 1);
    if (!a) std::fprintf(stderr, "first relay loan failed: result=%d backend=%d host_last=%d\n",
        allocate_result(NEOSWAP_CPU_DATA, MiB + 1), loans().last_backend_result, host().owner_last_result[0]);
    assert(a && reinterpret_cast<uintptr_t>(a) % 65536 == 0);
    std::memset(a, 0x5A, MiB + 1);
    assert(static_cast<unsigned char*>(a)[MiB] == 0x5A);
    {
        const auto s = loans();
        assert(s.live_bytes == MiB + 64 * KiB && s.live_blocks == 1 && s.allocation_count == 1);
        assert(s.kind_live_bytes[NEOSWAP_HOST_KIND_CPU_DATA] == MiB + 64 * KiB && s.kind_allocation_count[1] == 1);
        assert(s.padding_bytes > 0 && s.padding_bytes < 64 * KiB && !s.reuse_hits && !s.cached_blocks);
        assert(host().relay_loan_live_bytes == s.live_bytes && host().owner_relay_live_bytes[NEOSWAP_RPCS3] == s.live_bytes);
        assert(!host().owner_donated_live_bytes[NEOSWAP_RPCS3] && !totals().allocated_disk_bytes);
        assert(totals().live_bytes == s.live_bytes && totals().live_blocks == 1);
        assert(relay().live_bytes == s.live_bytes && relay().object_count == 1 && relay().alias_count == 1);
        const auto evidence = neostation::relay::backend().pressure_diagnostics();
        assert(evidence.owner_live_bytes[neostation::relay::host_loan_owner] == s.live_bytes && !evidence.owner_live_bytes[0]);
    }
    assert(api->sync(a) == NEOSWAP_OK);
    // Vulkan and video kinds are routed and accounted separately.
    void* gpu = allocate(NEOSWAP_GPU_HOST_VISIBLE, 2 * MiB, 16384);
    assert(gpu && reinterpret_cast<uintptr_t>(gpu) % 16384 == 0);
    void* frame = allocate(NEOSWAP_VIDEO_FRAME, 300 * KiB, 16384);
    assert(frame);
    std::memset(frame, 0x33, 300 * KiB);
    {
        const auto s = loans();
        assert(s.kind_live_blocks[NEOSWAP_HOST_KIND_GPU_HOST_VISIBLE] == 1 && s.kind_live_bytes[3] == 2 * MiB);
        assert(s.kind_live_blocks[NEOSWAP_HOST_KIND_VIDEO_FRAME] == 1 && s.kind_live_bytes[4] == 320 * KiB);
        assert(s.live_blocks == 3 && s.live_bytes == MiB + 64 * KiB + 2 * MiB + 320 * KiB);
    }
    // Video frames below the relay page and tiny requests are refused, never filed.
    assert(allocate_result(NEOSWAP_VIDEO_FRAME, 4 * KiB) == NEOSWAP_TOO_SMALL);
    assert(NeoSwap_SetRelayHostLoanPolicy(8 * MiB, 1, 0) == NEOSWAP_OK);
    assert(allocate_result(NEOSWAP_VIDEO_FRAME, 300 * KiB) == NEOSWAP_DISABLED);
    assert(loans().kind_refusal_count[NEOSWAP_HOST_KIND_VIDEO_FRAME] == 1 && loans().policy_refusals == 1);
    assert(NeoSwap_SetRelayHostLoanPolicy(8 * MiB, 1, 1) == NEOSWAP_OK);
    // Quota: the ceiling bounds live loans; a refusal has no file fallback here.
    assert(allocate_result(NEOSWAP_CPU_DATA, 5 * MiB) == NEOSWAP_DISABLED);
    assert(loans().quota_refusals == 1 && loans().kind_refusal_count[1] == 1);
    // Release caches the interval (still mapped); the next identical request reuses it.
    assert(api->release(gpu) == NEOSWAP_OK);
    {
        const auto s = loans();
        assert(s.live_blocks == 2 && s.cached_blocks == 1 && s.cached_bytes == 2 * MiB && !s.cache_flushes);
        assert(relay().object_count == 3 && os.unmaps == 0); // cached: no kernel unmap yet
    }
    void* again = allocate(NEOSWAP_GPU_HOST_VISIBLE, 2 * MiB, 16384);
    assert(again == gpu && loans().reuse_hits == 1 && !loans().cached_blocks && relay().object_count == 3);
    assert(api->release(again) == NEOSWAP_OK && loans().cached_blocks == 1);
    // Maintenance keeps young entries, flushes old ones, and flush_all drains.
    assert(NeoSwap_RelayLoanMaintain(0, 0) == NEOSWAP_OK && loans().cached_blocks == 1);
    assert(NeoSwap_RelayLoanMaintain(UINT64_MAX / 2, 0) == NEOSWAP_OK && !loans().cached_blocks);
    assert(loans().cache_flushes == 1 && relay().object_count == 2 && os.unmaps == 1 && os.zeros == 1);
    // now_ms = 0 selects the broker's own monotonic clock, the one that stamps
    // releases: a parked interval survives an immediate pass and is retired
    // once the bounded window has really elapsed on that clock.
    void* parked = allocate(NEOSWAP_GPU_HOST_VISIBLE, 2 * MiB, 16384);
    assert(parked && api->release(parked) == NEOSWAP_OK && loans().cached_blocks == 1);
    assert(NeoSwap_RelayLoanMaintain(0, 0) == NEOSWAP_OK && loans().cached_blocks == 1);
    std::this_thread::sleep_for(std::chrono::milliseconds(2100));
    assert(NeoSwap_RelayLoanMaintain(0, 0) == NEOSWAP_OK && !loans().cached_blocks);
    assert(loans().cache_flushes == 2 && relay().object_count == 2 && os.unmaps == 2);
    // Parked intervals count against the quota like live ones, as the backend
    // charges owner 1 for both; only an identical reuse is exempt.
    {
        const auto before = loans();
        void* park = allocate(NEOSWAP_GPU_HOST_VISIBLE, 2 * MiB, 16384);
        assert(park && api->release(park) == NEOSWAP_OK && loans().cached_blocks == 1);
        const uint64_t charged = loans().live_bytes + loans().cached_bytes;
        assert(NeoSwap_SetRelayHostLoanPolicy(charged + MiB, 1, 1) == NEOSWAP_OK);
        assert(allocate_result(NEOSWAP_GPU_HOST_VISIBLE, 3 * MiB) == NEOSWAP_DISABLED);
        assert(loans().quota_refusals == before.quota_refusals + 1 && loans().backend_refusals == before.backend_refusals);
        void* same = allocate(NEOSWAP_GPU_HOST_VISIBLE, 2 * MiB, 16384);
        assert(same == park && loans().reuse_hits == before.reuse_hits + 1 && !loans().cached_blocks);
        assert(api->release(same) == NEOSWAP_OK && NeoSwap_SetRelayHostLoanPolicy(8 * MiB, 1, 1) == NEOSWAP_OK);
        assert(NeoSwap_RelayLoanMaintain(UINT64_MAX / 2, 0) == NEOSWAP_OK && !loans().cached_blocks && relay().object_count == 2);
    }
    // Lowering the quota below live refuses new loans but revokes nothing.
    assert(NeoSwap_SetRelayHostLoanPolicy(MiB, 1, 1) == NEOSWAP_OK);
    assert(allocate_result(NEOSWAP_CPU_DATA, MiB) == NEOSWAP_DISABLED);
    assert(static_cast<unsigned char*>(a)[MiB] == 0x5A && static_cast<unsigned char*>(frame)[0] == 0x33);
    assert(NeoSwap_SetRelayHostLoanPolicy(8 * MiB, 1, 1) == NEOSWAP_OK);
    // Backend map failure falls through to the configured file fallback, and a
    // failed unmap retains ownership of the live relay mapping.
    NeoSwapConfig config{sizeof(config), NEOSWAP_ABI, 64 * MiB, 0, MiB, 1u << NEOSWAP_RPCS3, 0};
    assert(NeoSwap_Configure(directory, &config) == NEOSWAP_BUSY); // live blocks refuse reconfiguration
    assert(api->release(a) == NEOSWAP_OK && api->release(frame) == NEOSWAP_OK);
    assert(NeoSwap_RelayLoanMaintain(0, 1) == NEOSWAP_OK && !loans().live_blocks && !loans().cached_blocks);
    assert(!totals().live_blocks && relay().object_count == 0);
    assert(NeoSwap_Configure(directory, &config) == NEOSWAP_OK);
    os.fail_map = 1;
    void* filed = allocate(NEOSWAP_CPU_DATA, MiB);
    assert(filed && loans().backend_refusals == 1 && loans().last_backend_result == NEOSWAP_RELAY_MAPPING);
    assert(!loans().live_blocks && totals().allocated_disk_bytes >= MiB && totals().live_blocks == 1);
    assert(api->sync(filed) == NEOSWAP_OK && api->release(filed) == NEOSWAP_OK);
    void* sticky = allocate(NEOSWAP_CPU_DATA, MiB);
    assert(sticky && loans().live_blocks == 1);
    assert(NeoSwap_RelayLoanMaintain(0, 1) == NEOSWAP_OK);
    assert(NeoSwap_SetRelayHostLoanPolicy(8 * MiB, 0, 1) == NEOSWAP_OK); // not admitted: releases bypass the cache
    os.fail_unmap = 1;
    assert(api->release(sticky) == NEOSWAP_MAPPING && loans().release_failures == 1 && loans().live_blocks == 1);
    std::memset(sticky, 0x77, MiB); // still a valid, owned mapping
    assert(api->release(sticky) == NEOSWAP_OK && !loans().live_blocks && relay().object_count == 0);
    assert(api->release(sticky) == NEOSWAP_NOT_OWNED);
    assert(api->enabled(NEOSWAP_RPCS3)); // file policy keeps the client enabled
    assert(NeoSwap_SetRelayHostLoanPolicy(16 * MiB, 1, 1) == NEOSWAP_OK);
    // Small CPU buffers borrow relay pages once the host opens the gate.
    NeoSwap_SetCPUBufferExperiment(1);
    NeoSwap_SetCPUBufferPressure(0);
    void* small = allocate(NEOSWAP_CPU_CACHE, 70 * KiB, 64);
    assert(small && loans().kind_live_blocks[NEOSWAP_HOST_KIND_CPU_CACHE] == 1 && loans().kind_live_bytes[2] == 128 * KiB);
    NeoSwapCPUBufferStats cpu{}; assert(NeoSwap_CPUBufferSnapshot(&cpu) == NEOSWAP_OK);
    assert(cpu.successful_allocations == 1 && cpu.live_blocks == 1 && cpu.live_bytes == 128 * KiB);
    assert(cpu.fallback_count == 1 && cpu.requests == 2); // the earlier gated 64 KiB request counted as a fallback
    assert(api->release(small) == NEOSWAP_OK);
    assert(NeoSwap_CPUBufferSnapshot(&cpu) == NEOSWAP_OK && !cpu.live_blocks && !cpu.live_bytes);
    // Address index: mixed relay/file blocks, random release order, foreign pointers.
    std::vector<void*> live;
    std::mt19937 rng(12345);
    const uint64_t relay_before = loans().allocation_count, total_before = totals().allocation_count;
    for (unsigned i = 0; i < 2000; ++i) {
        const bool release_one = !live.empty() && (rng() % 3 == 0 || live.size() > 40);
        if (release_one) {
            const size_t index = rng() % live.size();
            assert(api->release(live[index]) == NEOSWAP_OK);
            live.erase(live.begin() + static_cast<long>(index));
            continue;
        }
        const uint32_t kind = rng() % 2 ? uint32_t{NEOSWAP_CPU_DATA} : uint32_t{NEOSWAP_GPU_HOST_VISIBLE};
        void* p = allocate(kind, MiB + (rng() % 3) * 64 * KiB, 16384);
        assert(p);
        live.push_back(p);
        int local = 0;
        assert(api->release(&local) == NEOSWAP_NOT_OWNED);
        assert(api->release(static_cast<char*>(p) + 4096) == NEOSWAP_NOT_OWNED);
    }
    const uint64_t relay_count = loans().allocation_count - relay_before;
    const uint64_t file_count = totals().allocation_count - total_before - relay_count;
    assert(relay_count > 0 && file_count > 0 && live.size() <= 41); // 16 MiB quota forces file fallback
    assert(totals().live_blocks == live.size());
    for (void* p : live) assert(api->release(p) == NEOSWAP_OK);
    assert(!totals().live_blocks && !totals().live_bytes);
    assert(NeoSwap_RelayLoanMaintain(0, 1) == NEOSWAP_OK && relay().object_count == 0 && !loans().cached_blocks);
    // Production FAST path: a miss cannot invoke relay map, donor or file IO.
    assert(neostation::swap::install(api) == NEOSWAP_OK);
    assert(NeoSwap_SetRelayHostLoanPolicy(8 * MiB, 1, 1) == NEOSWAP_OK);
    const int maps_before_fast = os.maps;
    const auto allocations_before_fast = totals().allocation_count;
    // An unsatisfiable 16 MiB demand must not starve a later 1 MiB request.
    assert(!neostation::swap::try_allocate(NEOSWAP_RPCS3, 16 * MiB, 65536));
    assert(!neostation::swap::try_allocate(NEOSWAP_RPCS3, MiB, 65536));
    assert(os.maps == maps_before_fast && totals().allocation_count == allocations_before_fast);
    assert(!totals().allocated_disk_bytes && !loans().live_blocks);
    assert(NeoSwap_RelayLoanMaintain(0, 0) == NEOSWAP_OK);
    assert(os.maps == maps_before_fast + 1 && loans().cached_bytes == MiB);
    void* fast = neostation::swap::try_allocate(NEOSWAP_RPCS3, MiB, 65536);
    assert(fast && os.maps == maps_before_fast + 1 && !totals().allocated_disk_bytes);
    std::memset(fast, 0x5C, MiB);
    struct Contended { const NeoSwapAPI* api; void* loan; } contended{api, fast};
    NeoSwap_TestWithBrokerLock([](void* data) {
        auto& context = *static_cast<Contended*>(data);
        void* miss = reinterpret_cast<void*>(1);
        assert(context.api->allocate(0, NEOSWAP_CPU_DATA | NEOSWAP_REQUEST_FAST,
                                     MiB, 65536, &miss) == NEOSWAP_BUSY && !miss);
        int ordinary = 0;
        assert(context.api->release(&ordinary) == NEOSWAP_NOT_OWNED);
        assert(context.api->release(context.loan) == NEOSWAP_OK); // transfers cleanup, never waits
    }, &contended);
    assert(loans().live_blocks == 1 && relay().object_count == 1); // still owned until actual maintenance
    const auto deferred_before = [&] { NeoSwapFastStats f{}; assert(!NeoSwap_FastSnapshot(&f)); return f; }();
    assert(deferred_before.requests == 4 && deferred_before.successes == 1 && deferred_before.broker_busy == 1);
    assert(deferred_before.fallback_count == 3 && deferred_before.prepared_loans == 1);
    assert(deferred_before.retire_requests == 1 && !deferred_before.retired_loans);
    // Revoke admission and inject failed cleanup after the caller relinquished
    // its pointer. The mapping/accounting remain owned and cannot be reissued.
    assert(NeoSwap_SetRelayHostLoanPolicy(8 * MiB, 0, 1) == NEOSWAP_OK);
    os.fail_unmap = 1;
    assert(NeoSwap_RelayLoanMaintain(0, 1) == NEOSWAP_OK);
    assert(loans().live_blocks == 1 && relay().object_count == 1);
    // Reading here is a fixture check of retained backing, not allowed caller use after release.
    assert(static_cast<unsigned char*>(fast)[0] == 0x5C);
    NeoSwapFastStats queued{}; assert(!NeoSwap_FastSnapshot(&queued));
    assert(queued.retire_failures == 1 && !queued.retired_loans);
    os.test_address_reuse = true;
    assert(NeoSwap_RelayLoanMaintain(0, 1) == NEOSWAP_OK);
    assert(!os.test_address_reuse && !loans().live_blocks && !relay().object_count);
    assert(!NeoSwap_FastSnapshot(&queued) && queued.retired_loans == queued.retire_requests);
    // Reusing the same bookkeeping slot must not inherit an old queued release.
    assert(NeoSwap_SetRelayHostLoanPolicy(8 * MiB, 1, 1) == NEOSWAP_OK);
    assert(!neostation::swap::try_allocate(NEOSWAP_RPCS3, MiB, 65536));
    os.fail_map = 1;
    assert(NeoSwap_RelayLoanMaintain(0, 0) == NEOSWAP_OK && !loans().cached_blocks);
    assert(!neostation::swap::try_allocate(NEOSWAP_RPCS3, MiB, 65536));
    assert(NeoSwap_RelayLoanMaintain(0, 0) == NEOSWAP_OK);
    fast = neostation::swap::try_allocate(NEOSWAP_RPCS3, MiB, 65536); assert(fast);
    std::memset(fast, 0x7D, MiB);
    assert(NeoSwap_RelayLoanMaintain(0, 0) == NEOSWAP_OK);
    assert(loans().live_blocks == 1 && static_cast<unsigned char*>(fast)[0] == 0x7D);
    assert(api->release(fast) == NEOSWAP_OK);
    assert(NeoSwap_RelayLoanMaintain(0, 1) == NEOSWAP_OK && !loans().live_blocks);
    assert(!NeoSwap_FastSnapshot(&queued) && queued.prepare_failures == 1);
    assert(NeoSwap_FastSnapshot(nullptr) == NEOSWAP_INVALID);
    // A failed batch must not starve later healthy retirement slots.
    NeoSwap_SetCPUBufferExperiment(1); NeoSwap_SetCPUBufferPressure(0);
    std::vector<void*> pending;
    for (unsigned n = 0; n < 40; ++n) {
        assert(!neostation::swap::try_allocate_cpu(0, 64 * KiB, 65536));
        assert(NeoSwap_RelayLoanMaintain(0, 0) == NEOSWAP_OK);
        void* loan = neostation::swap::try_allocate_cpu(0, 64 * KiB, 65536);
        assert(loan); pending.push_back(loan);
    }
    for (void* loan : pending) assert(api->release(loan) == NEOSWAP_OK);
    assert(NeoSwap_SetRelayHostLoanPolicy(8 * MiB, 0, 1) == NEOSWAP_OK);
    os.fail_unmap = 32;
    assert(NeoSwap_RelayLoanMaintain(0, 1) == NEOSWAP_OK && loans().live_blocks == 40);
    // Simulate persistent failures at the first 32 slots: the next tick must
    // visit later slots first, so no head-of-line retry can pin all 40 loans.
    assert(NeoSwap_RelayLoanMaintain(0, 1) == NEOSWAP_OK && loans().live_blocks == 8);
    assert(NeoSwap_RelayLoanMaintain(0, 1) == NEOSWAP_OK && !loans().live_blocks);
    assert(!NeoSwap_FastSnapshot(&queued) && queued.retire_requests == queued.retired_loans);
    assert(NeoSwap_SetRelayHostLoanPolicy(8 * MiB, 1, 1) == NEOSWAP_OK);
    // Build434 shelves: a FAST miss of a size class is measured, and the next
    // maintenance tick restocks that class by the misses it counted (bounded
    // by the per-tick cap of 8), not one interval per tick for every size.
    {
        auto shelf = loans();
        for (unsigned k = 0; k < NEOSWAP_SHELF_CLASS_COUNT; ++k)
            assert(!shelf.shelf_ready_blocks[k] && !shelf.shelf_target_blocks[k]);
        assert(shelf.shelf_budget_bytes == 256 * MiB);
        const uint64_t misses_before = shelf.shelf_misses[2]; // 256 KiB class
        const uint64_t prepared_before = shelf.shelf_prepared_blocks;
        const int maps_before = os.maps;
        // Five RSX-sized misses in one tick: five 256 KiB intervals follow.
        for (unsigned i = 0; i < 5; ++i) assert(!neostation::swap::try_allocate_cpu(0, 200 * KiB, 65536));
        shelf = loans();
        assert(shelf.shelf_misses[2] == misses_before + 5 && !shelf.shelf_ready_blocks[2]);
        assert(NeoSwap_RelayLoanMaintain(0, 0) == NEOSWAP_OK);
        shelf = loans();
        assert(shelf.shelf_target_blocks[2] == 5 && shelf.shelf_ready_blocks[2] == 5);
        assert(shelf.shelf_prepared_blocks == prepared_before + 5 && os.maps == maps_before + 5);
        assert(shelf.cached_blocks == 5 && shelf.cached_bytes == 5 * 256 * KiB);
        assert(shelf.shelf_last_refill_us <= shelf.shelf_max_refill_us);
        // The stock serves the class without any backend call, padding counted.
        std::vector<void*> rsx;
        const uint64_t padding_before = loans().padding_bytes;
        for (unsigned i = 0; i < 5; ++i) {
            void* loan = neostation::swap::try_allocate_cpu(0, 200 * KiB, 65536);
            assert(loan); rsx.push_back(loan);
        }
        shelf = loans();
        assert(os.maps == maps_before + 5 && shelf.shelf_hits[2] >= 5 && !shelf.shelf_ready_blocks[2]);
        assert(shelf.padding_bytes == padding_before + 5 * (256 * KiB - 200 * KiB) && shelf.live_blocks == 5);
        // A sixth request of the class misses again until the next tick.
        assert(!neostation::swap::try_allocate_cpu(0, 200 * KiB, 65536));
        // Releases re-shelve into the class; the hits keep the stock alive
        // through an aged maintenance pass because the class is still asked for.
        for (void* loan : rsx) assert(api->release(loan) == NEOSWAP_OK);
        assert(NeoSwap_RelayLoanMaintain(0, 0) == NEOSWAP_OK); // retires the 5 FAST loans onto the shelf
        shelf = loans();
        assert(shelf.shelf_ready_blocks[2] >= 5 && !shelf.live_blocks);
        // Target follows the misses of the last tick only (one miss above, which
        // this pass also served by preparing one more interval).
        assert(shelf.shelf_target_blocks[2] == 1);
        // Without new misses the target drops to zero and an aged, idle stock is
        // returned to the relay; a stock under its target would be kept.
        assert(NeoSwap_RelayLoanMaintain(UINT64_MAX / 2, 0) == NEOSWAP_OK);
        shelf = loans();
        assert(!shelf.shelf_ready_blocks[2] && !shelf.shelf_target_blocks[2] && !shelf.cached_blocks);
        // Quota bounds the refill: misses beyond the quota are skipped, counted,
        // and never starve a smaller class planned first.
        assert(NeoSwap_SetRelayHostLoanPolicy(2 * MiB + 128 * KiB, 1, 1) == NEOSWAP_OK);
        assert(!neostation::swap::try_allocate(NEOSWAP_RPCS3, 2 * MiB, 65536));    // class 5: 2 MiB
        assert(!neostation::swap::try_allocate_cpu(0, 64 * KiB, 65536));            // class 0: 64 KiB
        assert(!neostation::swap::try_allocate_cpu(0, 64 * KiB, 65536));
        const uint64_t skips_before = loans().shelf_prepare_skips;
        assert(NeoSwap_RelayLoanMaintain(0, 0) == NEOSWAP_OK);
        shelf = loans();
        assert(shelf.shelf_ready_blocks[0] == 2 && shelf.shelf_ready_blocks[5] == 1); // both fit exactly
        assert(shelf.shelf_prepare_skips == skips_before && shelf.cached_bytes == 2 * MiB + 128 * KiB);
        assert(!neostation::swap::try_allocate(NEOSWAP_RPCS3, 4 * MiB, 65536));    // class 6 cannot fit the quota
        assert(NeoSwap_RelayLoanMaintain(0, 0) == NEOSWAP_OK);
        shelf = loans();
        assert(shelf.shelf_prepare_skips == skips_before + 1 && !shelf.shelf_ready_blocks[6]);
        // A larger class interval serves a FAST request of an odd size.
        const uint64_t hits5_before = loans().shelf_hits[5];
        void* odd = neostation::swap::try_allocate(NEOSWAP_RPCS3, MiB + 64 * KiB, 65536);
        assert(odd && loans().shelf_hits[5] == hits5_before + 1 && !loans().shelf_ready_blocks[5]);
        assert(api->release(odd) == NEOSWAP_OK);
        assert(NeoSwap_RelayLoanMaintain(0, 1) == NEOSWAP_OK);
        shelf = loans();
        assert(!shelf.cached_blocks && !shelf.live_blocks);
        for (unsigned k = 0; k < NEOSWAP_SHELF_CLASS_COUNT; ++k) assert(!shelf.shelf_ready_blocks[k] && !shelf.shelf_target_blocks[k]);
        assert(NeoSwap_SetRelayHostLoanPolicy(8 * MiB, 1, 1) == NEOSWAP_OK);
        // Concurrent FAST requests from several threads never block each other
        // for long and never corrupt the stock: every loan is distinct.
        for (unsigned i = 0; i < 8; ++i) assert(!neostation::swap::try_allocate_cpu(0, 64 * KiB, 65536));
        assert(NeoSwap_RelayLoanMaintain(0, 0) == NEOSWAP_OK && loans().shelf_ready_blocks[0] == 8);
        std::vector<std::thread> workers;
        std::vector<std::vector<void*>> taken(4);
        for (unsigned t = 0; t < 4; ++t) workers.emplace_back([&, t] {
            for (unsigned i = 0; i < 4; ++i) {
                void* loan = neostation::swap::try_allocate_cpu(0, 64 * KiB, 65536);
                if (loan) taken[t].push_back(loan);
            }
        });
        for (auto& worker : workers) worker.join();
        std::vector<void*> all;
        for (const auto& list : taken) all.insert(all.end(), list.begin(), list.end());
        std::sort(all.begin(), all.end());
        assert(all.size() == 8 && std::adjacent_find(all.begin(), all.end()) == all.end());
        assert(!loans().shelf_ready_blocks[0] && loans().live_blocks == 8);
        for (void* loan : all) assert(api->release(loan) == NEOSWAP_OK);
        assert(NeoSwap_RelayLoanMaintain(0, 1) == NEOSWAP_OK && !loans().live_blocks && !loans().cached_blocks);
    }
    // Session end closes admission and drains the cache; existing blocks stay owned.
    void* kept = allocate(NEOSWAP_CPU_DATA, MiB);
    assert(kept && loans().live_blocks == 1);
    assert(NeoSwap_SetOwnerSessionActive(NEOSWAP_RPCS3, 1) == NEOSWAP_OK);
    assert(NeoSwap_SetOwnerSessionActive(NEOSWAP_RPCS3, 0) == NEOSWAP_OK);
    assert(!loans().admitted && loans().live_blocks == 1 && !loans().cached_blocks);
    std::memset(kept, 0x11, MiB);
    assert(api->release(kept) == NEOSWAP_OK && !loans().live_blocks && !loans().cached_blocks);
    assert(relay().object_count == 0 && os.mappings.size() == 2); // only the two adoption windows remain
    assert(NeoSwap_RelayLoanSnapshot(nullptr) == NEOSWAP_INVALID);
    config.capacity_bytes = 0;
    assert(NeoSwap_Configure(nullptr, &config) == NEOSWAP_OK && ::rmdir(directory) == 0);
    assert(neostation::relay::shutdown() == NEOSWAP_RELAY_OK);
    std::printf("PASS relay host loans: production broker + backend, kinds 1-4, quota/admission/video gates, "
                "bounded reuse cache, maintenance, map/unmap failure ownership, file fallback, "
                "FAST miss/lock refusal, off-frame prepare, deferred release/retry, small CPU gate, %llu relay and %llu file churn allocations, address index, "
                "size-class shelves (measured misses, bounded refill, retained stock, quota skips, concurrent takes), session end\n",
                static_cast<unsigned long long>(relay_count), static_cast<unsigned long long>(file_count));
}
