#pragma once
#include <string_view>
#include <cmath>
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
    // Physical footprint of the RPCS3 task (kernel ledger), see deviceRam.
    uint64_t footprint = 0;
    // HOST data NeoSwap supplies outside the process footprint: relay host
    // loans (RSX data, Vulkan buffers, video frames) plus donor loans. Guest
    // pages are part of `allocated` but not of this contribution figure.
    uint64_t hostLoans = 0;
    // RAM the device spends on the session (maintainer request of 7 October
    // 2026): the RPCS3 task physical footprint (kernel ledger, compressed pages
    // included) merged with the NeoSwap backing charged to its microprocesses
    // (`allocated`). Donor and relay pages are charged to the microprocess that
    // owns them and not to this footprint, even though their aliases are mapped
    // and resident in RPCS3: the resident counter would count them twice, the
    // footprint does not. The overlay draws only this merged line and the
    // NeoSwap contribution; microprocesses are no longer shown separately.
    // Valid whenever the footprint is; the backing is added only when measured.
    uint64_t deviceRam = 0;
    bool allocatedValid = false;
    bool footprintValid = false;
    bool hostLoansValid = false;
    bool deviceRamValid = false;
};
inline uint64_t NeoSwapHostLoanBytes(const NeoSwapHostStats* host) noexcept {
    if (!host) return 0;
    const uint64_t donor = host->owner_donated_live_bytes[NEOSWAP_RPCS3];
    return host->relay_loan_live_bytes > UINT64_MAX - donor ? UINT64_MAX : host->relay_loan_live_bytes + donor;
}
inline NeoSwapMemoryGraphPoint NeoSwapMemoryGraph(const NeoSwapHostStats* host,
    uint64_t relayLiveBacking, bool relayMeasured, uint64_t processFootprint) noexcept {
    NeoSwapMemoryGraphPoint point{};
    point.footprint = processFootprint;
    point.footprintValid = processFootprint != 0;
    if (host) {
        point.hostLoans = NeoSwapHostLoanBytes(host);
        point.hostLoansValid = true;
    }
    if (host && relayMeasured) {
        const uint64_t loans = host->owner_donated_live_bytes[NEOSWAP_RPCS3];
        if (relayLiveBacking <= UINT64_MAX - loans) {
            point.allocated = loans + relayLiveBacking;
            point.allocatedValid = true;
        }
    }
    if (point.footprintValid) {
        const uint64_t backing = point.allocatedValid ? point.allocated : 0;
        point.deviceRam = point.footprint > UINT64_MAX - backing ? UINT64_MAX : point.footprint + backing;
        point.deviceRamValid = true;
    }
    return point;
}
constexpr double NeoSwapDecimalGB(uint64_t bytes) noexcept {
    return static_cast<double>(bytes) / 1000000000.0;
}

// Zero FPS is a valid stalled-frame sample, not an unavailable measurement.
inline bool NeoSwapFPSValid(double fps, uint32_t validFields) noexcept {
    return (validFields & 1U) && std::isfinite(fps) && fps >= 0.0;
}

inline bool NeoSwapCPUBufferTitle(std::string_view title) noexcept {
    return title == "BCES00510" || title == "BCES00799" || title == "BCUS98111" ||
        title == "BCJS37001" || title == "BCAS25003" || title == "BCKS15003";
}
