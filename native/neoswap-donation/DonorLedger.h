#pragma once

#include "Broker.h"
#include <limits>

namespace neostation::donation {

struct DonorLedgerDelta {
  std::uint64_t resident = 0;
  std::uint64_t compressed = 0;
  bool valid = false;
};

// The nonvolatile ledgers are process-wide page counts. Baseline pages can
// move between resident and compressed while the verified objects stay alive.
// Cancel a negative category delta against the other category before bounding
// the cumulative increase; clamping both independently would invent pages.
// This remains a bounded process-ledger delta, not per-object attribution.
constexpr DonorLedgerDelta measured_ledger_delta(const Footprint& current,
    const Footprint& baseline, std::uint64_t capacity) noexcept {
  constexpr auto maximum = std::numeric_limits<std::uint64_t>::max();
  if (current.nonvolatile > maximum - current.nonvolatile_compressed ||
      baseline.nonvolatile > maximum - baseline.nonvolatile_compressed)
    return {};

  const bool residentIncreased = current.nonvolatile >= baseline.nonvolatile;
  const bool compressedIncreased =
      current.nonvolatile_compressed >= baseline.nonvolatile_compressed;
  std::uint64_t resident = residentIncreased
      ? current.nonvolatile - baseline.nonvolatile : 0;
  std::uint64_t compressed = compressedIncreased
      ? current.nonvolatile_compressed - baseline.nonvolatile_compressed : 0;
  if (!residentIncreased) {
    const auto decrease = baseline.nonvolatile - current.nonvolatile;
    compressed = compressed > decrease ? compressed - decrease : 0;
  }
  if (!compressedIncreased) {
    const auto decrease = baseline.nonvolatile_compressed - current.nonvolatile_compressed;
    resident = resident > decrease ? resident - decrease : 0;
  }
  const bool valid = resident <= capacity && compressed <= capacity &&
                     resident <= capacity - compressed;
  return {resident, compressed, valid};
}

} // namespace neostation::donation
