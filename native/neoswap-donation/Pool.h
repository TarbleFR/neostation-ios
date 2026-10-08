#pragma once

#include "Broker.h"

namespace neostation::donation {

enum class PoolState : std::uint32_t { unavailable, preparing, verified, donor_lost };
struct PoolSnapshot {
  std::uint64_t generation = 0;
  std::int32_t donor_pid = 0;
  PoolState state = PoolState::unavailable;
  Stage last_stage = Stage::none;
  std::int32_t last_kernel_result = 0;
  std::uint64_t prepared_bytes = 0;
  std::uint64_t live_bytes = 0;
  std::uint64_t live_blocks = 0;
  std::uint64_t peak_live_bytes = 0;
  std::uint64_t donor_footprint = 0;
  std::uint64_t donor_nonvolatile = 0;
  std::uint64_t donor_nonvolatile_compressed = 0;
  std::uint64_t target_bytes = 0;
  std::uint64_t retained_bytes = 0;
  std::uint64_t retained_live_bytes = 0;
  std::uint64_t resident_bytes = 0;
  std::uint64_t compressed_bytes = 0;
  std::uint64_t verified_chunks = 0;
  std::uint32_t donor_count = 0;
  std::uint32_t lost_donor_count = 0;
};

struct PoolDonorSnapshot {
  std::uint64_t generation = 0;
  std::int32_t pid = 0;
  PoolState state = PoolState::unavailable;
  std::uint64_t prepared_bytes = 0;
  std::uint64_t retained_bytes = 0;
  std::uint64_t live_bytes = 0;
  std::uint64_t resident_bytes = 0;
  std::uint64_t compressed_bytes = 0;
  std::uint64_t footprint_bytes = 0;
  std::uint64_t nonvolatile_bytes = 0;
  std::uint64_t nonvolatile_compressed_bytes = 0;
  std::uint64_t verified_chunks = 0;
  Stage last_stage = Stage::none;
  std::int32_t last_kernel_result = 0;
};

// Eight distinct donor PIDs. One campaign owns the global target/quota. Only
// chunks confirmed by the IPC page/ledger proof may become new local loans.
Result pool_campaign_begin(std::uint64_t epoch, std::uint64_t target_bytes) noexcept;
// End one campaign only after every live loan has been returned. This drops
// retained host mappings so the donor processes can be closed without
// carrying unused prepared pages into the next RPCS3 session.
Result pool_campaign_end(std::uint64_t epoch) noexcept;
Result pool_donor_begin(std::uint64_t epoch, std::uint32_t index,
    std::uint64_t generation, std::int32_t pid) noexcept;
Result pool_adopt_donor(std::uint64_t epoch, std::uint32_t index,
    std::uint64_t generation, std::uint64_t chunk_index,
    std::uint32_t entry, std::size_t bytes) noexcept;
Result pool_verify_donor(std::uint64_t epoch, std::uint32_t index,
    std::uint64_t generation, std::uint64_t verified_capacity,
    const Footprint& donor, std::uint64_t resident_delta,
    std::uint64_t compressed_delta) noexcept;
void pool_donor_lost(std::uint64_t epoch, std::uint32_t index,
    std::uint64_t generation, std::int32_t reason) noexcept;
void pool_donor_snapshot(std::uint32_t index, PoolDonorSnapshot& out) noexcept;
// Background collection only; live borrowed intervals are never touched.
Result pool_collect_lost() noexcept;
// Atomically stop offering a donor only if none of its entries is borrowed.
// No OS cleanup here: the manager closes the helper and collects lost entries
// on its maintenance queue. A live loan makes this a refusal with no revocation.
Result pool_retire_idle_donor(std::uint64_t epoch, std::uint32_t index,
    std::uint64_t generation) noexcept;
bool pool_donor_restartable(std::uint64_t epoch, std::uint32_t index) noexcept;

// Called by the async, authenticated process manager. API success, an extension
// PID and virtual entries alone must never cause pool_verified to be called.
// Verification requires shared-page round trips and actual footprint ledgers.
// Starting a later generation is refused until all earlier loans are released.
// These single-donor wrappers are retained for the original kernel probes.
Result pool_begin(std::uint64_t generation, std::int32_t donor_pid,
                  std::uint64_t max_shared_bytes) noexcept;
Result pool_adopt(std::uint64_t generation, std::uint32_t entry,
                  std::size_t bytes) noexcept;
Result pool_verified(std::uint64_t generation, const Footprint& donor) noexcept;
void pool_footprint(std::uint64_t generation, const Footprint& donor) noexcept;
void pool_lost(std::uint64_t generation, std::int32_t reason) noexcept;
void pool_snapshot(PoolSnapshot& out) noexcept;

// Acquisition uses try_lock and returns pool_busy on contention.
// No XPC, files, allocation or page writes on these paths. Existing mappings
// remain valid when a helper disconnects; only new loans stop. Tokens are unique
// until process death, so a late release cannot free another allocation.
Result pool_acquire(std::uint64_t bytes, std::uint64_t alignment,
                    void** out, std::uint64_t* token) noexcept;
Result pool_release(std::uint64_t token) noexcept;

}  // namespace neostation::donation
