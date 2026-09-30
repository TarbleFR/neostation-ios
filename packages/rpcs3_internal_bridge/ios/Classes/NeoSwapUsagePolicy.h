#pragma once
#include <neo_swap/NeoSwapClientStats.h>
#include <neo_swap/NeoSwapHost.h>

// Live buffers take precedence over a lost backend. Readiness comes from a
// configured file owner or verified donor pages, never a virtual reservation.
enum class NeoSwapUsageStatus {
    unavailable, clientUnavailable, disabled, waiting, small,
    rejected, released, active
};
inline bool NeoSwapDonorMeasured(const NeoSwapHostStats* host) noexcept {
    return host && host->donation_state == 2 && host->donor_count && host->donor_prepared_bytes;
}
inline NeoSwapUsageStatus NeoSwapUsage(uint64_t live, const NeoSwapClientStats* client,
                                     const NeoSwapHostStats* host) noexcept {
    if (live) return NeoSwapUsageStatus::active;
    if (!host) return NeoSwapUsageStatus::unavailable;
    const bool fileReady = host->file_ready_owner_mask & (1u << NEOSWAP_RPCS3);
    const bool donorReady = NeoSwapDonorMeasured(host);
    if (!fileReady && !donorReady) return NeoSwapUsageStatus::unavailable;
    if (!client) return NeoSwapUsageStatus::clientUnavailable;
    if (client->eligible_attempts && client->last_result != NEOSWAP_OK)
        return NeoSwapUsageStatus::rejected;
    if (client->successful_allocations) return NeoSwapUsageStatus::released;
    if (client->disabled) return NeoSwapUsageStatus::disabled;
    if (client->missing_api) return NeoSwapUsageStatus::clientUnavailable;
    if (!client->eligible_attempts && client->skipped_small) return NeoSwapUsageStatus::small;
    return NeoSwapUsageStatus::waiting;
}
