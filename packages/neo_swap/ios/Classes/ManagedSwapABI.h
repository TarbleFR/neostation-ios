// SPDX-License-Identifier: MIT
#ifndef NEOSTATION_MANAGED_SWAP_ABI_H
#define NEOSTATION_MANAGED_SWAP_ABI_H
#include <stdint.h>

#define NEOSWAP_MANAGED_ABI_VERSION 1u
#ifdef __cplusplus
extern "C" {
#define NS_MANAGED_NOEXCEPT noexcept
#else
#define NS_MANAGED_NOEXCEPT
#endif

/* Explicitly owned, bounded CPU chunks. Never pass guest/JIT/GPU pointers or
 * the sole copy of saves. Create/Destroy, Read, Write, Checkpoint, Evict,
 * Retire, DescribeChunk and Stats belong on a serialized utility queue.
 * TryRead performs no file I/O and never waits for the manager's lock.
 * The caller must serialize Destroy against all context operations.
 * Views pin exactly one chunk. They remain valid after Retire and Destroy;
 * release their opaque lease exactly once, through the original view.
 * Initialize output headers to {sizeof(output), NEOSWAP_MANAGED_ABI_VERSION}.
 * Larger compatible structs are accepted; unknown ABI versions are refused.
 * A live view cannot be overwritten by another acquire operation.
 */
enum NeoSwapManagedCode {
    NS_MANAGED_OK = 0, NS_MANAGED_MISSING = 1, NS_MANAGED_BUSY = 2,
    NS_MANAGED_PRESSURE = 3, NS_MANAGED_QUOTA = 4, NS_MANAGED_IO = 5,
    NS_MANAGED_CORRUPT = 6, NS_MANAGED_STOPPED = 7,
    NS_MANAGED_INVALID = 8, NS_MANAGED_STALE = 9
};
enum NeoSwapManagedPressure {
    NS_MANAGED_PRESSURE_NORMAL = 0, NS_MANAGED_PRESSURE_WARNING = 1,
    NS_MANAGED_PRESSURE_CRITICAL = 2
};
typedef struct NeoSwapManagedContext NeoSwapManagedContext;
typedef struct NeoSwapManagedReadLease NeoSwapManagedReadLease;
typedef struct NeoSwapManagedWriteLease NeoSwapManagedWriteLease;
typedef struct NeoSwapManagedObject { uint64_t id, session; } NeoSwapManagedObject;
typedef struct NeoSwapManagedError {
    uint32_t struct_size, abi_version, code;
    int32_t os_error;
} NeoSwapManagedError;
typedef struct NeoSwapManagedConfig {
    uint32_t struct_size, abi_version;
    uint64_t resident_bytes, logical_bytes;
    uint32_t chunk_bytes, max_objects;
    uint64_t store_ram_bytes, store_warm_bytes, disk_bytes, free_disk_floor;
    uint64_t max_write_bytes_per_second;
    uint32_t store_max_blob, store_max_entries, store_max_queue;
    uint32_t compression_budget_us, prefetch_latency_limit_us;
    uint32_t compression; /* exactly 0 or 1; no C++ bool in the public ABI */
} NeoSwapManagedConfig;
typedef struct NeoSwapManagedChunkInfo {
    uint32_t struct_size, abi_version;
    uint64_t generation, persisted_generation, byte_count;
    uint32_t resident, borrowed;
} NeoSwapManagedChunkInfo;
typedef struct NeoSwapManagedReadView {
    uint32_t struct_size, abi_version;
    const uint8_t* data;
    uint64_t byte_count, generation;
    NeoSwapManagedReadLease* lease;
} NeoSwapManagedReadView;
typedef struct NeoSwapManagedWriteView {
    uint32_t struct_size, abi_version;
    uint8_t* data;
    uint64_t byte_count, generation;
    NeoSwapManagedWriteLease* lease;
} NeoSwapManagedWriteView;
typedef struct NeoSwapManagedStorageStats {
    uint64_t logical_bytes, raw_ram_bytes, compressed_ram_bytes;
    uint64_t pinned_raw_bytes, loading_reserved_bytes;
    uint64_t disk_only_logical_bytes, stored_payload_bytes;
    uint64_t allocated_file_bytes, reserved_file_bytes;
    uint64_t reusable_file_bytes, reused_extent_count, discarded_entries;
    uint64_t bytes_read, bytes_written, read_calls, write_calls;
    uint64_t evicted_logical_bytes, restored_logical_bytes;
    uint64_t warm_hits, ram_hits, disk_hits;
    uint64_t prefetch_used, prefetch_wasted, prefetch_cancelled;
    uint64_t io_errors, corruptions, quota_refusals, backpressure;
    uint64_t pressure_events, compression_attempts, compression_accepted;
    uint64_t compression_input_bytes, compression_output_bytes;
    uint64_t compression_us, decompression_us, worker_scratch_peak;
    uint64_t queue_peak, managed_ram_peak;
    uint64_t read_p50_us, read_p95_us, read_p99_us, read_max_us;
    uint64_t write_p95_us, queue_p95_us, restore_p95_us;
    int32_t last_errno;
    uint32_t pressure; /* 0 normal, 1 warning, 2 critical */
} NeoSwapManagedStorageStats;
typedef struct NeoSwapManagedStats {
    uint32_t struct_size, abi_version;
    uint64_t logical_bytes, owned_ram_bytes;
    uint64_t resident_mapped_bytes, resident_mapped_peak;
    uint64_t resident_limit_bytes, owned_limit_bytes;
    uint64_t backend_workspace_bound_bytes;
    uint64_t checkpointed_bytes, released_owned_bytes, restored_bytes;
    uint64_t checkpoints, failures, objects, chunks;
    NeoSwapManagedStorageStats store;
} NeoSwapManagedStats;

/* Config defaults are copied from the production Manager, not duplicated. */
uint32_t NeoSwapManagedDefaultConfig(NeoSwapManagedConfig*, uint32_t struct_size) NS_MANAGED_NOEXCEPT;
NeoSwapManagedContext* NeoSwapManagedCreate(const char* private_directory,
    const NeoSwapManagedConfig* /* null uses defaults */, NeoSwapManagedError*) NS_MANAGED_NOEXCEPT;
void NeoSwapManagedDestroy(NeoSwapManagedContext*) NS_MANAGED_NOEXCEPT;
uint32_t NeoSwapManagedCreateObject(NeoSwapManagedContext*, uint64_t logical_bytes,
    NeoSwapManagedObject*, uint32_t* chunk_count, NeoSwapManagedError*) NS_MANAGED_NOEXCEPT;
uint32_t NeoSwapManagedDescribeChunk(NeoSwapManagedContext*, NeoSwapManagedObject,
    uint32_t chunk, NeoSwapManagedChunkInfo*, NeoSwapManagedError*) NS_MANAGED_NOEXCEPT;
uint32_t NeoSwapManagedTryRead(NeoSwapManagedContext*, NeoSwapManagedObject,
    uint32_t chunk, NeoSwapManagedReadView*, NeoSwapManagedError*) NS_MANAGED_NOEXCEPT;
uint32_t NeoSwapManagedRead(NeoSwapManagedContext*, NeoSwapManagedObject,
    uint32_t chunk, NeoSwapManagedReadView*, NeoSwapManagedError*) NS_MANAGED_NOEXCEPT;
uint32_t NeoSwapManagedWrite(NeoSwapManagedContext*, NeoSwapManagedObject,
    uint32_t chunk, uint64_t expected_generation, NeoSwapManagedWriteView*, NeoSwapManagedError*) NS_MANAGED_NOEXCEPT;
uint32_t NeoSwapManagedCheckpoint(NeoSwapManagedContext*, NeoSwapManagedObject,
    uint32_t chunk, uint64_t expected_generation, NeoSwapManagedError*) NS_MANAGED_NOEXCEPT;
uint32_t NeoSwapManagedEvict(NeoSwapManagedContext*, NeoSwapManagedObject,
    uint32_t chunk, NeoSwapManagedError*) NS_MANAGED_NOEXCEPT;
uint32_t NeoSwapManagedRetire(NeoSwapManagedContext*, NeoSwapManagedObject,
    NeoSwapManagedError*) NS_MANAGED_NOEXCEPT;
void NeoSwapManagedReleaseRead(NeoSwapManagedReadView*) NS_MANAGED_NOEXCEPT;
void NeoSwapManagedReleaseWrite(NeoSwapManagedWriteView*) NS_MANAGED_NOEXCEPT;
uint32_t NeoSwapManagedSnapshot(NeoSwapManagedContext*, NeoSwapManagedStats*, NeoSwapManagedError*) NS_MANAGED_NOEXCEPT;
uint32_t NeoSwapManagedSetPressure(NeoSwapManagedContext*, uint32_t pressure,
    NeoSwapManagedError*) NS_MANAGED_NOEXCEPT;

#ifdef NEOSWAP_STORAGE_TESTING
enum NeoSwapManagedTestFault {
    NS_MANAGED_TEST_NONE = 0, NS_MANAGED_TEST_WRITE_ERROR = 1,
    NS_MANAGED_TEST_SYNC_ERROR = 2, NS_MANAGED_TEST_READ_ERROR = 3,
    NS_MANAGED_TEST_SHORT_IO = 4, NS_MANAGED_TEST_TRUNCATE = 5,
    NS_MANAGED_TEST_CORRUPT = 6
};
uint32_t NeoSwapManagedTestInject(NeoSwapManagedContext*, uint32_t fault) NS_MANAGED_NOEXCEPT;
#endif
#ifdef __cplusplus
}
#endif
#undef NS_MANAGED_NOEXCEPT
#endif
