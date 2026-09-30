#include "NeoSwap.h"
#include "NeoSwapHost.h"
#include <array>
#include <atomic>
#include <barrier>
#include <cerrno>
#include <cassert>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <thread>
#include <vector>
#include <sys/mman.h>
#include <unistd.h>

constexpr size_t MiB = 1024 * 1024;
static NeoSwapStats snapshot() {
    NeoSwapStats s{}; s.struct_size = sizeof(s); assert(NeoSwap_Snapshot(&s) == 0); return s;
}
static unsigned char byte_at(size_t n) { return static_cast<unsigned char>((n * 131 + (n >> 12) * 17) ^ 0x9d); }
int main() {
    char dir[] = "/tmp/neoswap-test-XXXXXX";
    assert(::mkdtemp(dir));
    const auto* api = NeoSwap_GetAPI(NEOSWAP_ABI);
    assert(api && !NeoSwap_GetAPI(123));
    NeoSwapConfig config{sizeof(config), NEOSWAP_ABI, 8*MiB, 0, 4096, 0x3f, 0};
    void* p = reinterpret_cast<void*>(1);
    assert(api->allocate(0, NEOSWAP_CPU_DATA, MiB, 16, &p) == NEOSWAP_DISABLED && !p);
    NeoSwapHostStats host{};
    assert(!NeoSwap_HostSnapshot(&host) && !host.reserved_virtual_bytes);
    assert(host.owner_last_result[0] == NEOSWAP_DISABLED);
    assert(NeoSwap_Configure(dir, &config) == 0);
    assert(!NeoSwap_HostSnapshot(&host) && !host.reserved_virtual_bytes);
    assert(!snapshot().live_bytes && !snapshot().allocated_disk_bytes);
    // An 8GiB budget is policy, with no capacity-sized virtual reservation.
    auto budget = config;
    budget.capacity_bytes = 8192*MiB;
    assert(NeoSwap_Configure(dir, &budget) == 0);
    assert(!NeoSwap_HostSnapshot(&host) && !host.reserved_virtual_bytes);
    assert(snapshot().capacity_bytes == 8192*MiB && !snapshot().allocated_disk_bytes);
    assert(NeoSwap_Configure(dir, &config) == 0);
    // A failed directory replacement preserves the working quota/owner policy.
    auto rejected_config = config;
    rejected_config.capacity_bytes = 4*MiB;
    rejected_config.enabled_owner_mask = 1u << NEOSWAP_DOLPHIN;
    assert(NeoSwap_Configure("/dev/null", &rejected_config) == NEOSWAP_STORAGE);
    assert(snapshot().capacity_bytes == config.capacity_bytes);
    assert(api->enabled(0) && api->enabled(NEOSWAP_PROBE));
    assert(NeoSwap_Configure("relative", &rejected_config) == NEOSWAP_INVALID);
    const size_t page = static_cast<size_t>(::sysconf(_SC_PAGESIZE));
    const auto rounded = [page](size_t bytes) { return (bytes+page-1)&~(page-1); };
    // A foreign mapping is never a candidate for MAP_FIXED or cleanup.
    void* foreign = ::mmap(nullptr, 65536, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    assert(foreign != MAP_FAILED);
    std::memset(foreign, 0x5b, 65536);
    for (auto alignment : {1u, 16u, 4096u, 16384u, 65536u}) {
        assert(api->allocate(0, NEOSWAP_CPU_DATA, MiB+31, alignment, &p) == 0);
        assert(reinterpret_cast<uintptr_t>(p) % alignment == 0);
        assert(!NeoSwap_HostSnapshot(&host) && host.reserved_virtual_bytes == rounded(MiB+31));
        auto* data = static_cast<unsigned char*>(p);
        for (size_t n=0; n<MiB+31; ++n) assert(!data[n]);
        for (size_t n=0; n<MiB+31; ++n) data[n] = byte_at(n);
        assert(api->sync(p) == 0);
        assert(NeoSwap_TestVerifyFile(p, p, MiB+31));
        // The production MAP_SHARED backing must survive a reclaim hint.
        assert(::madvise(p, snapshot().live_bytes, MADV_DONTNEED) == 0);
        for (size_t n=0; n<MiB+31; ++n) assert(data[n] == byte_at(n));
        auto s = snapshot();
        assert(s.live_blocks == 1 && s.live_bytes >= MiB+31 && s.allocated_disk_bytes >= MiB);
        assert(NeoSwap_Configure(dir, &config) == NEOSWAP_BUSY);
        assert(api->release(p) == 0);
        assert(!NeoSwap_HostSnapshot(&host) && !host.reserved_virtual_bytes);
        assert(api->release(p) == NEOSWAP_NOT_OWNED);
    }
    int local = 0;
    assert(api->release(&local) == NEOSWAP_NOT_OWNED);
    assert(api->allocate(999, 1, MiB, 16, &p) == NEOSWAP_INVALID);
    assert(api->allocate(0, 999, MiB, 16, &p) == NEOSWAP_INVALID); // JIT/GPU not admissible
    assert(api->allocate(0, 1, 0, 16, &p) == NEOSWAP_INVALID);
    assert(api->allocate(0, 1, MiB, 3, &p) == NEOSWAP_INVALID);
    assert(api->allocate(0, 1, UINT64_MAX, 16, &p) == NEOSWAP_INVALID);
    assert(api->allocate(0, 1, 32, 16, &p) == NEOSWAP_TOO_SMALL);
    assert(api->allocate(0, 1, 9*MiB, 16, &p) == NEOSWAP_QUOTA);
    config.minimum_free_bytes = UINT64_MAX;
    assert(NeoSwap_Configure(dir, &config) == 0);
    assert(api->allocate(0, 1, MiB, 16, &p) == NEOSWAP_STORAGE && !p);
    assert(!NeoSwap_HostSnapshot(&host) && host.owner_last_result[0] == NEOSWAP_STORAGE);
    assert(host.owner_last_errno[0] == ENOSPC && !host.remaining_storage_bytes);
    config.minimum_free_bytes = 0;
    assert(NeoSwap_Configure(dir, &config) == 0);
    for (int stage : {1, 2, 3, 6}) {
        NeoSwap_TestFailNext(stage);
        assert(api->allocate(0, 1, MiB, 16, &p) < 0 && !p);
        assert(snapshot().live_blocks == 0 && snapshot().live_bytes == 0);
        assert(!NeoSwap_HostSnapshot(&host) && !host.reserved_virtual_bytes);
        for (size_t n=0; n<65536; ++n) assert(static_cast<unsigned char*>(foreign)[n] == 0x5b);
    }
    // A rejected map whose unmap fails remains a bounded, owned quarantine.
    // It is not reported as a live client buffer or as allocated file storage.
    NeoSwap_TestFailNext(7);
    assert(api->allocate(0, 1, MiB, 65536, &p) == NEOSWAP_MAPPING && !p);
    assert(!NeoSwap_HostSnapshot(&host) && host.reserved_virtual_bytes == MiB);
    assert(host.reservation_result == NEOSWAP_MAPPING && host.reservation_errno == EIO);
    assert(!snapshot().live_blocks && !snapshot().live_bytes && !snapshot().allocated_disk_bytes);
    NeoSwap_TestFailNext(8);
    assert(NeoSwap_Configure(dir, &rejected_config) == NEOSWAP_MAPPING);
    assert(snapshot().capacity_bytes == config.capacity_bytes && api->enabled(NEOSWAP_PROBE));
    assert(!NeoSwap_HostSnapshot(&host) && host.reserved_virtual_bytes == MiB);
    assert(NeoSwap_Configure(dir, &config) == 0);
    assert(!NeoSwap_HostSnapshot(&host) && !host.reserved_virtual_bytes);
    assert(api->release(foreign) == NEOSWAP_NOT_OWNED);
    for (size_t n=0; n<65536; ++n) assert(static_cast<unsigned char*>(foreign)[n] == 0x5b);
    assert(api->allocate(0, 1, MiB, 16, &p) == 0);
    std::memset(p, 0x73, MiB);
    NeoSwap_TestFailNext(5);
    assert(api->sync(p) == NEOSWAP_IO && static_cast<unsigned char*>(p)[0] == 0x73);
    NeoSwap_TestFailNext(4);
    assert(api->release(p) == NEOSWAP_MAPPING); // ownership survives failure
    assert(snapshot().live_blocks == 1 && static_cast<unsigned char*>(p)[0] == 0x73);
    assert(!NeoSwap_HostSnapshot(&host) && host.reserved_virtual_bytes == MiB);
    assert(api->release(p) == 0 && !snapshot().live_blocks);
    assert(!NeoSwap_HostSnapshot(&host) && !host.reserved_virtual_bytes);
    // Independent regions keep all other pointers/data stable on release and
    // failure. Rounded reservation accounting has no persistent align padding.
    std::array<void*, 3> independent{};
    const std::array<size_t, 3> sizes{4096, 4097, 65537};
    uint64_t reserved_bytes = 0;
    for (size_t i=0; i<independent.size(); ++i) {
        assert(api->allocate(0, 1, sizes[i], 65536, &independent[i]) == 0);
        std::memset(independent[i], static_cast<int>(0x31+i), sizes[i]);
        reserved_bytes += rounded(sizes[i]);
        assert(!NeoSwap_HostSnapshot(&host) && host.reserved_virtual_bytes == reserved_bytes);
    }
    assert(api->release(independent[1]) == 0);
    reserved_bytes -= rounded(sizes[1]);
    assert(!NeoSwap_HostSnapshot(&host) && host.reserved_virtual_bytes == reserved_bytes);
    // Asking the OS for the released address never uses MAP_FIXED in the test.
    // If it reuses that address, stale release still cannot remove the mapping.
    void* reused = ::mmap(independent[1], rounded(sizes[1]), PROT_READ | PROT_WRITE,
                         MAP_PRIVATE | MAP_ANON, -1, 0);
    assert(reused != MAP_FAILED);
    std::memset(reused, 0xa7, rounded(sizes[1]));
    assert(api->release(reused) == NEOSWAP_NOT_OWNED);
    NeoSwap_TestFailNext(3);
    assert(api->allocate(0, 1, MiB, 65536, &p) == NEOSWAP_MAPPING && !p);
    assert(!NeoSwap_HostSnapshot(&host) && host.reserved_virtual_bytes == reserved_bytes);
    for (size_t i : {0u, 2u}) {
        for (size_t n=0; n<sizes[i]; ++n)
            assert(static_cast<unsigned char*>(independent[i])[n] == 0x31+i);
        assert(api->release(independent[i]) == 0);
    }
    for (size_t n=0; n<rounded(sizes[1]); ++n) assert(static_cast<unsigned char*>(reused)[n] == 0xa7);
    assert(::munmap(reused, rounded(sizes[1])) == 0);
    assert(::munmap(foreign, 65536) == 0);
    std::atomic<int> failures{0};
    std::barrier first_allocations(NEOSWAP_OWNER_COUNT+1);
    std::vector<std::thread> workers;
    for (uint32_t owner=0; owner<NEOSWAP_OWNER_COUNT; ++owner) {
        NeoSwap_RegisterClient(owner);
        workers.emplace_back([&, owner] {
            for (int i=0; i<60; ++i) {
                void* ptr = nullptr;
                const bool allocated = api->allocate(owner, NEOSWAP_CPU_DATA, 65536, 65536, &ptr) == 0;
                if (!allocated) ++failures;
                else std::memset(ptr, static_cast<int>(owner+1), 65536);
                if (!i) {
                    first_allocations.arrive_and_wait();
                    first_allocations.arrive_and_wait();
                }
                if (!allocated) continue;
                NeoSwapHostStats display{};
                if (NeoSwap_HostSnapshot(&display) || display.reserved_virtual_bytes < 65536 ||
                    display.reserved_virtual_bytes >= config.capacity_bytes) ++failures;
                for (size_t n=0; n<65536; ++n) if (static_cast<unsigned char*>(ptr)[n] != owner+1) ++failures;
                if (api->release(ptr)) ++failures;
            }
        });
    }
    first_allocations.arrive_and_wait();
    assert(!failures);
    assert(!NeoSwap_HostSnapshot(&host) && host.reserved_virtual_bytes == NEOSWAP_OWNER_COUNT*65536);
    assert(snapshot().live_blocks == NEOSWAP_OWNER_COUNT);
    first_allocations.arrive_and_wait();
    for (auto& worker : workers) worker.join();
    assert(!failures && !snapshot().live_bytes && snapshot().registered_owner_mask == 0x3f);
    assert(!NeoSwap_HostSnapshot(&host) && !host.reserved_virtual_bytes);
    // Exhaust all descriptor slots and prove quota rolls back exactly.
    std::array<void*, 256> pointers{};
    for (auto& ptr : pointers) assert(api->allocate(0, 1, 4096, 16, &ptr) == 0);
    assert(!NeoSwap_HostSnapshot(&host) && host.reserved_virtual_bytes == pointers.size()*rounded(4096));
    assert(api->allocate(0, 1, 4096, 16, &p) == NEOSWAP_LIMIT && !p);
    for (auto ptr : pointers) assert(api->release(ptr) == 0);
    config.capacity_bytes = 0;
    assert(NeoSwap_Configure(nullptr, &config) == 0 && !api->enabled(0));
    assert(!NeoSwap_HostSnapshot(&host) && !host.reserved_virtual_bytes);
    assert(api->allocate(0, 1, MiB, 16, &p) == NEOSWAP_DISABLED);
    assert(::rmdir(dir) == 0); // no backing names survive any success/error path
    auto result = snapshot();
    std::printf("NeoSwap PASS: %llu allocations, %llu rejections, all owners, 8 fault stages, exact regions, zero live blocks\n",
        static_cast<unsigned long long>(result.allocation_count), static_cast<unsigned long long>(result.rejection_count));
}
