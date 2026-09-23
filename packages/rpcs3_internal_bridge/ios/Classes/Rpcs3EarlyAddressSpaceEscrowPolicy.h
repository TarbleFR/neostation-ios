#pragma once

#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <vector>

namespace neostation::rpcs3::early_escrow {

inline constexpr uint64_t mib = 1024ull * 1024;
inline constexpr uint64_t low = 0x100000000ull;
inline constexpr uint64_t high = 0x1000000000ull;
inline constexpr uint64_t reach = 0x100000000ull;
inline constexpr uint64_t data_bytes = 256 * mib;
inline constexpr std::array<uint64_t, 4> code_capacities = {
    448 * mib, 384 * mib, 320 * mib, 256 * mib};
inline constexpr const char* marker =
    "NEOSTATION_BUILD321_EARLY_JIT_ESCROW_V1";

struct Range {
  uint64_t begin = 0;
  uint64_t end = 0;
};

struct Layout {
  uint64_t code = 0;
  uint64_t data = 0;
  uint64_t code_bytes = 0;
  bool contiguous = false;

  explicit operator bool() const {
    return code != 0 && data != 0 && code_bytes != 0;
  }
};

inline uint64_t align_up(uint64_t value, uint64_t alignment) {
  return (value + alignment - 1) & ~(alignment - 1);
}

inline uint64_t align_down(uint64_t value, uint64_t alignment) {
  return value & ~(alignment - 1);
}

inline bool valid(Layout layout, uint64_t page) {
  if (!page || (page & (page - 1)) || !layout) return false;
  if (layout.code_bytes < code_capacities.back() ||
      layout.code_bytes > code_capacities.front() ||
      layout.code < low || layout.data < low ||
      layout.code > high - layout.code_bytes ||
      layout.data > high - data_bytes ||
      layout.code % page || layout.data % page) {
    return false;
  }
  const uint64_t code_end = layout.code + layout.code_bytes;
  const uint64_t data_end = layout.data + data_bytes;
  if (!(code_end <= layout.data || data_end <= layout.code)) return false;
  return std::max(code_end, data_end) - std::min(layout.code, layout.data) <=
         reach;
}

// Prefer the full proven 448 MiB code capacity plus the Core's 256 MiB
// minimum data capacity. Smaller code capacities are the same adaptive
// fallbacks already used by the embedded Core, not a second runtime mode.
inline std::vector<Layout> candidates(const std::vector<Range>& gaps,
                                      uint64_t page) {
  std::vector<Layout> result;
  if (!page || (page & (page - 1))) return result;

  for (const uint64_t code_bytes : code_capacities) {
    const uint64_t total = code_bytes + data_bytes;
    for (const Range gap : gaps) {
      const uint64_t begin = align_up(std::max(low, gap.begin), page);
      const uint64_t end = std::min(high, gap.end);
      if (begin < end && total <= end - begin) {
        result.push_back({begin, begin + code_bytes, code_bytes, true});
      }
    }

    // A split pair is valid only when both mappings stay within the 4 GiB
    // ADRP reach required by the Core. Place the facing edges as close as
    // possible instead of probing arbitrary addresses inside either gap.
    for (size_t i = 0; i < gaps.size(); ++i) {
      const uint64_t cb = align_up(std::max(low, gaps[i].begin), page);
      const uint64_t ce = std::min(high, gaps[i].end);
      if (cb >= ce || code_bytes > ce - cb) continue;
      for (size_t j = 0; j < gaps.size(); ++j) {
        if (i == j) continue;
        const uint64_t db = align_up(std::max(low, gaps[j].begin), page);
        const uint64_t de = std::min(high, gaps[j].end);
        if (db >= de || data_bytes > de - db) continue;

        uint64_t code = cb;
        uint64_t data = db;
        if (cb < db) {
          code = align_down(ce - code_bytes, page);
        } else {
          data = align_down(de - data_bytes, page);
        }
        Layout candidate{code, data, code_bytes, false};
        if (valid(candidate, page)) result.push_back(candidate);
      }
    }
  }
  return result;
}

struct ReservationResult {
  Layout layout;
  int kernel = 0;
  bool cleanup_ok = true;
  uint64_t attempted_address = 0;
  uint64_t attempted_bytes = 0;
  size_t attempts = 0;
};

// Backend::reserve is an exact, non-overwriting reservation. Failed split
// pairs roll back their first mapping before another candidate is attempted.
template <class Backend>
ReservationResult reserve(const std::vector<Range>& gaps,
                          uint64_t page,
                          Backend& backend) {
  ReservationResult result;
  for (const Layout plan : candidates(gaps, page)) {
    ++result.attempts;
    result.attempted_address = plan.code;
    result.attempted_bytes =
        plan.contiguous ? plan.code_bytes + data_bytes : plan.code_bytes;
    result.kernel =
        backend.reserve(plan.code, result.attempted_bytes);
    if (result.kernel) {
      if (backend.cleanup_failed()) {
        result.cleanup_ok = false;
        return result;
      }
      continue;
    }
    if (plan.contiguous) {
      result.layout = plan;
      return result;
    }

    result.attempted_address = plan.data;
    result.attempted_bytes = data_bytes;
    result.kernel = backend.reserve(plan.data, data_bytes);
    if (!result.kernel) {
      result.layout = plan;
      return result;
    }
    if (backend.cleanup_failed()) {
      result.cleanup_ok = false;
      return result;
    }
    if (backend.release(plan.code, plan.code_bytes)) {
      result.cleanup_ok = false;
      return result;
    }
  }
  return result;
}

template <class Backend>
int release(Layout& layout, Backend& backend) {
  if (layout.contiguous && layout.code) {
    const int error =
        backend.release(layout.code, layout.code_bytes + data_bytes);
    if (!error) layout = {};
    return error;
  }

  int error = 0;
  if (layout.code) {
    error = backend.release(layout.code, layout.code_bytes);
    if (!error) layout.code = 0;
  }
  if (layout.data) {
    const int data_error = backend.release(layout.data, data_bytes);
    if (!data_error) layout.data = 0;
    if (!error) error = data_error;
  }
  if (!layout.code && !layout.data) layout = {};
  return error;
}

}  // namespace neostation::rpcs3::early_escrow
