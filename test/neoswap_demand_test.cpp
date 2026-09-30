#include "NeoSwap.h"
#include "NeoSwapHost.h"
#include "Donation/Broker.h"
#include <cassert>
#include <cstdio>
#include <cstdlib>
#include <unistd.h>

constexpr uint64_t MiB = 1024 * 1024;
static NeoSwapDonationDemand claim() {
    NeoSwapDonationDemand demand{};
    assert(NeoSwap_ClaimDonationDemand(&demand) == NEOSWAP_OK);
    return demand;
}
static NeoSwapHostStats host() {
    NeoSwapHostStats stats{};
    assert(NeoSwap_HostSnapshot(&stats) == NEOSWAP_OK);
    return stats;
}
int main() {
    // Regression: the hosted Mac reported 85% kernel headroom while free+
    // purgeable pages were only about 145 MiB. That must allow a bounded real
    // chunk, without counting the kernel estimate as donated resident memory.
    neostation::donation::SystemHeadroom system{};
    system.free_bytes = 8289ULL * 16384;
    system.purgeable_bytes = 821ULL * 16384;
    system.pressure = neostation::donation::MemoryPressure::normal;
    neostation::donation::derive_system_budget(system, 7516192768ULL, 85, true);
    assert(system.kernel_estimate_valid && system.usable_bytes > 128 * MiB);
    assert(system.usable_bytes < 7516192768ULL && !host().donated_live_bytes);
    system.pressure = neostation::donation::MemoryPressure::warning;
    neostation::donation::derive_system_budget(system, 7516192768ULL, 85, true);
    assert(!system.usable_bytes);
    system.pressure = neostation::donation::MemoryPressure::unobserved;
    neostation::donation::derive_system_budget(system, 7516192768ULL, 101, true);
    assert(!system.kernel_estimate_valid && !system.usable_bytes);
    neostation::donation::derive_system_budget(system, 7516192768ULL, 85, false);
    assert(!system.kernel_estimate_valid && !system.usable_bytes);
    system.free_bytes = 1024 * MiB;
    system.purgeable_bytes = 0;
    neostation::donation::derive_system_budget(system, 7516192768ULL, 0, true);
    assert(system.kernel_estimate_valid && !system.usable_bytes);
    neostation::donation::derive_system_budget(system, 7516192768ULL, 0, false);
    assert(!system.kernel_estimate_valid && system.usable_bytes == 512 * MiB);
    system.pressure = neostation::donation::MemoryPressure::critical;
    system.free_bytes = UINT64_MAX;
    neostation::donation::derive_system_budget(system, UINT64_MAX, 100, true);
    assert(!system.usable_bytes);
    char directory[] = "/tmp/neoswap-demand-test-XXXXXX";
    assert(mkdtemp(directory));
    const auto* api = NeoSwap_GetAPI(1);
    NeoSwapConfig config{sizeof(config), NEOSWAP_ABI, 8 * MiB, 0, MiB, 0x3f, 0};
    assert(NeoSwap_Configure(directory, &config) == NEOSWAP_OK);
    assert(!claim().bytes && !host().donor_pending_demand_count);
    const auto request = [&](uint32_t owner, uint64_t bytes) {
        void* pointer = nullptr;
        assert(api->allocate(owner, NEOSWAP_CPU_DATA, bytes, 65536, &pointer) == NEOSWAP_OK);
        auto* data = static_cast<unsigned char*>(pointer);
        data[0] = 0x35; data[bytes - 1] = 0x91;
        assert(api->sync(pointer) == NEOSWAP_OK);
        assert(data[0] == 0x35 && data[bytes - 1] == 0x91);
        assert(!host().donated_live_bytes && !host().owner_donated_live_bytes[NEOSWAP_RPCS3]);
        assert(api->release(pointer) == NEOSWAP_OK);
        assert(!host().reserved_virtual_bytes);
    };
    request(NEOSWAP_PROBE, MiB);
    request(NEOSWAP_DOLPHIN, MiB);
    void* invalid = nullptr;
    assert(api->allocate(NEOSWAP_RPCS3, NEOSWAP_CPU_DATA, 257 * MiB, 65536, &invalid) == NEOSWAP_QUOTA);
    assert(api->allocate(NEOSWAP_RPCS3, NEOSWAP_CPU_DATA, MiB, 3, &invalid) == NEOSWAP_INVALID);
    assert(api->allocate(NEOSWAP_RPCS3, NEOSWAP_CPU_DATA, 1024, 16, &invalid) == NEOSWAP_TOO_SMALL);
    assert(!claim().bytes); // probes, unsupported requests and small buffers never grow donors
    config.capacity_bytes = 512 * MiB;
    assert(NeoSwap_Configure(directory, &config) == NEOSWAP_OK);
    request(NEOSWAP_RPCS3, 257 * MiB); // the donation chunk bound never narrows the real file ABI
    assert(!claim().bytes && !host().donated_live_bytes);
    config.capacity_bytes = 8 * MiB;
    assert(NeoSwap_Configure(directory, &config) == NEOSWAP_OK);
    request(NEOSWAP_RPCS3, 4 * MiB);
    auto first = claim();
    assert(first.bytes == 4 * MiB && first.sequence);
    assert(host().donor_inflight_demand_bytes == 4 * MiB);
    assert(claim().sequence == first.sequence); // refusal/loss never consumes a claim
    assert(NeoSwap_AcknowledgeDonationDemand(first.sequence + 1) == NEOSWAP_NOT_OWNED);
    assert(claim().sequence == first.sequence);
    request(NEOSWAP_RPCS3, 4 * MiB); // new request while the first is in flight
    request(NEOSWAP_RPCS3, 2 * MiB); // a smaller request is not blocked by an unsatisfied large one
    auto smaller = claim();
    assert(smaller.bytes == 2 * MiB && smaller.sequence != first.sequence);
    assert(NeoSwap_AcknowledgeDonationDemand(first.sequence) == NEOSWAP_NOT_OWNED);
    assert(host().donor_pending_demand_count == 1); // identical queued sizes coalesce
    assert(NeoSwap_AcknowledgeDonationDemand(smaller.sequence) == NEOSWAP_OK);
    auto newer = claim();
    assert(newer.bytes == 4 * MiB && newer.sequence > first.sequence);
    request(NEOSWAP_RPCS3, MiB);
    assert(NeoSwap_AcknowledgeDonationDemand(newer.sequence) == NEOSWAP_OK);
    auto last = claim();
    assert(last.bytes == MiB && last.sequence > newer.sequence);
    assert(NeoSwap_AcknowledgeDonationDemand(last.sequence) == NEOSWAP_OK);
    assert(!claim().bytes && !host().donor_pending_demand_count);
    const uint64_t page = static_cast<uint64_t>(sysconf(_SC_PAGESIZE));
    for (uint64_t n = 0; n < 64; ++n) request(NEOSWAP_RPCS3, 2 * MiB + n * page);
    assert(host().donor_pending_demand_count == 64);
    request(NEOSWAP_RPCS3, 3 * MiB);
    request(NEOSWAP_RPCS3, MiB);
    assert(host().donor_pending_demand_count == 64 && host().donor_demand_overflow_count == 2);
    assert(claim().bytes == MiB); // bounded queue still prioritizes a new satisfiable small request
    NeoSwapStats stats{}; stats.struct_size = sizeof(stats);
    assert(NeoSwap_Snapshot(&stats) == NEOSWAP_OK && !stats.live_blocks && !stats.allocated_disk_bytes);
    assert(!host().donated_live_bytes && !host().reserved_virtual_bytes);
    config.capacity_bytes = 0;
    assert(NeoSwap_Configure(directory, &config) == NEOSWAP_OK && rmdir(directory) == 0);
    std::puts("PASS: real file fallback including 257MiB, eligible demand only, coalescing, failed/lost claim retention, smaller-request priority, new-demand preservation during a claim, bounded overflow; no donated-RAM claim");
}
