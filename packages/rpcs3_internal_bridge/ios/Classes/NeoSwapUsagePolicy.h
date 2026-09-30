#pragma once
#include <neo_swap/NeoSwapClientStats.h>
#include <neo_swap/NeoSwapHost.h>

// Read actual counters without interpreting virtual addresses as physical RAM.
enum class NeoSwapUsageStatus {
    unavailable, clientUnavailable, disabled, waiting, small,
    rejected, released, active
};
inline NeoSwapUsageStatus NeoSwapUsage(uint64_t live, const NeoSwapClientStats* client,
                                     const NeoSwapHostStats* host) noexcept {
  if (!host || ((host->reservation_result != NEOSWAP_OK || !host->reserved_virtual_bytes) &&
                !(host->donation_state == 2 && host->donor_prepared_bytes)))
        return NeoSwapUsageStatus::unavailable;
    if (live) return NeoSwapUsageStatus::active;
    if (!client) return NeoSwapUsageStatus::clientUnavailable;
    if (client->eligible_attempts && client->last_result != NEOSWAP_OK)
        return NeoSwapUsageStatus::rejected;
    if (client->successful_allocations) return NeoSwapUsageStatus::released;
    if (client->disabled) return NeoSwapUsageStatus::disabled;
    if (client->missing_api) return NeoSwapUsageStatus::clientUnavailable;
    if (!client->eligible_attempts && client->skipped_small) return NeoSwapUsageStatus::small;
    return NeoSwapUsageStatus::waiting;
}
