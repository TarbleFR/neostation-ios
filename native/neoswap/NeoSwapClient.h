#pragma once
#include "NeoSwap.h"
#include <atomic>
#include <cstddef>

namespace neostation::swap {
// Each core stores only a borrowed vtable. The broker itself is compiled once
// into neo_swap.framework, never into each emulator. No static constructors.
inline constinit std::atomic<const NeoSwapAPI*> client_api{nullptr};
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
    if (bytes < 1024 * 1024) return nullptr;
    const auto* api = client_api.load(std::memory_order_acquire);
    if (!api || !api->enabled(owner)) return nullptr;
    void* ptr = nullptr;
    return api->allocate(owner, NEOSWAP_CPU_DATA, bytes, alignment, &ptr) == NEOSWAP_OK ? ptr : nullptr;
}
inline int release(void* ptr) noexcept {
    const auto* api = client_api.load(std::memory_order_acquire);
    return api ? api->release(ptr) : NEOSWAP_NOT_OWNED;
}
}
