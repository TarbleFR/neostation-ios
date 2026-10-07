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
    // Live relay-backed host loans per owner; distinct from donor loans and files.
    uint64_t owner_relay_live_bytes[NEOSWAP_OWNER_COUNT];
    uint64_t relay_loan_live_bytes;
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

// Cumulative acquisition telemetry. These counts are host acquisition attempts,
// independent of RPCS3 guest range-lock waits and OS page-fault measurements.
typedef struct NeoSwapFastStats {
    uint64_t requests, successes, broker_busy, donor_busy, ready_misses;
    uint64_t fallback_count, total_time_us, max_time_us;
    uint64_t prepare_requests, prepared_loans, prepare_failures;
    uint64_t retire_requests, retired_loans, retire_failures;
} NeoSwapFastStats;

typedef struct NeoSwapDonationDemand {
    uint64_t sequence, bytes;
} NeoSwapDonationDemand;

// Host-side view of the additive allocation kinds the RPCS3 client sends
// through the unchanged NeoSwapAPI v1 table. Values mirror the Core's
// NeoSwapClient.h extended kinds; a test asserts both definitions agree.
// Kinds identify the RPCS3 consumer of every loan; they never change ownership
// rules, alignment limits or the release contract.
enum NeoSwapHostKind {
    NEOSWAP_HOST_KIND_CPU_DATA = 1,         /* RSX aligned CPU data >= 1 MiB */
    NEOSWAP_HOST_KIND_CPU_CACHE = 2,        /* RSX aligned CPU data 64 KiB..1 MiB */
    NEOSWAP_HOST_KIND_GPU_HOST_VISIBLE = 3, /* coherent host-visible Vulkan SYSTEM buffers */
    NEOSWAP_HOST_KIND_VIDEO_FRAME = 4,      /* owned software VDEC frame mappings */
    NEOSWAP_HOST_KIND_COUNT = 5
};

// Relay-backed HOST loans: RPCS3 host data served from the guest page relay's
// retained named objects (creator exited, pages charged outside the host
// footprint). Counts are cumulative independent atomics; live/cached/peak are
// byte counts of allocated backing intervals, never resident-page proof.
typedef struct NeoSwapRelayLoanStats {
    uint64_t live_bytes, peak_bytes, live_blocks, allocation_count;
    uint64_t quota_bytes, policy_refusals, quota_refusals, backend_refusals;
    uint64_t reuse_hits, cached_bytes, cached_blocks, cache_flushes;
    uint64_t release_failures, padding_bytes;
    uint64_t kind_live_bytes[NEOSWAP_HOST_KIND_COUNT], kind_live_blocks[NEOSWAP_HOST_KIND_COUNT];
    uint64_t kind_allocation_count[NEOSWAP_HOST_KIND_COUNT], kind_refusal_count[NEOSWAP_HOST_KIND_COUNT];
    int32_t last_backend_result;
    uint32_t admitted, available, video_frames_admitted;
} NeoSwapRelayLoanStats;

#ifdef __cplusplus
extern "C" {
#endif
NEOSWAP_PUBLIC int NeoSwap_FastSnapshot(NeoSwapFastStats* stats);
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
// Global budget controller outputs, applied on the diagnostics timer. A quota
// below the live value refuses new loans only; existing loans are retained.
// video_frames selects whether kind 4 may borrow relay pages at all.
NEOSWAP_PUBLIC int NeoSwap_SetRelayHostLoanPolicy(uint64_t quota_bytes, int admitted, int video_frames);
// Completes up to 32 relinquished FAST loans (relay or donors), retaining
// ownership on cleanup failure. Also retires cached (released, still mapped) loans older than the bounded reuse
// window, or every cached loan when flush_all is set. Maintenance only.
// now_ms = 0 uses the broker's own monotonic clock, the one that stamps
// releases; tests may pass an explicit value on that same base.
NEOSWAP_PUBLIC int NeoSwap_RelayLoanMaintain(uint64_t now_ms, int flush_all);
NEOSWAP_PUBLIC int NeoSwap_RelayLoanSnapshot(NeoSwapRelayLoanStats* stats);
#ifdef __cplusplus
}
#endif
