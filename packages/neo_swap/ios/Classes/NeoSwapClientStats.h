#pragma once
#include <stdint.h>

// Optional diagnostic getter, independent of both the allocator v1 vtable and
// RPCS3's runtime ABI. Counts reflect actual allocator decisions, not RAM gains.
enum { NEOSWAP_CLIENT_STATS_ABI = 1 };
typedef struct NeoSwapClientStats {
    uint32_t struct_size, abi_version;
    uint64_t skipped_small, missing_api, disabled;
    uint64_t eligible_attempts, failed_allocations, successful_allocations;
    int32_t last_result;
    uint32_t reserved;
} NeoSwapClientStats;
