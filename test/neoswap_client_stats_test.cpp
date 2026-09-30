#include "NeoSwapClient.h"
#include <cassert>
#include <cstdio>
#include <cstdlib>
#include <unistd.h>

static NeoSwapClientStats snapshot() {
    NeoSwapClientStats stats{};
    stats.struct_size = sizeof(stats);
    stats.abi_version = NEOSWAP_CLIENT_STATS_ABI;
    assert(neostation::swap::snapshot(&stats) == NEOSWAP_OK);
    return stats;
}

int main() {
    static_assert(sizeof(NeoSwapClientStats) == 64);
    constexpr size_t MiB = 1024 * 1024;
    char directory[] = "/tmp/neoswap-client-stats-XXXXXX";
    assert(mkdtemp(directory));
    assert(!neostation::swap::try_allocate(NEOSWAP_RPCS3, 1024, 16));
    assert(snapshot().skipped_small == 1 && !snapshot().eligible_attempts);
    assert(!neostation::swap::try_allocate(NEOSWAP_RPCS3, MiB, 16));
    assert(snapshot().missing_api == 1 && !snapshot().eligible_attempts);
    const NeoSwapAPI* api = NeoSwap_GetAPI(NEOSWAP_ABI);
    assert(neostation::swap::install(api) == NEOSWAP_OK);
    assert(!neostation::swap::try_allocate(NEOSWAP_RPCS3, MiB, 16));
    assert(snapshot().disabled == 1 && !snapshot().eligible_attempts);
    NeoSwapConfig config{sizeof(config), NEOSWAP_ABI, 8*MiB, 0, MiB, 1u, 0};
    assert(NeoSwap_Configure(directory, &config) == NEOSWAP_OK);
    void* address = neostation::swap::try_allocate(NEOSWAP_RPCS3, MiB, 16);
    assert(address && snapshot().eligible_attempts == 1);
    assert(snapshot().successful_allocations == 1 && !snapshot().failed_allocations);
    assert(!neostation::swap::try_allocate(NEOSWAP_RPCS3, 8*MiB, 16));
    assert(snapshot().failed_allocations == 1 && snapshot().eligible_attempts == 2);
    assert(snapshot().last_result == NEOSWAP_QUOTA);
    assert(neostation::swap::release(address) == NEOSWAP_OK);
    NeoSwapClientStats invalid{};
    invalid.struct_size = sizeof(invalid);
    invalid.abi_version = 99;
    assert(neostation::swap::snapshot(&invalid) == NEOSWAP_INVALID);
    assert(invalid.abi_version == 99 && !invalid.skipped_small);
    assert(neostation::swap::snapshot(nullptr) == NEOSWAP_INVALID);
    invalid.abi_version = NEOSWAP_CLIENT_STATS_ABI;
    invalid.struct_size -= 1;
    assert(neostation::swap::snapshot(&invalid) == NEOSWAP_INVALID);
    config.capacity_bytes = 0;
    assert(NeoSwap_Configure(nullptr, &config) == NEOSWAP_OK);
    assert(rmdir(directory) == 0);
    puts("PASS: client telemetry distinguishes small, unbound, disabled, succeeded and rejected real allocator paths; v1 ABI unchanged");
}
