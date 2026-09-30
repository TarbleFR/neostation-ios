#include "Pool.h"

#include <algorithm>
#include <array>
#include <atomic>
#include <limits>
#include <memory>
#include <mutex>
#include <new>
#if defined(__APPLE__)
#include <mach/mach.h>
#include <unistd.h>
#endif

namespace neostation::donation {
namespace {
constexpr std::size_t max_entries = 64;
constexpr std::size_t max_loans = 256;
constexpr std::uint64_t max_capacity = 8ULL * 1024 * 1024 * 1024;
struct Entry {
  std::unique_ptr<Block> block;
  std::uint64_t generation = 0;
  std::size_t loans = 0;
};
struct Loan {
  std::uint64_t token = 0;
  std::uint64_t bytes = 0;
  std::uint64_t offset = 0;
  std::size_t entry = 0;
};
struct Pool {
  std::mutex mutex;
  std::array<Entry, max_entries> entries;
  std::array<Loan, max_loans> loans{};
  PoolSnapshot stats;
  std::uint64_t capacity = 0;
  std::uint64_t next_token = 1;
  // Advisory display samples are independent relaxed atomic observations.
  // Reading telemetry never waits on a mapping/allocation mutex.
  std::array<std::atomic<std::uint64_t>, 12> published{};
};
static_assert(std::atomic<std::uint64_t>::is_always_lock_free);
Pool& pool() { static Pool instance; return instance; }
void publish(Pool& p) {
  const auto& s = p.stats;
  const std::uint64_t values[] = {s.generation, static_cast<std::uint64_t>(s.donor_pid),
      static_cast<std::uint64_t>(s.state), static_cast<std::uint64_t>(s.last_stage),
      static_cast<std::uint64_t>(s.last_kernel_result), s.prepared_bytes, s.live_bytes,
      s.live_blocks, s.peak_live_bytes, s.donor_footprint, s.donor_nonvolatile,
      s.donor_nonvolatile_compressed};
  for (std::size_t i = 0; i < p.published.size(); ++i)
    p.published[i].store(values[i], std::memory_order_relaxed);
}
Result fail(Pool& p, Stage stage, std::int32_t code = -1) {
  p.stats.last_stage = stage;
  p.stats.last_kernel_result = code;
  publish(p);
  return {stage, code};
}
bool power_of_two(std::uint64_t n) { return n && !(n & (n - 1)); }
void update_footprint(Pool& p, const Footprint& donor) {
  p.stats.donor_footprint = donor.physical;
  p.stats.donor_nonvolatile = donor.nonvolatile;
  p.stats.donor_nonvolatile_compressed = donor.nonvolatile_compressed;
}
}  // namespace

Result pool_begin(std::uint64_t generation, std::int32_t donor_pid,
                  std::uint64_t max_shared_bytes) noexcept {
  if (auto result = availability(); !result) return result;
  auto& p = pool();
  std::lock_guard guard(p.mutex);
  if (!generation || generation <= p.stats.generation || donor_pid <= 0 ||
      !max_shared_bytes || max_shared_bytes > max_capacity)
    return fail(p, Stage::invalid_argument);
#if defined(__APPLE__)
  if (donor_pid == ::getpid()) return fail(p, Stage::invalid_argument);
#endif
  // A first implementation does not restart a donor while pointers from the
  // previous session remain borrowed. Thus prepared/live bytes always refer
  // to this generation, never to an object formerly charged to another task.
  if (p.stats.live_blocks) return fail(p, Stage::pool_unready);
  // Disable new loans before removing any old mapping. A partial cleanup
  // failure must not leave a verified pool offering an already unmapped slot.
  p.stats.state = PoolState::preparing;
  p.stats.donor_footprint = 0;
  p.stats.donor_nonvolatile = 0;
  p.stats.donor_nonvolatile_compressed = 0;
  for (auto& entry : p.entries) if (entry.block && !entry.loans) {
    const auto bytes = entry.block->size();
    const auto result = entry.block->reset();
    p.stats.prepared_bytes -= bytes - entry.block->size();
    if (!result) return fail(p, result.stage, result.kernel_result);
    entry = {};
  }
  p.stats.generation = generation;
  p.stats.donor_pid = donor_pid;
  p.stats.state = PoolState::preparing;
  p.stats.last_stage = Stage::none;
  p.stats.last_kernel_result = 0;
  p.stats.donor_footprint = 0;
  p.stats.donor_nonvolatile = 0;
  p.stats.donor_nonvolatile_compressed = 0;
  p.capacity = max_shared_bytes;
  publish(p);
  return {};
}

Result pool_adopt(std::uint64_t generation, std::uint32_t entry,
                  std::size_t bytes) noexcept {
  auto mapping = std::unique_ptr<Block>(new (std::nothrow) Block);
  if (!mapping) return {Stage::pool_limit, -1};
  if (auto result = Block::map_borrowed(entry, bytes, *mapping); !result) return result;
  auto& p = pool();
  std::lock_guard guard(p.mutex);
  if (generation != p.stats.generation ||
      (p.stats.state != PoolState::preparing && p.stats.state != PoolState::verified))
    return fail(p, Stage::pool_unready);
  if (p.stats.prepared_bytes > p.capacity || bytes > p.capacity - p.stats.prepared_bytes)
    return fail(p, Stage::pool_quota);
  for (auto& slot : p.entries) if (!slot.block) {
    slot.block = std::move(mapping);
    slot.generation = generation;
    slot.loans = 0;
    p.stats.prepared_bytes += bytes;
    publish(p);
    return {};
  }
  return fail(p, Stage::pool_limit);
}

Result pool_verified(std::uint64_t generation, const Footprint& donor) noexcept {
  auto& p = pool();
  std::lock_guard guard(p.mutex);
  if (generation != p.stats.generation || p.stats.state != PoolState::preparing)
    return fail(p, Stage::pool_unready);
  const bool has_entry = std::any_of(p.entries.begin(), p.entries.end(),
      [generation](const Entry& e) { return e.block && e.generation == generation; });
  if (!has_entry) return fail(p, Stage::pool_unready);
  update_footprint(p, donor);
  p.stats.state = PoolState::verified;
  p.stats.last_stage = Stage::none;
  p.stats.last_kernel_result = 0;
  publish(p);
  return {};
}

void pool_footprint(std::uint64_t generation, const Footprint& donor) noexcept {
  auto& p = pool();
  std::lock_guard guard(p.mutex);
  if (generation == p.stats.generation && p.stats.state != PoolState::donor_lost) {
    update_footprint(p, donor);
    publish(p);
  }
}

void pool_lost(std::uint64_t generation, std::int32_t reason) noexcept {
  auto& p = pool();
  std::lock_guard guard(p.mutex);
  if (generation != p.stats.generation) return;
  p.stats.state = PoolState::donor_lost;
  p.stats.last_stage = Stage::pool_unready;
  p.stats.last_kernel_result = reason;
  // These snapshots describe the last measured donor, not its current charge.
  // Zero them on disconnection rather than claiming a dead task still owns RAM.
  p.stats.donor_footprint = 0;
  p.stats.donor_nonvolatile = 0;
  p.stats.donor_nonvolatile_compressed = 0;
  publish(p);
}

void pool_snapshot(PoolSnapshot& out) noexcept {
  auto& p = pool();
  std::uint64_t v[12]{};
  for (std::size_t i = 0; i < p.published.size(); ++i)
    v[i] = p.published[i].load(std::memory_order_relaxed);
  out = {v[0], static_cast<std::int32_t>(v[1]), static_cast<PoolState>(v[2]),
         static_cast<Stage>(v[3]), static_cast<std::int32_t>(v[4]),
         v[5], v[6], v[7], v[8], v[9], v[10], v[11]};
}

Result pool_acquire(std::uint64_t bytes, std::uint64_t alignment,
                    void** out, std::uint64_t* token) noexcept {
  if (!out || !token) return {Stage::invalid_argument, -1};
  *out = nullptr;
  *token = 0;
  auto& p = pool();
  std::lock_guard guard(p.mutex);
  if (p.stats.state != PoolState::verified) return fail(p, Stage::pool_unready);
  if (!bytes || !power_of_two(alignment) || alignment > 65536)
    return fail(p, Stage::invalid_argument);
  if (p.next_token == std::numeric_limits<std::uint64_t>::max())
    return fail(p, Stage::pool_limit);
  Loan* loan = nullptr;
  for (auto& candidate : p.loans) if (!candidate.token) { loan = &candidate; break; }
  if (!loan) return fail(p, Stage::pool_limit);
  for (std::size_t index = 0; index < p.entries.size(); ++index) {
    auto& entry = p.entries[index];
    if (!entry.block || entry.generation != p.stats.generation) continue;
    const auto base = reinterpret_cast<std::uintptr_t>(entry.block->data());
    const std::uint64_t size = entry.block->size();
    std::uint64_t offset = (alignment - (base & (alignment - 1))) & (alignment - 1);
    while (offset <= size && bytes <= size - offset) {
      std::uint64_t next = offset;
      for (const auto& live : p.loans) if (live.token && live.entry == index &&
          offset < live.offset + live.bytes && live.offset < offset + bytes)
        next = std::max(next, live.offset + live.bytes);
      if (next == offset) {
        *loan = {p.next_token++, bytes, offset, index};
        ++entry.loans;
        p.stats.live_bytes += bytes;
        ++p.stats.live_blocks;
        p.stats.peak_live_bytes = std::max(p.stats.peak_live_bytes, p.stats.live_bytes);
        p.stats.last_stage = Stage::none;
        p.stats.last_kernel_result = 0;
        *out = reinterpret_cast<void*>(base + offset);
        *token = loan->token;
        publish(p);
        return {};
      }
      offset = (next + alignment - 1) & ~(alignment - 1);
    }
  }
  return fail(p, Stage::pool_quota);
}

Result pool_release(std::uint64_t token) noexcept {
  auto& p = pool();
  std::lock_guard guard(p.mutex);
  for (auto& loan : p.loans) if (token && loan.token == token) {
    auto& entry = p.entries[loan.entry];
    p.stats.live_bytes -= loan.bytes;
    --p.stats.live_blocks;
    --entry.loans;
    loan = {};
    // Maps remain retained even on donor loss. A generation change is refused
    // until every loan is released; only pool_begin then removes the mappings.
    publish(p);
    return {};
  }
  return fail(p, Stage::pool_not_owned);
}

}  // namespace neostation::donation
