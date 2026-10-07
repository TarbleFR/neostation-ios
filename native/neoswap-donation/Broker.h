#pragma once

#include <cstddef>
#include <cstdint>

// Darwin shared-memory backend. The separate pool and host adapter decide
// routing without changing NeoSwap API v1. Reservations/disk are not donation.
namespace neostation::donation {

// One shared native limit: larger aggregate pools use multiple verified blocks.
inline constexpr std::uint64_t max_chunk_bytes = 256ULL * 1024 * 1024;
constexpr bool valid_chunk_size(std::uint64_t bytes, std::uint64_t page) noexcept {
  return page && bytes && bytes <= max_chunk_bytes && bytes % page == 0;
}
constexpr std::uint64_t pending_headroom_budget(std::uint64_t available,
    std::uint64_t remaining, std::uint64_t pending, std::uint64_t page) noexcept {
  const auto bound = available < remaining ? available : remaining;
  if (!page || bound <= pending) return 0;
  const auto budget = bound - pending;
  return budget - budget % page;
}


// Pure policy: a larger hard ceiling is capacity, not a preallocation request.
constexpr std::uint64_t adaptive_donation_target(std::uint64_t live,
    std::uint64_t floor, std::uint64_t reserve, std::uint64_t quantum,
    std::uint64_t limit) noexcept {
  if (!limit || !quantum) return 0;
  if (live >= limit) return limit;
  const auto room = limit - live;
  auto desired = live + (reserve < room ? reserve : room);
  if (desired < floor) desired = floor < limit ? floor : limit;
  const auto remainder = desired % quantum;
  if (remainder) {
    const auto rounding = quantum - remainder;
    desired = rounding > limit - desired ? limit : desired + rounding;
  }
  return desired;
}

enum class Stage : std::uint32_t {
  none,
  unavailable,
  invalid_argument,
  create_entry,
  retain_entry,
  map_entry,
  query_nonvolatile,
  wrong_purgeable_state,
  unmap,
  release_entry,
  footprint,
  footprint_revision,
  pool_unready,
  pool_quota,
  pool_limit,
  pool_not_owned,
  cleanup_limit,
  system_headroom,
  memory_pressure,
  pool_duplicate_pid,
  snapshot_busy,
  pool_busy,
};

struct Result {
  Stage stage = Stage::none;
  std::int32_t kernel_result = 0;
  const char* missing_symbol = nullptr;
  explicit operator bool() const noexcept { return stage == Stage::none; }
};

struct Footprint {
  std::uint64_t physical = 0;
  std::uint64_t resident = 0;
  std::uint64_t internal = 0;
  std::uint64_t nonvolatile = 0;
  std::uint64_t nonvolatile_compressed = 0;
};

// Each process reports its own ledgers. A mapped byte count is never substituted
// for any of these measurements, and an unsupported revision is an error.
Result availability() noexcept;
Result footprint(Footprint& out) noexcept;
const char* stage_name(Stage stage) noexcept;

struct CleanupSnapshot {
  std::uint64_t pending_blocks = 0;
  std::uint64_t pending_mappings = 0;
  std::uint64_t pending_rights = 0;
  Stage last_stage = Stage::none;
  std::int32_t last_kernel_result = 0;
};
// Destruction never discards a failed unmap/send-right release. Each Block
// reserves one cleanup descriptor before acquiring kernel resources. Failed
// destruction moves those resources to that descriptor for explicit retry.
Result retry_cleanup() noexcept;
void cleanup_snapshot(CleanupSnapshot& out) noexcept;

enum class MemoryPressure : std::uint32_t { unobserved, normal, warning, critical };
struct SystemHeadroom {
  std::uint64_t free_bytes = 0;
  std::uint64_t purgeable_bytes = 0;
  std::uint64_t reclaimable_bytes = 0;
  std::uint64_t usable_bytes = 0;
  std::uint64_t kernel_available_bytes = 0;
  std::uint32_t kernel_available_percent = 0;
  bool kernel_estimate_valid = false;
  MemoryPressure pressure = MemoryPressure::unobserved;
};
// A kernel sample, not os_proc_available_memory (which is a process limit).
// The optional memorystatus level estimates allocation headroom, including OS
// reclamation; it is never a measurement of donated/resident physical pages.
// free_count includes speculative pages. Keep 512 MiB and one percentage point.
void derive_system_budget(SystemHeadroom& out, std::uint64_t physical_bytes,
                          std::uint32_t kernel_percent, bool valid) noexcept;
Result system_headroom(SystemHeadroom& out) noexcept;
// A macOS-hosted probe/Simulator has no required iOS jetsam limit. Its zero
// process reading is not a zero system budget. Device zero remains a refusal.
// UINT64_MAX means no process bound, never measured or donated capacity; the
// caller must still intersect this bound with freshly measured system headroom.
constexpr std::uint64_t process_headroom_budget(std::uint64_t measured,
    bool required, std::uint64_t margin) noexcept {
  return !required ? UINT64_MAX : measured > margin ? measured - margin : 0;
}
#if defined(NEOSWAP_TESTING)
// Negative cleanup test; the object still comes from the real Darwin kernel.
void test_fail_next_unmaps(std::uint32_t count) noexcept;
void test_fail_next_right_releases(std::uint32_t count) noexcept;
#endif

// Reserve retry ownership before copying a task-local send right. This holder
// adopts exactly one existing user reference and quarantines failed releases.
class SendRight final {
 public:
  SendRight() noexcept = default;
  ~SendRight();
  SendRight(const SendRight&) = delete;
  SendRight& operator=(const SendRight&) = delete;
  Result prepare() noexcept;
  Result adopt(std::uint32_t entry) noexcept;
  Result reset() noexcept;
 private:
  std::uint32_t entry_ = 0;
  std::uint32_t cleanup_slot_ = UINT32_MAX;
};

class Block final {
 public:
  Block() noexcept = default;
  ~Block();
  Block(const Block&) = delete;
  Block& operator=(const Block&) = delete;

  // Called inside the donor task. MAP_MEM_PURGABLE starts NONVOLATILE in XNU;
  // this experiment never marks a block volatile or asks for NO_FOOTPRINT.
  static Result create_owned(std::size_t bytes, Block& out) noexcept;
  // The receiver holds a send right and maps the same VM object with copy=false.
  // It never calls mach_memory_entry_ownership to claim the donor's object.
  static Result map_borrowed(std::uint32_t entry, std::size_t bytes,
                             Block& out) noexcept;

  Result reset() noexcept;
  void* data() const noexcept { return reinterpret_cast<void*>(address_); }
  std::size_t size() const noexcept { return bytes_; }
  std::uint32_t entry() const noexcept { return entry_; }

 private:
  static Result map_retained(std::uint32_t entry, std::size_t bytes,
                             Block& out) noexcept;
  std::uint64_t address_ = 0;
  std::size_t bytes_ = 0;
  std::uint32_t entry_ = 0;
  std::uint32_t cleanup_slot_ = UINT32_MAX;
};

}  // namespace neostation::donation
