#pragma once

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define NEO_DUSKLIGHT_ABI_VERSION 3u
#define NEO_DUSKLIGHT_DIFFERENT_DISC (-2)

enum NeoDusklightState {
  NEO_DUSKLIGHT_IDLE = 0,
  NEO_DUSKLIGHT_STARTING = 1,
  NEO_DUSKLIGHT_RUNNING = 2,
  NEO_DUSKLIGHT_STOPPING = 3,
  NEO_DUSKLIGHT_ENDED = 4,
};

/// Delivered on the UIKit main thread. RUNNING means a game frame was submitted.
typedef void (*NeoDusklightEventFn)(void* context, int state, const char* message);

/// Stable host/Core boundary. The Core adapter owns the game runtime;
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
  void (*set_event_callback)(NeoDusklightEventFn callback, void* context);
  int (*session_state)(void);
  // Translated by NeoStation's twelve-language catalog, copied by the Core.
  void (*set_ui_text)(const char* key, const char* value);
} NeoDusklightAPI;

typedef const NeoDusklightAPI* (*NeoDusklightGetAPIFn)(void);

#ifdef __cplusplus
}
#endif
