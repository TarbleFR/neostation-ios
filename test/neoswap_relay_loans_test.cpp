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
                "small CPU gate, %llu relay and %llu file churn allocations, address index, session end\n",
                static_cast<unsigned long long>(relay_count), static_cast<unsigned long long>(file_count));
}
