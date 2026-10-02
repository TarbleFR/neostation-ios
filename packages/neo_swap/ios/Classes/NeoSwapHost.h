#pragma once
#include "NeoSwap.h"

// Host diagnostics are separate from the immutable v1 emulator ABI. A virtual
// reservation consumes address space only; it is not donated RAM or disk space.
typedef struct NeoSwapHostStats {
    uint64_t reserved_virtual_bytes, disk_free_bytes, remaining_storage_bytes;
    int32_t reservation_result, reservation_errno;
    int32_t owner_last_result[NEOSWAP_OWNER_COUNT];
    int32_t owner_last_errno[NEOSWAP_OWNER_COUNT];
    uint64_t owner_donated_live_bytes[NEOSWAP_OWNER_COUNT];
    // Actual loans from verified donor-owned Mach objects, separate from files
    // and untouched virtual capacity. Charge readings are valid in state 2 only.
    uint64_t donated_live_bytes, donor_prepared_bytes, donor_footprint_bytes;
    uint64_t donor_nonvolatile_bytes, donor_compressed_bytes;
    uint64_t donor_generation;
    int32_t donor_pid, donation_state, donation_last_stage, donation_last_kernel_result;
    uint64_t donor_target_bytes, donor_retained_bytes, donor_retained_live_bytes;
    uint64_t donor_resident_bytes, donor_accounted_compressed_bytes;
    uint32_t donor_count, donor_lost_count;
    uint32_t file_ready_owner_mask;
    uint64_t donor_pending_demand_bytes, donor_inflight_demand_bytes;
    uint64_t donor_pending_demand_count, donor_demand_overflow_count;
} NeoSwapHostStats;

// Host-only counters, not additions to the immutable emulator API/stats ABI.
// Sub-MiB borrowing is an experiment with actual CPU buffers, not a capacity test.
// Counts are cumulative independent atomic observations; live/peak are byte counts.
typedef struct NeoSwapCPUBufferStats {
    uint64_t requests, requested_bytes, successful_allocations, fallback_count;
    uint64_t live_bytes, peak_bytes, live_blocks, allocated_bytes;
    uint64_t pressure_refusals, policy_refusals, pool_misses;
    uint64_t request_bins[4], donated_bins[4];
    uint32_t enabled, pressure_raised;
} NeoSwapCPUBufferStats;

typedef struct NeoSwapDonationDemand {
    uint64_t sequence, bytes;
} NeoSwapDonationDemand;

#ifdef __cplusplus
extern "C" {
#endif
NEOSWAP_PUBLIC int NeoSwap_HostSnapshot(NeoSwapHostStats* stats);
// These settings never migrate or free an existing allocation. Disable on exit.
NEOSWAP_PUBLIC void NeoSwap_SetCPUBufferExperiment(int enabled);
NEOSWAP_PUBLIC void NeoSwap_SetCPUBufferPressure(int raised);
NEOSWAP_PUBLIC int NeoSwap_CPUBufferSnapshot(NeoSwapCPUBufferStats* stats);
// Refresh disk-capacity fields on a background diagnostics queue. The fast
// HostSnapshot getter only copies cached fields and never queries filesystem.
NEOSWAP_PUBLIC int NeoSwap_StorageSnapshot(NeoSwapHostStats* stats);
// Background manager only. A claimed failed RPCS3 request persists until the
// newly verified block is adopted/acknowledged; later requests stay queued.
NEOSWAP_PUBLIC int NeoSwap_ClaimDonationDemand(NeoSwapDonationDemand* demand);
NEOSWAP_PUBLIC int NeoSwap_AcknowledgeDonationDemand(uint64_t sequence);
// Host-only lifecycle signal. It does not change allocator ABI v1; the donor
// manager uses it to warm while an emulator session is active and retire
// verified pages once that session has fully released its loans.
NEOSWAP_PUBLIC int NeoSwap_SetOwnerSessionActive(uint32_t owner, int active);
NEOSWAP_PUBLIC int NeoSwap_OwnerSessionActive(uint32_t owner);
// Bounded host-side readiness wait used off the main thread before emulator
// boot. It observes only verified donor capacity and never creates memory.
NEOSWAP_PUBLIC int NeoSwap_WaitForDonationReady(uint64_t minimum_bytes, uint32_t timeout_ms);
#ifdef __cplusplus
}
#endif
