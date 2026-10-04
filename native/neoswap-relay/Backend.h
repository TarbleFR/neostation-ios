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
constexpr std::uint32_t supported_owner_mask = initial_owner_mask; // RPCS3 only, including preparation checks.

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
int configure(std::uint32_t enabled_owner_mask,
              std::uint64_t capacity_limit = maximum_capacity) noexcept;
int adopt(std::uint32_t entry, std::uint64_t bytes, std::int32_t creator_pid,
          std::uint64_t generation) noexcept;
void set_pressure(bool raised) noexcept;
int shutdown() noexcept;
int collect() noexcept;
} // namespace neostation::relay
