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
};

// Called by the async, authenticated process manager. API success, an extension
// PID and virtual entries alone must never cause pool_verified to be called.
// Verification requires shared-page round trips and actual footprint ledgers.
// Starting a later generation is refused until all earlier loans are released.
Result pool_begin(std::uint64_t generation, std::int32_t donor_pid,
                  std::uint64_t max_shared_bytes) noexcept;
Result pool_adopt(std::uint64_t generation, std::uint32_t entry,
                  std::size_t bytes) noexcept;
Result pool_verified(std::uint64_t generation, const Footprint& donor) noexcept;
void pool_footprint(std::uint64_t generation, const Footprint& donor) noexcept;
void pool_lost(std::uint64_t generation, std::int32_t reason) noexcept;
void pool_snapshot(PoolSnapshot& out) noexcept;

// No XPC, files, allocation or page writes on these paths. Existing mappings
// remain valid when a helper disconnects; only new loans stop. Tokens are unique
// until process death, so a late release cannot free another allocation.
Result pool_acquire(std::uint64_t bytes, std::uint64_t alignment,
                    void** out, std::uint64_t* token) noexcept;
Result pool_release(std::uint64_t token) noexcept;

}  // namespace neostation::donation
