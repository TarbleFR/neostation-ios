#pragma once
// One memory policy shared by host reservation, Core adoption and behavior tests.
#include <algorithm>
#include <cstdint>
#include <vector>

namespace neostation::rpcs3::arena {
inline constexpr uint64_t mib = 1024ull * 1024;
inline constexpr uint64_t code_bytes = 448 * mib;
inline constexpr uint64_t data_bytes = 576 * mib;
inline constexpr uint64_t budget_bytes = 1024 * mib;
inline constexpr uint64_t low = 0x100000000ull;
inline constexpr uint64_t high = 0x1000000000ull;
inline constexpr uint64_t reach = 0x100000000ull;
inline constexpr const char* marker = "NEOSTATION_RPCS3_HOST_RESERVATION_V1";
struct Range { uint64_t begin = 0, end = 0; };
struct Layout {
  uint64_t code = 0, data = 0;
  bool contiguous = false;
  explicit operator bool() const { return code != 0 && data != 0; }
};
inline uint64_t align_up(uint64_t value, uint64_t alignment) {
  return (value + alignment - 1) & ~(alignment - 1);
}
inline bool valid(Layout layout, uint64_t page) {
  if (!page || (page & (page - 1)) || !layout) return false;
  if (layout.code < low || layout.data < low ||
      layout.code > high - code_bytes || layout.data > high - data_bytes ||
      layout.code % page || layout.data % page) return false;
  const uint64_t code_end = layout.code + code_bytes;
  const uint64_t data_end = layout.data + data_bytes;
  if (!(code_end <= layout.data || data_end <= layout.code)) return false;
  return std::max(code_end, data_end) - std::min(layout.code, layout.data) <= reach;
}
// Enumerate *real* VM gaps. No 64 MiB stepping that skips small but adequate
// holes, no MAP_FIXED overwrite of unowned memory, no change of capacity.
inline std::vector<Layout> candidates(const std::vector<Range>& gaps, uint64_t page) {
  std::vector<Layout> result;
  if (!page || (page & (page - 1))) return result;
  for (auto gap : gaps) {
    const uint64_t begin = align_up(std::max(low, gap.begin), page);
    const uint64_t end = std::min(high, gap.end);
    if (begin < end && budget_bytes <= end - begin)
      result.push_back({begin, begin + code_bytes, true});
  }
  // Split layout is the same fixed 1 GiB policy, not a second JIT mode. Only
  // differing gaps are considered; a common gap was handled above.
  for (size_t i = 0; i < gaps.size(); ++i) {
    const uint64_t cb = align_up(std::max(low, gaps[i].begin), page);
    const uint64_t ce = std::min(high, gaps[i].end);
    if (cb >= ce || code_bytes > ce - cb) continue;
    for (size_t j = 0; j < gaps.size(); ++j) {
      if (i == j) continue;
      const uint64_t db = align_up(std::max(low, gaps[j].begin), page);
      const uint64_t de = std::min(high, gaps[j].end);
      if (db >= de || data_bytes > de - db) continue;
      // Place the lower range at its upper edge when needed for ADRP reach.
      uint64_t c = cb, d = db;
      if (cb < db) c = (ce - code_bytes) & ~(page - 1);
      else d = (de - data_bytes) & ~(page - 1);
      Layout candidate{c, d, false};
      if (valid(candidate, page)) result.push_back(candidate);
    }
  }
  return result;
}
struct ReservationResult {
  Layout layout;
  int kernel = 0;
  bool cleanup_ok = true;
  uint64_t attempted_address = 0, attempted_bytes = 0;
  size_t attempts = 0;
};
// Backend::reserve must reserve exactly without overwriting. Both reserve and
// release return the actual kernel status (0 is success). Test backends inject
// map races, protection failures, and rollback failures into this production code.
template<class Backend>
ReservationResult reserve(const std::vector<Range>& gaps, uint64_t page, Backend& backend) {
  ReservationResult result;
  for (Layout plan : candidates(gaps, page)) {
    ++result.attempts;
    result.attempted_address = plan.code;
    result.attempted_bytes = plan.contiguous ? budget_bytes : code_bytes;
    result.kernel = backend.reserve(plan.code, result.attempted_bytes);
    if (result.kernel) {
      if (backend.cleanup_failed()) { result.cleanup_ok = false; return result; }
      continue;
    }
    if (plan.contiguous) { result.layout = plan; return result; }
    result.attempted_address = plan.data;
    result.attempted_bytes = data_bytes;
    result.kernel = backend.reserve(plan.data, data_bytes);
    if (!result.kernel) { result.layout = plan; return result; }
    if (backend.cleanup_failed()) { result.cleanup_ok = false; return result; }
    const int released = backend.release(plan.code, code_bytes);
    if (released) { result.cleanup_ok = false; return result; }
  }
  return result;
}
template<class Backend>
int release(Layout& layout, Backend& backend) {
  if (layout.contiguous && layout.code) {
    const int error = backend.release(layout.code, budget_bytes);
    if (!error) layout = {};
    return error;
  }
  int error = 0;
  if (layout.code) {
    error = backend.release(layout.code, code_bytes);
    if (!error) layout.code = 0;
  }
  if (layout.data) {
    const int data_error = backend.release(layout.data, data_bytes);
    if (!data_error) layout.data = 0;
    if (!error) error = data_error;
  }
  return error;
}
static_assert(code_bytes + data_bytes == budget_bytes);
} // namespace neostation::rpcs3::arena
