#ifndef NEOSTATION_NEOSWAP_H
#define NEOSTATION_NEOSWAP_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
/* NeoSwap v1: explicitly opted-in CPU data, not kernel swap or GPU memory.
 * One broker per HOST PROCESS. Clients borrow the immutable vtable for the
 * lifetime of their allocations. No function may be called from a signal
 * handler or a real-time audio callback. Never pass an arbitrary live region.
 * Caller must quiesce users before releasing or syncing a block.
 */
enum { NEOSWAP_ABI = 1, NEOSWAP_OWNER_COUNT = 6 };
enum NeoSwapOwner {
    NEOSWAP_RPCS3 = 0, NEOSWAP_DOLPHIN = 1, NEOSWAP_ARMSX2 = 2,
    NEOSWAP_DUSKLIGHT = 3, NEOSWAP_KARTPAD = 4, NEOSWAP_PROBE = 5
};
enum NeoSwapKind { NEOSWAP_CPU_DATA = 1, NEOSWAP_CPU_CACHE = 2 };
enum NeoSwapResult {
    NEOSWAP_OK = 0, NEOSWAP_NOT_OWNED = 1,
    NEOSWAP_DISABLED = -1, NEOSWAP_INVALID = -2, NEOSWAP_QUOTA = -3,
    NEOSWAP_STORAGE = -4, NEOSWAP_IO = -5, NEOSWAP_MAPPING = -6,
    NEOSWAP_BUSY = -7, NEOSWAP_TOO_SMALL = -8, NEOSWAP_LIMIT = -9
};
typedef struct NeoSwapConfig {
    uint32_t struct_size, abi_version;
    uint64_t capacity_bytes, minimum_free_bytes, minimum_allocation_bytes;
    uint32_t enabled_owner_mask, reserved;
} NeoSwapConfig;
typedef struct NeoSwapOwnerStats {
    uint64_t live_bytes, peak_bytes, allocation_count, rejection_count;
} NeoSwapOwnerStats;
typedef struct NeoSwapStats {
    uint32_t struct_size, abi_version;
    uint64_t capacity_bytes, live_bytes, peak_bytes, allocated_disk_bytes;
    uint64_t live_blocks, allocation_count, rejection_count, io_errors;
    uint64_t allocation_time_us, max_allocation_time_us, minimum_free_bytes;
    uint32_t enabled_owner_mask;
    int32_t last_result, last_errno;
    uint32_t registered_owner_mask;
    NeoSwapOwnerStats owners[NEOSWAP_OWNER_COUNT];
} NeoSwapStats;
typedef struct NeoSwapAPI {
    uint32_t struct_size, abi_version;
    int (*allocate)(uint32_t owner, uint32_t kind, uint64_t bytes,
                    uint64_t alignment, void** address);
    /* ONLY NOT_OWNED permits a caller to use its ordinary free(). Any other
     * failure retains ownership and must not be turned into a heap free. */
    int (*release)(void* address);
    int (*sync)(void* address);
    int (*enabled)(uint32_t owner);
} NeoSwapAPI;
#if defined(__GNUC__)
#define NEOSWAP_PUBLIC __attribute__((visibility("default")))
#else
#define NEOSWAP_PUBLIC
#endif
NEOSWAP_PUBLIC const NeoSwapAPI* NeoSwap_GetAPI(uint32_t abi_version);
/* Reconfiguration is atomic; it refuses while any broker block is live. */
NEOSWAP_PUBLIC int NeoSwap_Configure(const char* private_directory, const NeoSwapConfig* config);
NEOSWAP_PUBLIC int NeoSwap_Snapshot(NeoSwapStats* stats);
NEOSWAP_PUBLIC void NeoSwap_RegisterClient(uint32_t owner);
/* Lock-free display counter, not a residency or OS page-out measurement. */
NEOSWAP_PUBLIC uint64_t NeoSwap_LiveBytes(uint32_t owner);
#ifdef NEOSWAP_TESTING
/* Fault injection is compiled out of deliverable libraries. */
void NeoSwap_TestFailNext(int stage); /* 1=open, 2=reserve, 3=map, 4=unmap, 5=sync */
int NeoSwap_TestVerifyFile(void* address, const void* expected, size_t bytes);
#endif
#ifdef __cplusplus
}
#endif
#endif
