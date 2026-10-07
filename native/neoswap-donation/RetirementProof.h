// Native proof support only: standalone probes do not run the app's maintenance
// timer. Drive the actual broker after users/GPU have relinquished FAST loans,
// and prove both host accounting and donor pool ownership really reach zero.
#pragma once
#include "Pool.h"
#include "NeoSwapHost.h"
#include <algorithm>
#include <chrono>
#include <cstdint>

namespace neostation::donation {
struct RetirementProof {
    bool passed = false;
    std::uint64_t queued_loans = 0, queued_bytes = 0, completed_loans = 0, pending_loans = 0;
    std::uint64_t failures = 0, elapsed_us = 0, host_live_bytes = 0, donated_live_bytes = 0;
    std::uint64_t pool_live_bytes = 0, pool_live_blocks = 0;
    unsigned passes = 0, maximum_passes = 0;
};
inline RetirementProof prove_fast_retirement(std::uint64_t expected_loans,
    std::uint64_t expected_bytes, const NeoSwapFastStats& before_release) noexcept {
    RetirementProof proof{};
    // Production maintenance drains at most 32 loans per call. Permit four
    // bounded retry passes, never an unbounded wait that conceals a real leak.
    if (!expected_loans || expected_loans > 1024 || !expected_bytes ||
        before_release.retire_requests != before_release.retired_loans) return proof;
    proof.maximum_passes = static_cast<unsigned>((expected_loans + 31) / 32 + 4);
    const auto started = std::chrono::steady_clock::now();
    const auto deadline = started + std::chrono::seconds(2);
    NeoSwapFastStats fast{};
    NeoSwapHostStats host{};
    PoolSnapshot pool{};
    const auto observe = [&] {
        if (NeoSwap_FastSnapshot(&fast) != NEOSWAP_OK || NeoSwap_HostSnapshot(&host) != NEOSWAP_OK ||
            fast.retire_requests < before_release.retire_requests ||
            fast.retired_loans < before_release.retired_loans ||
            fast.retire_failures < before_release.retire_failures ||
            fast.retire_requests < fast.retired_loans) return false;
        pool_snapshot(pool);
        if (pool.last_stage == Stage::snapshot_busy) return false;
        proof.queued_loans = fast.retire_requests - before_release.retire_requests;
        proof.completed_loans = fast.retired_loans - before_release.retired_loans;
        proof.pending_loans = fast.retire_requests - fast.retired_loans;
        proof.failures = fast.retire_failures - before_release.retire_failures;
        proof.host_live_bytes = NeoSwap_LiveBytes(NEOSWAP_RPCS3);
        proof.donated_live_bytes = host.owner_donated_live_bytes[NEOSWAP_RPCS3];
        proof.pool_live_bytes = pool.live_bytes;
        proof.pool_live_blocks = pool.live_blocks;
        proof.elapsed_us = static_cast<std::uint64_t>(std::chrono::duration_cast<std::chrono::microseconds>(
            std::chrono::steady_clock::now() - started).count());
        return true;
    };
    if (!observe()) return proof;
    proof.queued_bytes = proof.donated_live_bytes;
    // Destruction only transferred cleanup. All expected loans must still be
    // owned before the standalone probe supplies its missing maintenance tick.
    if (proof.queued_loans != expected_loans || proof.completed_loans ||
        proof.pending_loans != expected_loans || proof.host_live_bytes != expected_bytes ||
        proof.donated_live_bytes != expected_bytes || proof.pool_live_bytes != expected_bytes ||
        proof.pool_live_blocks != expected_loans) return proof;
    while (proof.passes < proof.maximum_passes && std::chrono::steady_clock::now() < deadline) {
        // A donor-only build returns RELAY_DISABLED after draining FAST loans;
        // evidence is the actual ownership/counters, never that relay status.
        (void)NeoSwap_RelayLoanMaintain(0, 1);
        ++proof.passes;
        if (!observe()) return proof;
        if (proof.queued_loans == expected_loans && proof.completed_loans == expected_loans &&
            !proof.pending_loans && !proof.host_live_bytes && !proof.donated_live_bytes &&
            !proof.pool_live_bytes && !proof.pool_live_blocks && std::chrono::steady_clock::now() <= deadline) {
            proof.passed = true;
            return proof;
        }
    }
    return proof;
}
} // namespace neostation::donation
