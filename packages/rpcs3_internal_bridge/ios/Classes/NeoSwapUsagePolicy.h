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

// Distinct live objects only. Prepared pools, file fallback and VM aliases are
// not extra microprocess allocations. This is not a physical-residency sum.
struct NeoSwapMemoryGraphPoint {
    uint64_t allocated = 0;
    uint64_t resident = 0;
    bool allocatedValid = false;
    bool residentValid = false;
};
inline NeoSwapMemoryGraphPoint NeoSwapMemoryGraph(const NeoSwapHostStats* host,
    uint64_t relayLiveBacking, bool relayMeasured, uint64_t processResident) noexcept {
    NeoSwapMemoryGraphPoint point{};
    point.resident = processResident;
    point.residentValid = processResident != 0;
    if (host && relayMeasured) {
        const uint64_t loans = host->owner_donated_live_bytes[NEOSWAP_RPCS3];
        if (relayLiveBacking <= UINT64_MAX - loans) {
            point.allocated = loans + relayLiveBacking;
            point.allocatedValid = true;
        }
    }
    return point;
}
constexpr double NeoSwapDecimalGB(uint64_t bytes) noexcept {
    return static_cast<double>(bytes) / 1000000000.0;
}
