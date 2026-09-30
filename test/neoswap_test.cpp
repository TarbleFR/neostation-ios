#include "NeoSwap.h"
#include "NeoSwapHost.h"
#include <array>
#include <atomic>
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
    assert(!NeoSwap_HostSnapshot(&host) && host.reserved_virtual_bytes == 8*MiB);
    assert(!snapshot().live_bytes && !snapshot().allocated_disk_bytes);
    // Virtual space is reserved persistently without fake owner allocations.
    // A failed replacement must retain the working arena and owner policy.
    NeoSwap_TestFailNext(6);
    assert(NeoSwap_Configure(dir, &config) == NEOSWAP_MAPPING);
    assert(!NeoSwap_HostSnapshot(&host) && host.reserved_virtual_bytes == 8*MiB);
    assert(host.reservation_result == NEOSWAP_MAPPING && host.reservation_errno);
    assert(api->enabled(0));
    void* previous = nullptr;
    for (auto alignment : {1u, 16u, 4096u, 16384u, 65536u}) {
        assert(api->allocate(0, NEOSWAP_CPU_DATA, MiB+31, alignment, &p) == 0);
        assert(reinterpret_cast<uintptr_t>(p) % alignment == 0);
        if (previous) assert(p == previous); // released PROT_NONE space is reusable
        previous = p;
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
        assert(!NeoSwap_HostSnapshot(&host) && host.reserved_virtual_bytes == 8*MiB);
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
    for (int stage=1; stage<=3; ++stage) {
        NeoSwap_TestFailNext(stage);
        assert(api->allocate(0, 1, MiB, 16, &p) < 0 && !p);
        assert(snapshot().live_blocks == 0 && snapshot().live_bytes == 0);
    }
    assert(api->allocate(0, 1, MiB, 16, &p) == 0);
    std::memset(p, 0x73, MiB);
    NeoSwap_TestFailNext(5);
    assert(api->sync(p) == NEOSWAP_IO && static_cast<unsigned char*>(p)[0] == 0x73);
    NeoSwap_TestFailNext(4);
    assert(api->release(p) == NEOSWAP_MAPPING); // ownership survives failure
    assert(snapshot().live_blocks == 1 && static_cast<unsigned char*>(p)[0] == 0x73);
    assert(api->release(p) == 0 && !snapshot().live_blocks);
    std::atomic<int> failures{0};
    std::vector<std::thread> workers;
    for (uint32_t owner=0; owner<NEOSWAP_OWNER_COUNT; ++owner) {
        NeoSwap_RegisterClient(owner);
        workers.emplace_back([&, owner] {
            for (int i=0; i<60; ++i) {
                void* ptr = nullptr;
                if (api->allocate(owner, NEOSWAP_CPU_DATA, 65536, 65536, &ptr)) { ++failures; continue; }
                std::memset(ptr, static_cast<int>(owner+1), 65536);
                NeoSwapHostStats display{};
                if (NeoSwap_HostSnapshot(&display) || display.reserved_virtual_bytes != 8*MiB) ++failures;
                for (size_t n=0; n<65536; ++n) if (static_cast<unsigned char*>(ptr)[n] != owner+1) ++failures;
                if (api->release(ptr)) ++failures;
            }
        });
    }
    for (auto& worker : workers) worker.join();
    assert(!failures && !snapshot().live_bytes && snapshot().registered_owner_mask == 0x3f);
    // Exhaust all descriptor slots and prove quota rolls back exactly.
    std::array<void*, 256> pointers{};
    for (auto& ptr : pointers) assert(api->allocate(0, 1, 4096, 16, &ptr) == 0);
    assert(api->allocate(0, 1, 4096, 16, &p) == NEOSWAP_LIMIT && !p);
    for (auto ptr : pointers) assert(api->release(ptr) == 0);
    config.capacity_bytes = 0;
    assert(NeoSwap_Configure(nullptr, &config) == 0 && !api->enabled(0));
    assert(!NeoSwap_HostSnapshot(&host) && !host.reserved_virtual_bytes);
    assert(api->allocate(0, 1, MiB, 16, &p) == NEOSWAP_DISABLED);
    assert(::rmdir(dir) == 0); // no backing names survive any success/error path
    auto result = snapshot();
    std::printf("NeoSwap PASS: %llu allocations, %llu rejections, all owners, 5 fault stages, zero live blocks\n",
        static_cast<unsigned long long>(result.allocation_count), static_cast<unsigned long long>(result.rejection_count));
}
