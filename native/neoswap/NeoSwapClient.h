#pragma once
#include "NeoSwap.h"
#include "NeoSwapClientStats.h"
#include <atomic>
#include <cstddef>

namespace neostation::swap {
// Each core stores only a borrowed vtable. The broker itself is compiled once
// into neo_swap.framework, never into each emulator. No static constructors.
inline constinit std::atomic<const NeoSwapAPI*> client_api{nullptr};
inline constinit std::atomic<uint64_t> skipped_small{0}, missing_api{0}, disabled{0};
inline constinit std::atomic<uint64_t> eligible_attempts{0}, failed_allocations{0}, successful_allocations{0};
inline constinit std::atomic<int32_t> last_result{NEOSWAP_OK};
inline int install(const NeoSwapAPI* api) noexcept {
    if (!api || api->struct_size != sizeof(NeoSwapAPI) || api->abi_version != NEOSWAP_ABI ||
        !api->allocate || !api->release || !api->sync || !api->enabled) return NEOSWAP_INVALID;
    const NeoSwapAPI* expected = nullptr;
    if (!client_api.compare_exchange_strong(expected, api, std::memory_order_acq_rel) && expected != api)
        return NEOSWAP_BUSY;
    return NEOSWAP_OK;
}
inline void* try_allocate(uint32_t owner, size_t bytes, size_t alignment) noexcept {
    // Small renderer allocations must not take the broker lock or create files.
    if (bytes < 1024 * 1024) {
        skipped_small.fetch_add(1, std::memory_order_relaxed);
        return nullptr;
    }
    const auto* api = client_api.load(std::memory_order_acquire);
    if (!api) {
        missing_api.fetch_add(1, std::memory_order_relaxed);
        return nullptr;
    }
    if (!api->enabled(owner)) {
        disabled.fetch_add(1, std::memory_order_relaxed);
        return nullptr;
    }
    void* ptr = nullptr;
    eligible_attempts.fetch_add(1, std::memory_order_relaxed);
    const int result = api->allocate(owner, NEOSWAP_CPU_DATA, bytes, alignment, &ptr);
    last_result.store(result, std::memory_order_relaxed);
    if (result == NEOSWAP_OK && ptr) {
        successful_allocations.fetch_add(1, std::memory_order_relaxed);
        return ptr;
    }
    failed_allocations.fetch_add(1, std::memory_order_relaxed);
    return nullptr;
}
// RSX CPU data only. Vulkan retains try_allocate() and its 1 MiB threshold.
// The host decides whether this title may borrow sub-MiB buffers. A refusal
// returns to the original aligned heap allocator, never to a per-buffer file.
inline void* try_allocate_cpu(uint32_t owner, size_t bytes, size_t alignment) noexcept {
    if (bytes >= 1024 * 1024 || bytes < 64 * 1024)
        return try_allocate(owner, bytes, alignment);
    const auto* api = client_api.load(std::memory_order_acquire);
    if (!api) {
        missing_api.fetch_add(1, std::memory_order_relaxed);
        return nullptr;
    }
    if (!api->enabled(owner)) {
        disabled.fetch_add(1, std::memory_order_relaxed);
        return nullptr;
    }
    void* pointer = nullptr;
    eligible_attempts.fetch_add(1, std::memory_order_relaxed);
    const int result = api->allocate(owner, NEOSWAP_CPU_CACHE, bytes, alignment, &pointer);
    last_result.store(result, std::memory_order_relaxed);
    if (result == NEOSWAP_OK && pointer) {
        successful_allocations.fetch_add(1, std::memory_order_relaxed);
        return pointer;
    }
    failed_allocations.fetch_add(1, std::memory_order_relaxed);
    return nullptr;
}
inline int snapshot(NeoSwapClientStats* out) noexcept {
    if (!out || out->struct_size != sizeof(*out) ||
        out->abi_version != NEOSWAP_CLIENT_STATS_ABI) return NEOSWAP_INVALID;
    // Relaxed cumulative observations avoid adding locks to renderer threads.
    *out = {sizeof(*out), NEOSWAP_CLIENT_STATS_ABI,
        skipped_small.load(std::memory_order_relaxed), missing_api.load(std::memory_order_relaxed),
        disabled.load(std::memory_order_relaxed), eligible_attempts.load(std::memory_order_relaxed),
        failed_allocations.load(std::memory_order_relaxed), successful_allocations.load(std::memory_order_relaxed),
        last_result.load(std::memory_order_relaxed), 0};
    return NEOSWAP_OK;
}
inline int release(void* ptr) noexcept {
    const auto* api = client_api.load(std::memory_order_acquire);
    return api ? api->release(ptr) : NEOSWAP_NOT_OWNED;
}
}
