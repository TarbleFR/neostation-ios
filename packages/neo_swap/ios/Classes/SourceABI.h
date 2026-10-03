// SPDX-License-Identifier: MIT
#ifndef NEOSTATION_SOURCE_ARCHIVE_ABI_H
#define NEOSTATION_SOURCE_ARCHIVE_ABI_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
/* Optional host-owned archive for immutable CPU snapshots: compiled GLSL
 * (domains 0..2), or exclusively owned software pixels (domain 3 opt-in).
 * An old GLSL-only host refuses domain 3; retain original pixels on refusal.
 * Layout/ABI 1 is unchanged. Admission
 * snapshots at most 1 MiB, never waits for I/O and keeps ownership on refusal.
 * The host checkpoints on its utility queue before releasing its snapshot.
 * read copies into caller-owned output: synchronous debug/export or VDEC CPU
 * consumption outside queue/conversion locks. NOT an RSX/render-thread lookup,
 * a guest-memory pager or a way to archive FFmpeg reference/GPU frames. */
enum { NEOSWAP_SOURCE_ABI = 1, NEOSWAP_SOURCE_MAX_BYTES = 1024*1024 };
enum NeoSwapSourceResult { NS_SOURCE_OK=0, NS_SOURCE_BUSY=1,
    NS_SOURCE_DISABLED=2, NS_SOURCE_INVALID=3, NS_SOURCE_IO=4,
    NS_SOURCE_QUOTA=5, NS_SOURCE_MISSING=6, NS_SOURCE_PRESSURE=7 };
typedef struct NeoSwapSourceAPI {
    uint32_t struct_size, abi_version;
    uint64_t (*session)(void);
    int (*admit)(uint64_t session, uint32_t domain, const char* source,
                 uint64_t bytes, uint64_t* object);
    int (*read)(uint64_t session, uint64_t object, char* output,
                uint64_t exact_bytes, int* os_error);
    void (*discard)(uint64_t session, uint64_t object);
    void (*released)(uint64_t session, uint64_t source_capacity);
} NeoSwapSourceAPI;
#ifdef __cplusplus
}
#endif
#endif
