// SPDX-License-Identifier: MIT
// Adapted from Guest Page Relay; see LICENSE in this directory.
#pragma once
#if __has_include("../NeoSwapRelay.h")
#include "../NeoSwapRelay.h"
#else
#include "../../packages/neo_swap/ios/Classes/NeoSwapRelay.h"
#endif
#include <cstdint>
#include <memory>

namespace neostation::relay {
constexpr std::uint64_t maximum_capacity = 8ULL * 1024 * 1024 * 1024;
constexpr std::uint64_t maximum_segment_bytes = 512ULL * 1024 * 1024;
constexpr std::uint32_t initial_owner_mask = 1U; // NeoSwap RPCS3 owner 0 only.
// Relay owner 1 backs RPCS3 HOST data loans (RSX CPU buffers, host-visible
// Vulkan buffers, video frames) served by the host broker. It shares the same
// retained named objects as guest data but is bounded by its own quota so
// guest allocations keep their reserved share of the capacity.
constexpr std::uint32_t host_loan_owner = 1U;
constexpr std::uint32_t supported_owner_mask = initial_owner_mask | (1U << host_loan_owner);
constexpr std::uint32_t tracked_owner_count = 2;

// Operations return zero on success, otherwise their original OS error.
// map and unmap MUST be atomic on failure. fixed unmap must OVERWRITE with a
// PROT_NONE reservation, never deallocate followed by a separate reservation.
// The injectable contract lets tests exercise rollback without pretending to
// prove Darwin residency, jetsam behavior, or real iPhone memory availability.
struct Operations {
    int (*retain)(void*, std::uint32_t);
    int (*drop)(void*, std::uint32_t);
    int (*map)(void*, std::uint32_t entry, std::uint64_t offset,
               std::uint64_t bytes, std::uintptr_t target, std::uint32_t protection,
               std::uintptr_t* mapped);
    int (*unmap)(void*, std::uintptr_t, std::uint64_t bytes, bool fixed);
    int (*zero)(void*, std::uintptr_t, std::uint64_t bytes);
    std::uint64_t (*headroom)(void*);
};

// Host diagnostics only: never copied into the pinned NeoSwapRelayStats ABI.
struct PressureDiagnostics {
    std::uint64_t transitions = 0, existing_alias_maps = 0;
    std::uint64_t create_refusals = 0, first_map_refusals = 0, map_failures = 0;
    int last_map_result = 0, last_map_os_error = 0;
    // Per-owner live backing and quotas (owner 0 guest data, owner 1 host loans).
    std::uint64_t owner_live_bytes[tracked_owner_count] = {};
    std::uint64_t owner_peak_bytes[tracked_owner_count] = {};
    std::uint64_t owner_quota_bytes[tracked_owner_count] = {};
    std::uint64_t quota_refusals = 0;
};
class Backend final {
public:
    explicit Backend(const Operations&, void* context = nullptr) noexcept;
    ~Backend();
    Backend(const Backend&) = delete;
    Backend& operator=(const Backend&) = delete;
    int configure(std::uint32_t enabled_owner_mask,
                  std::uint64_t capacity_limit = maximum_capacity) noexcept;
    // IPC manager must authenticate PID/generation and observe creator exit
    // BEFORE adoption. Takes its own send-right reference; caller keeps theirs.
    // Failure may quarantine retained resources if OS rollback itself fails;
    // shutdown() retries those resources without publishing them as capacity.
    int adopt(std::uint32_t entry, std::uint64_t bytes, std::int32_t creator_pid,
              std::uint64_t generation) noexcept;
    void set_pressure(bool raised) noexcept;
    // Live-byte ceiling for one owner's objects; zero means no owner quota.
    // Lowering a quota below the live value refuses new objects only: existing
    // tokens, aliases and their data are never revoked by policy.
    int set_owner_quota(std::uint32_t owner, std::uint64_t bytes) noexcept;
    int create(std::uint32_t owner, std::uint64_t bytes, std::uint64_t* token) noexcept;
    int map(std::uint64_t token, void* target, std::uint32_t protection, void** mapped) noexcept;
    int unmap(std::uint64_t token, void* address) noexcept;
    int release(std::uint64_t token) noexcept;
    int retire(std::uint64_t token) noexcept;
    // Bounded retry of explicitly retired ANYWHERE aliases/scrubs only. Failed
    // fixed retirements are permanently quarantined: never overwrite a virtual
    // address which its former caller could have reused. Never touches active
    // guest tokens. Run on a maintenance worker, not a frame/audio callback.
    int collect() noexcept;
    int enabled(std::uint32_t owner) noexcept;
    int snapshot(NeoSwapRelayStats*) noexcept;
    PressureDiagnostics pressure_diagnostics() noexcept;
    // Refuses active objects, then retires every cleaning window/right. Failed
    // cleanup remains tracked and a later shutdown call retries just that work.
    int shutdown() noexcept;
private:
    struct State;
    std::unique_ptr<State> state_;
};
Backend& backend() noexcept;
#if defined(NEOSWAP_TESTING)
// Portable tests inject the OS operations of the process-wide backend before
// its first use. Deliverable builds never compile this hook.
void install_operations_for_test(const Operations& operations, void* context) noexcept;
#endif
int configure(std::uint32_t enabled_owner_mask,
              std::uint64_t capacity_limit = maximum_capacity) noexcept;
int set_owner_quota(std::uint32_t owner, std::uint64_t bytes) noexcept;
int adopt(std::uint32_t entry, std::uint64_t bytes, std::int32_t creator_pid,
          std::uint64_t generation) noexcept;
void set_pressure(bool raised) noexcept;
int shutdown() noexcept;
int collect() noexcept;
} // namespace neostation::relay
