// SPDX-License-Identifier: MIT
#ifndef NEOSTATION_NEOSWAP_RELAY_H
#define NEOSTATION_NEOSWAP_RELAY_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

/* Separate ABI: does not change NeoSwapAPI v1 or its allocation ownership.
 * A token owns one backing interval. Every map of that token aliases the SAME
 * bytes. Capacity is retained VM-object capacity, never resident physical RAM.
 * All calls require a normal thread. Quiesce every guest/CPU/GPU user before
 * unmap/release; these operations do not wait for emulator work to complete.
 */
enum { NEOSWAP_RELAY_ABI = 1, NEOSWAP_RELAY_ALIGNMENT = 65536 };
enum NeoSwapRelayProtection {
    NEOSWAP_RELAY_NONE = 0, NEOSWAP_RELAY_READ = 1, NEOSWAP_RELAY_READ_WRITE = 3
};
enum NeoSwapRelayResult {
    NEOSWAP_RELAY_OK = 0, NEOSWAP_RELAY_DISABLED = -1,
    NEOSWAP_RELAY_INVALID = -2, NEOSWAP_RELAY_QUOTA = -3,
    NEOSWAP_RELAY_MAPPING = -4, NEOSWAP_RELAY_BUSY = -5,
    NEOSWAP_RELAY_UNKNOWN = -6, NEOSWAP_RELAY_PRESSURE = -7,
    NEOSWAP_RELAY_LIMIT = -8, NEOSWAP_RELAY_CLEANUP = -9
};
typedef struct NeoSwapRelayStats {
    uint32_t struct_size, abi_version;
    uint64_t capacity_bytes, retained_capacity_bytes, live_bytes, peak_live_bytes;
    uint64_t object_count, alias_count, mapped_alias_bytes, entry_count;
    uint64_t rejection_count, os_error_count, pending_cleanup_entries, retiring_object_count;
    uint64_t quarantined_fixed_alias_count;
    uint32_t enabled_owner_mask, pressure_raised;
    int32_t last_result, last_os_error;
} NeoSwapRelayStats;
typedef struct NeoSwapRelayAPI {
    uint32_t struct_size, abi_version;
    int (*create)(uint32_t owner, uint64_t bytes, uint64_t* token);
    /* A non-null target MUST be a caller-owned reserved guest range. Existing
     * guest users must be quiesced. Failed maps leave that reservation intact.
     * Null requests a new, 64-KiB-aligned alias. No executable mapping exists.
     */
    int (*map)(uint64_t token, void* target, uint32_t protection, void** mapped);
    /* A fixed alias is atomically replaced with a PROT_NONE reservation;
     * an anywhere alias is deallocated. Failure retains ownership and mapping.
     */
    int (*unmap)(uint64_t token, void* address);
    /* BUSY while any aliases remain. Scrub failure retains the token for retry;
     * no error permits reuse of the backing interval or an ordinary free().
     */
    int (*release)(uint64_t token);
    int (*enabled)(uint32_t owner);
    int (*snapshot)(NeoSwapRelayStats* stats);
    /* Destructor path: caller has quiesced ALL users and relinquishes the
     * token. The backend blocks new maps immediately and owns retirement of
     * every remaining alias. ANYWHERE cleanup errors are retried by collect().
     * FIXED aliases are attempted synchronously once: a failed fixed replacement
     * is permanently quarantined because its caller may subsequently reuse the
     * virtual address. That object is never scrubbed/reissued during this process.
     * Unlike release(), caller may forget the token after calling retire().
     */
    int (*retire)(uint64_t token);
} NeoSwapRelayAPI;
#if defined(__GNUC__)
__attribute__((visibility("default")))
#endif
const NeoSwapRelayAPI* NeoSwap_GetRelayAPI(uint32_t abi_version);
#ifdef __cplusplus
}
#endif
#endif
