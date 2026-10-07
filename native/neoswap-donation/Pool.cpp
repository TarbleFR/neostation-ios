#include "Pool.h"

#include <algorithm>
#include <array>
#include <atomic>
#include <limits>
#include <memory>
#include <mutex>
#include <new>
#if defined(__APPLE__)
#include <unistd.h>
#endif

namespace neostation::donation {
namespace {
constexpr std::size_t max_donors = 8;
constexpr std::size_t max_entries = 512;
// 256 legacy large allocations plus 768 bounded CPU sub-MiB allocations.
// The host keeps the slot classes separate so small data cannot starve large buffers.
constexpr std::size_t max_loans = 1024;
constexpr std::uint64_t max_capacity = 8ULL * 1024 * 1024 * 1024;
struct Entry {
  std::unique_ptr<Block> block;
  std::uint64_t generation = 0, chunk = 0;
  std::size_t donor = 0, loans = 0;
  std::size_t first_loan = max_loans;
  bool verified = false;
};
struct Loan {
  std::uint64_t token = 0, bytes = 0, offset = 0;
  std::size_t entry = 0;
  std::size_t previous = max_loans, next = max_loans;
};
struct Donor {
  PoolDonorSnapshot stats;
  std::uint64_t next_chunk = 0;
};
struct Pool {
  std::mutex mutex;
  std::array<Entry, max_entries> entries;
  std::array<Loan, max_loans> loans{};
  std::array<Donor, max_donors> donors;
  PoolSnapshot stats;
  std::uint64_t next_token = 1;
  std::atomic<std::uint64_t> publication_sequence{0};
  std::array<std::atomic<std::uint64_t>, 20> published{};
  std::array<std::array<std::atomic<std::uint64_t>, 14>, max_donors> donor_published{};
};
static_assert(std::atomic<std::uint64_t>::is_always_lock_free);
Pool& pool() { static Pool instance; return instance; }
bool power_of_two(std::uint64_t n) { return n && !(n & (n - 1)); }

void publish(Pool& p) {
  p.publication_sequence.fetch_add(1, std::memory_order_acq_rel);
  std::atomic_thread_fence(std::memory_order_release);
  auto& s = p.stats;
  s.prepared_bytes = s.retained_bytes = s.retained_live_bytes = 0;
  s.donor_footprint = s.donor_nonvolatile = s.donor_nonvolatile_compressed = 0;
  s.resident_bytes = s.compressed_bytes = s.verified_chunks = 0;
  s.donor_count = s.lost_donor_count = 0;
  s.donor_pid = 0;
  bool preparing = false;
  for (auto& d : p.donors) {
    d.stats.prepared_bytes = d.stats.retained_bytes = d.stats.live_bytes = 0;
    d.stats.verified_chunks = 0;
  }
  for (const auto& e : p.entries) if (e.block) {
    const auto bytes = e.block->size();
    auto& d = p.donors[e.donor].stats;
    d.retained_bytes += bytes;
    s.retained_bytes += bytes;
    if (e.verified && d.state == PoolState::verified && e.generation == d.generation) {
      d.prepared_bytes += bytes;
      ++d.verified_chunks;
      s.prepared_bytes += bytes;
      ++s.verified_chunks;
    }
  }
  for (const auto& loan : p.loans) if (loan.token) {
    const auto& e = p.entries[loan.entry];
    auto& d = p.donors[e.donor].stats;
    d.live_bytes += loan.bytes;
    if (d.state != PoolState::verified || d.generation != e.generation)
      s.retained_live_bytes += loan.bytes;
  }
  for (std::size_t index = 0; index < p.donors.size(); ++index) {
    const auto& d = p.donors[index].stats;
    if (d.state == PoolState::verified) {
      ++s.donor_count;
      s.donor_pid = s.donor_count == 1 ? d.pid : 0;
      s.donor_footprint += d.footprint_bytes;
      s.donor_nonvolatile += d.nonvolatile_bytes;
      s.donor_nonvolatile_compressed += d.nonvolatile_compressed_bytes;
      s.resident_bytes += d.resident_bytes;
      s.compressed_bytes += d.compressed_bytes;
    } else if (d.state == PoolState::donor_lost) ++s.lost_donor_count;
    else if (d.state == PoolState::preparing) preparing = true;
    const std::uint64_t values[] = {d.generation, static_cast<std::uint64_t>(d.pid),
        static_cast<std::uint64_t>(d.state), d.prepared_bytes, d.retained_bytes, d.live_bytes,
        d.resident_bytes, d.compressed_bytes, d.footprint_bytes, d.nonvolatile_bytes,
        d.nonvolatile_compressed_bytes, d.verified_chunks,
        static_cast<std::uint64_t>(d.last_stage), static_cast<std::uint64_t>(d.last_kernel_result)};
    for (std::size_t i = 0; i < p.donor_published[index].size(); ++i)
      p.donor_published[index][i].store(values[i], std::memory_order_relaxed);
  }
  s.state = s.donor_count ? PoolState::verified : preparing ? PoolState::preparing :
      s.lost_donor_count ? PoolState::donor_lost : PoolState::unavailable;
  const std::uint64_t values[] = {s.generation, static_cast<std::uint64_t>(s.donor_pid),
      static_cast<std::uint64_t>(s.state), static_cast<std::uint64_t>(s.last_stage),
      static_cast<std::uint64_t>(s.last_kernel_result), s.prepared_bytes, s.live_bytes,
      s.live_blocks, s.peak_live_bytes, s.donor_footprint, s.donor_nonvolatile,
      s.donor_nonvolatile_compressed, s.target_bytes, s.retained_bytes,
      s.retained_live_bytes, s.resident_bytes, s.compressed_bytes, s.verified_chunks,
      s.donor_count, s.lost_donor_count};
  for (std::size_t i = 0; i < p.published.size(); ++i)
    p.published[i].store(values[i], std::memory_order_relaxed);
  p.publication_sequence.fetch_add(1, std::memory_order_release);
}

template <std::size_t Size>
bool read_published(Pool& p, const std::array<std::atomic<std::uint64_t>, Size>& source,
                    std::uint64_t (&values)[Size]) noexcept {
  // A heartbeat can move a page charge between resident and compressed
  // ledgers. Never combine different publications into a fictitious larger
  // charge. The UI path stays bounded and reports unavailable while busy.
  for (unsigned attempt = 0; attempt < 16; ++attempt) {
    const auto before = p.publication_sequence.load(std::memory_order_acquire);
    if (before & 1) continue;
    for (std::size_t i = 0; i < Size; ++i)
      values[i] = source[i].load(std::memory_order_relaxed);
    std::atomic_thread_fence(std::memory_order_acquire);
    if (before == p.publication_sequence.load(std::memory_order_acquire)) return true;
  }
  return false;
}
Result fail(Pool& p, Stage stage, std::int32_t code = -1) {
  p.stats.last_stage = stage;
  p.stats.last_kernel_result = code;
  publish(p);
  return {stage, code};
}
void lost(Donor& d, std::int32_t reason) {
  d.stats.state = PoolState::donor_lost;
  d.stats.last_stage = Stage::pool_unready;
  d.stats.last_kernel_result = reason;
  d.stats.resident_bytes = d.stats.compressed_bytes = d.stats.footprint_bytes = 0;
  d.stats.nonvolatile_bytes = d.stats.nonvolatile_compressed_bytes = 0;
}
bool matches(const Pool& p, std::uint64_t epoch, std::uint32_t index,
             std::uint64_t generation) {
  return epoch == p.stats.generation && index < max_donors && generation &&
      generation == p.donors[index].stats.generation;
}
}  // namespace

Result pool_campaign_begin(std::uint64_t epoch, std::uint64_t target) noexcept {
  if (auto result = availability(); !result) return result;
  auto& p = pool();
  std::lock_guard guard(p.mutex);
  if (!epoch || epoch <= p.stats.generation || !target || target > max_capacity)
    return fail(p, Stage::invalid_argument);
  if (p.stats.live_blocks) return fail(p, Stage::pool_unready);
  // Disable all old sources before removing even one old mapping. No new
  // campaign can attribute old retained objects to its new donor processes.
  for (auto& d : p.donors) if (d.stats.state != PoolState::unavailable) lost(d, 0);
  for (auto& entry : p.entries) if (entry.block) {
    if (auto result = entry.block->reset(); !result)
      return fail(p, result.stage, result.kernel_result);
    entry = {};
  }
  p.donors = {};
  p.stats.generation = epoch;
  p.stats.target_bytes = target;
  p.stats.last_stage = Stage::none;
  p.stats.last_kernel_result = 0;
  publish(p);
  return {};
}

Result pool_campaign_end(std::uint64_t epoch) noexcept {
  auto& p = pool();
  std::lock_guard guard(p.mutex);
  if (!epoch || epoch != p.stats.generation)
    return fail(p, Stage::invalid_argument);
  if (p.stats.live_blocks)
    return fail(p, Stage::pool_unready);
  for (auto& entry : p.entries) if (entry.block) {
    if (auto result = entry.block->reset(); !result)
      return fail(p, result.stage, result.kernel_result);
    entry = {};
  }
  p.donors = {};
  p.stats.target_bytes = 0;
  p.stats.last_stage = Stage::none;
  p.stats.last_kernel_result = 0;
  publish(p);
  return {};
}

Result pool_donor_begin(std::uint64_t epoch, std::uint32_t index,
    std::uint64_t generation, std::int32_t pid) noexcept {
  auto& p = pool();
  std::lock_guard guard(p.mutex);
  if (epoch != p.stats.generation || index >= max_donors || !generation || pid <= 0)
    return fail(p, Stage::invalid_argument);
#if defined(__APPLE__)
  if (pid == ::getpid()) return fail(p, Stage::invalid_argument);
#endif
  auto& d = p.donors[index];
  if ((d.stats.state != PoolState::unavailable && d.stats.state != PoolState::donor_lost) ||
      d.stats.retained_bytes || d.stats.live_bytes)
    return fail(p, Stage::pool_unready);
  if (d.stats.generation && generation <= d.stats.generation)
    return fail(p, Stage::invalid_argument);
  for (const auto& entry : p.entries) if (entry.block && entry.donor == index)
    return fail(p, Stage::pool_unready); // even a retained send right with no mapping
  for (const auto& other : p.donors) if (other.stats.pid == pid &&
      (other.stats.state == PoolState::preparing || other.stats.state == PoolState::verified))
    return fail(p, Stage::pool_duplicate_pid);
  d = {};
  d.stats.generation = generation;
  d.stats.pid = pid;
  d.stats.state = PoolState::preparing;
  publish(p);
  return {};
}

Result pool_adopt_donor(std::uint64_t epoch, std::uint32_t index,
    std::uint64_t generation, std::uint64_t chunk, std::uint32_t entry,
    std::size_t bytes) noexcept {
  auto mapping = std::unique_ptr<Block>(new (std::nothrow) Block);
  if (!mapping) return {Stage::pool_limit, -1};
  if (auto result = Block::map_borrowed(entry, bytes, *mapping); !result) return result;
  auto& p = pool();
  std::lock_guard guard(p.mutex);
  if (!matches(p, epoch, index, generation)) return fail(p, Stage::pool_unready);
  auto& d = p.donors[index];
  if ((d.stats.state != PoolState::preparing && d.stats.state != PoolState::verified) ||
      chunk != d.next_chunk || chunk >= 64) return fail(p, Stage::pool_unready);
  if (p.stats.retained_bytes > p.stats.target_bytes ||
      bytes > p.stats.target_bytes - p.stats.retained_bytes)
    return fail(p, Stage::pool_quota);
  // Replaying the same named object must not create fictitious additional
  // capacity. IPC additionally ties each new proof and ledger delta to index.
  for (const auto& old : p.entries) if (old.block && old.block->entry() == entry)
    return fail(p, Stage::invalid_argument);
  for (auto& slot : p.entries) if (!slot.block) {
    slot.block = std::move(mapping);
    slot.generation = generation;
    slot.chunk = chunk;
    slot.donor = index;
    slot.verified = false;
    ++d.next_chunk;
    publish(p);
    return {};
  }
  return fail(p, Stage::pool_limit);
}

Result pool_verify_donor(std::uint64_t epoch, std::uint32_t index,
    std::uint64_t generation, std::uint64_t capacity, const Footprint& donor,
    std::uint64_t resident, std::uint64_t compressed) noexcept {
  auto& p = pool();
  std::lock_guard guard(p.mutex);
  if (!matches(p, epoch, index, generation)) return fail(p, Stage::pool_unready);
  auto& d = p.donors[index];
  if (d.stats.state != PoolState::preparing && d.stats.state != PoolState::verified)
    return fail(p, Stage::pool_unready);
  std::uint64_t mapped = 0;
  for (const auto& e : p.entries) if (e.block && e.donor == index && e.generation == generation)
    mapped += e.block->size();
  const auto tolerance = std::min<std::uint64_t>(1024 * 1024, capacity / 16);
  if (!capacity || capacity != mapped || compressed > capacity || resident > capacity - compressed ||
      resident + compressed < capacity - tolerance || donor.nonvolatile < resident ||
      donor.nonvolatile_compressed < compressed || donor.physical < resident + compressed) {
    lost(d, -1);
    return fail(p, Stage::footprint);
  }
  d.stats.state = PoolState::verified;
  d.stats.resident_bytes = resident;
  d.stats.compressed_bytes = compressed;
  d.stats.footprint_bytes = donor.physical;
  d.stats.nonvolatile_bytes = donor.nonvolatile;
  d.stats.nonvolatile_compressed_bytes = donor.nonvolatile_compressed;
  d.stats.last_stage = Stage::none;
  d.stats.last_kernel_result = 0;
  for (auto& e : p.entries) if (e.block && e.donor == index && e.generation == generation)
    e.verified = true;
  p.stats.last_stage = Stage::none;
  p.stats.last_kernel_result = 0;
  publish(p);
  return {};
}

void pool_donor_lost(std::uint64_t epoch, std::uint32_t index,
    std::uint64_t generation, std::int32_t reason) noexcept {
  auto& p = pool();
  std::lock_guard guard(p.mutex);
  if (!matches(p, epoch, index, generation)) return;
  lost(p.donors[index], reason);
  // Retain all live mappings; an unrelated verified donor continues offering
  // loans. Unused lost mappings are removed only when the campaign is retired.
  publish(p);
}

Result pool_collect_lost() noexcept {
  auto& p = pool();
  std::lock_guard guard(p.mutex);
  Result first{};
  for (auto& e : p.entries) if (e.block && !e.loans &&
      p.donors[e.donor].stats.state == PoolState::donor_lost) {
    const auto result = e.block->reset();
    if (result) e = {};
    else if (first) first = result;
  }
  if (!first) return fail(p, first.stage, first.kernel_result);
  publish(p);
  return {};
}

bool pool_donor_restartable(std::uint64_t epoch, std::uint32_t index) noexcept {
  auto& p = pool();
  std::lock_guard guard(p.mutex);
  if (epoch != p.stats.generation || index >= max_donors) return false;
  const auto& d = p.donors[index].stats;
  if ((d.state != PoolState::unavailable && d.state != PoolState::donor_lost) || d.live_bytes)
    return false;
  for (const auto& entry : p.entries) if (entry.block && entry.donor == index) return false;
  return true;
}

void pool_snapshot(PoolSnapshot& out) noexcept {
  auto& p = pool();
  std::uint64_t v[20]{};
  if (!read_published(p, p.published, v)) {
    out = {}; out.last_stage = Stage::snapshot_busy; return;
  }
  out = {v[0], static_cast<std::int32_t>(v[1]), static_cast<PoolState>(v[2]),
      static_cast<Stage>(v[3]), static_cast<std::int32_t>(v[4]),
      v[5], v[6], v[7], v[8], v[9], v[10], v[11], v[12], v[13], v[14],
      v[15], v[16], v[17], static_cast<std::uint32_t>(v[18]), static_cast<std::uint32_t>(v[19])};
}
void pool_donor_snapshot(std::uint32_t index, PoolDonorSnapshot& out) noexcept {
  out = {};
  if (index >= max_donors) return;
  auto& p = pool();
  std::uint64_t v[14]{};
  if (!read_published(p, p.donor_published[index], v)) {
    out.last_stage = Stage::snapshot_busy; return;
  }
  out = {v[0], static_cast<std::int32_t>(v[1]), static_cast<PoolState>(v[2]),
      v[3], v[4], v[5], v[6], v[7], v[8], v[9], v[10], v[11],
      static_cast<Stage>(v[12]), static_cast<std::int32_t>(v[13])};
}

Result pool_acquire(std::uint64_t bytes, std::uint64_t alignment,
    void** out, std::uint64_t* token) noexcept {
  if (!out || !token) return {Stage::invalid_argument, -1};
  *out = nullptr; *token = 0;
  auto& p = pool();
  std::unique_lock guard(p.mutex, std::try_to_lock);
  // Cleanup can hold this mutex across OS calls. Never queue an
  // emulator acquisition behind that work, and do not mutate stats unlocked.
  if (!guard.owns_lock()) return {Stage::pool_busy, 0};
  if (p.stats.state != PoolState::verified) return fail(p, Stage::pool_unready);
  if (!bytes || !power_of_two(alignment) || alignment > 65536)
    return fail(p, Stage::invalid_argument);
  if (p.next_token == std::numeric_limits<std::uint64_t>::max())
    return fail(p, Stage::pool_limit);
  std::size_t slot = max_loans;
  for (std::size_t i = 0; i < p.loans.size(); ++i)
    if (!p.loans[i].token) { slot = i; break; }
  if (slot == max_loans) return fail(p, Stage::pool_limit);
  for (std::size_t index = 0; index < p.entries.size(); ++index) {
    auto& e = p.entries[index];
    const auto& donor = p.donors[e.donor].stats;
    if (!e.block || !e.verified || donor.state != PoolState::verified ||
        e.generation != donor.generation) continue;
    const auto base = reinterpret_cast<std::uintptr_t>(e.block->data());
    const std::uint64_t size = e.block->size();
    auto align_offset = [base, alignment](std::uint64_t offset) {
      return offset + ((alignment - ((base + offset) & (alignment - 1))) & (alignment - 1));
    };
    std::uint64_t offset = align_offset(0);
    std::size_t previous = max_loans, next = e.first_loan;
    // Fixed-slot intrusive list, sorted by offset within this entry. Search
    // each live interval once instead of rescanning all loans for every gap.
    // No allocation, IPC or page writes are introduced on this hot path.
    while (next != max_loans) {
      const auto& live = p.loans[next];
      if (offset <= live.offset && bytes <= live.offset - offset) break;
      offset = align_offset(live.offset + live.bytes);
      previous = next;
      next = live.next;
    }
    if (offset > size || bytes > size - offset) continue;
    auto& loan = p.loans[slot];
    loan = {p.next_token++, bytes, offset, index, previous, next};
    if (previous == max_loans) e.first_loan = slot;
    else p.loans[previous].next = slot;
    if (next != max_loans) p.loans[next].previous = slot;
    ++e.loans;
    p.stats.live_bytes += bytes; ++p.stats.live_blocks;
    p.stats.peak_live_bytes = std::max(p.stats.peak_live_bytes, p.stats.live_bytes);
    p.stats.last_stage = Stage::none; p.stats.last_kernel_result = 0;
    *out = reinterpret_cast<void*>(base + offset); *token = loan.token;
    publish(p);
    return {};
  }
  return fail(p, Stage::pool_quota);
}

Result pool_release(std::uint64_t token) noexcept {
  auto& p = pool();
  std::lock_guard guard(p.mutex);
  for (auto& loan : p.loans) if (token && loan.token == token) {
    auto& entry = p.entries[loan.entry];
    if (loan.previous == max_loans) entry.first_loan = loan.next;
    else p.loans[loan.previous].next = loan.next;
    if (loan.next != max_loans) p.loans[loan.next].previous = loan.previous;
    --entry.loans;
    p.stats.live_bytes -= loan.bytes; --p.stats.live_blocks;
    loan = {};
    publish(p);
    return {};
  }
  return fail(p, Stage::pool_not_owned);
}

Result pool_begin(std::uint64_t generation, std::int32_t pid, std::uint64_t target) noexcept {
  if (auto result = pool_campaign_begin(generation, target); !result) return result;
  return pool_donor_begin(generation, 0, generation, pid);
}
Result pool_adopt(std::uint64_t generation, std::uint32_t entry, std::size_t bytes) noexcept {
  std::uint64_t next = 0;
  { auto& p = pool(); std::lock_guard guard(p.mutex); next = p.donors[0].next_chunk; }
  return pool_adopt_donor(generation, 0, generation, next, entry, bytes);
}
Result pool_verified(std::uint64_t generation, const Footprint& donor) noexcept {
  PoolDonorSnapshot stats{}; pool_donor_snapshot(0, stats);
  if (stats.last_stage == Stage::snapshot_busy) return {Stage::snapshot_busy, 0};
  return pool_verify_donor(generation, 0, generation, stats.retained_bytes, donor,
      donor.nonvolatile, donor.nonvolatile_compressed);
}
void pool_footprint(std::uint64_t generation, const Footprint& donor) noexcept {
  PoolDonorSnapshot stats{}; pool_donor_snapshot(0, stats);
  if (stats.last_stage == Stage::snapshot_busy) return;
  (void)pool_verify_donor(generation, 0, generation, stats.prepared_bytes, donor,
      donor.nonvolatile, donor.nonvolatile_compressed);
}
void pool_lost(std::uint64_t generation, std::int32_t reason) noexcept {
  pool_donor_lost(generation, 0, generation, reason);
}
}  // namespace neostation::donation
