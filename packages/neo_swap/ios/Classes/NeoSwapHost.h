#pragma once
#include "NeoSwap.h"

// Host diagnostics are separate from the immutable v1 emulator ABI. A virtual
// reservation consumes address space only; it is not donated RAM or disk space.
typedef struct NeoSwapHostStats {
    uint64_t reserved_virtual_bytes, disk_free_bytes, remaining_storage_bytes;
    int32_t reservation_result, reservation_errno;
    int32_t owner_last_result[NEOSWAP_OWNER_COUNT];
    int32_t owner_last_errno[NEOSWAP_OWNER_COUNT];
    // Actual loans from verified donor-owned Mach objects, separate from files
    // and untouched virtual capacity. Charge readings are valid in state 2 only.
    uint64_t donated_live_bytes, donor_prepared_bytes, donor_footprint_bytes;
    uint64_t donor_nonvolatile_bytes, donor_compressed_bytes;
    uint64_t donor_generation;
    int32_t donor_pid, donation_state, donation_last_stage, donation_last_kernel_result;
} NeoSwapHostStats;

#ifdef __cplusplus
extern "C" {
#endif
NEOSWAP_PUBLIC int NeoSwap_HostSnapshot(NeoSwapHostStats* stats);
// Refresh disk-capacity fields on a background diagnostics queue. The fast
// HostSnapshot getter only copies cached fields and never queries filesystem.
NEOSWAP_PUBLIC int NeoSwap_StorageSnapshot(NeoSwapHostStats* stats);
#ifdef __cplusplus
}
#endif
