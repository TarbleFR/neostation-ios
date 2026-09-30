// The getter is compiled separately from the real production source body.
#include "rpcs3/ios/RPCS3IOS.h"
#include "rpcs3/ios/NeoSwapClient.h"
#include <cassert>
#include <cstddef>
#include <cstdio>
#include <cstring>
#include <initializer_list>

static_assert(sizeof(NeoSwapClientStats) == 64);
static_assert(offsetof(NeoSwapClientStats, skipped_small) == 8);
static_assert(offsetof(NeoSwapClientStats, last_result) == 56);
static_assert(RPCS3_IOS_ABI_VERSION == 30u);
static_assert(NEOSWAP_ABI == 1);

int main() {
    assert(rpcs3_ios_get_neoswap_client_stats(nullptr) == NEOSWAP_INVALID);
    NeoSwapClientStats stats{};
    stats.struct_size = sizeof(stats);
    stats.abi_version = NEOSWAP_CLIENT_STATS_ABI;
    stats.reserved = 0x12345678;
    for (int invalid : {0, 1}) {
        auto bad = stats;
        if (!invalid) --bad.struct_size;
        else ++bad.abi_version;
        const auto original = bad;
        assert(rpcs3_ios_get_neoswap_client_stats(&bad) == NEOSWAP_INVALID);
        assert(std::memcmp(&bad, &original, sizeof(bad)) == 0);
    }
    assert(rpcs3_ios_get_neoswap_client_stats(&stats) == NEOSWAP_OK);
    assert(stats.skipped_small == 0 && stats.missing_api == 0 && stats.disabled == 0);
    assert(stats.eligible_attempts == 0 && stats.failed_allocations == 0 && stats.successful_allocations == 0);
    assert(stats.last_result == NEOSWAP_OK && stats.reserved == 0);
    // The allocator and getter are separate translation units. They must
    // share inline client counters without importing the broker or running
    // any initialization routine during a Core's passive dlopen.
    assert(!neostation::swap::try_allocate(NEOSWAP_RPCS3, 64, 64));
    assert(!neostation::swap::try_allocate(NEOSWAP_RPCS3, 1024 * 1024, 64));
    assert(rpcs3_ios_get_neoswap_client_stats(&stats) == NEOSWAP_OK);
    assert(stats.skipped_small == 1 && stats.missing_api == 1);
    assert(stats.eligible_attempts == 0 && stats.failed_allocations == 0 && stats.successful_allocations == 0);
    std::puts("PASS RPCS3 optional NeoSwap getter: layout, null/size/version validation, shared counters, no broker dependency");
}
