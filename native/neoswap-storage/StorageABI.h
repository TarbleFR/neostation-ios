// SPDX-License-Identifier: MIT
#ifndef NEOSTATION_STORAGE_ABI_H
#define NEOSTATION_STORAGE_ABI_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
/* Optional HOST service for regenerable SPIR-V CPU bytes only. Never owns
 * VkShaderModule, GPU memory, guest pages, JIT code or user save data.
 * Calls on a rendering/compilation thread do no file I/O and never wait for I/O.
 * A miss (including pending restore) means recompile from the unchanged GLSL.
 * Each operation is scoped to an immutable session generation. */
enum { NEOSWAP_STORAGE_ABI = 1, NEOSWAP_STORAGE_KEY_BYTES = 32 };
enum NeoSwapStorageResult { NS_STORAGE_OK = 0, NS_STORAGE_MISS = 1,
    NS_STORAGE_BUSY = 2, NS_STORAGE_DISABLED = 3, NS_STORAGE_INVALID = 4 };
enum NeoSwapStorageEvent { NS_STORAGE_SOURCE_COMPILE = 1,
    NS_STORAGE_CACHED_MODULE_REJECTED = 2, NS_STORAGE_CPU_COPY_RELEASED = 3 };
typedef struct NeoSwapStorageView {
    const uint32_t* words;
    uint64_t byte_count;
    void* lease; /* opaque: release exactly once; valid across session stop */
} NeoSwapStorageView;
typedef struct NeoSwapStorageAPI {
    uint32_t struct_size, abi_version;
    uint64_t (*session)(void); /* zero unless configured for this title */
    int (*acquire)(uint64_t session, const uint8_t key[32], NeoSwapStorageView*);
    int (*publish)(uint64_t session, const uint8_t key[32], const uint32_t*, uint64_t);
    void (*release)(NeoSwapStorageView*);
    void (*prefetch)(uint64_t session, const uint8_t key[32]);
    void (*invalidate)(uint64_t session, const uint8_t key[32]);
    void (*event)(uint64_t session, uint32_t kind, uint64_t bytes);
} NeoSwapStorageAPI;
#ifdef __cplusplus
}
#endif
#endif
