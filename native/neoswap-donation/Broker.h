#pragma once

#include <cstddef>
#include <cstdint>

// Darwin shared-memory backend. The separate pool and host adapter decide
// routing without changing NeoSwap API v1. Reservations/disk are not donation.
namespace neostation::donation {

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
#if defined(NEOSWAP_TESTING)
// Negative cleanup test; the object still comes from the real Darwin kernel.
void test_fail_next_unmaps(std::uint32_t count) noexcept;
#endif

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
