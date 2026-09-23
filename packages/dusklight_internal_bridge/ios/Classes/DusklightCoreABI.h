#pragma once

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define NEO_DUSKLIGHT_ABI_VERSION 1u

/// Stable host/Core boundary. The future Core adapter owns the game runtime;
/// UIKit window and application lifecycle remain owned by NeoStation.
typedef struct NeoDusklightAPI {
  uint32_t abi_version;
  uint32_t struct_size;
  int (*initialize)(const char* support_path,
                    const char* cache_path,
                    char* error,
                    size_t error_size);
  int (*start)(const char* game_path,
               void* host_view,
               char* error,
               size_t error_size);
  void (*stop)(void);
  int (*is_running)(void);
} NeoDusklightAPI;

typedef const NeoDusklightAPI* (*NeoDusklightGetAPIFn)(void);

#ifdef __cplusplus
}
#endif
