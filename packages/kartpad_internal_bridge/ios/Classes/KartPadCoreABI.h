#pragma once

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define NEO_KARTPAD_ABI_VERSION 1u
#define NEO_KARTPAD_RUNTIME_IDENTITY "kartpad_rmcp01_full_game_v1"

enum NeoKartPadState {
  NEO_KARTPAD_IDLE = 0,
  NEO_KARTPAD_STARTING = 1,
  NEO_KARTPAD_RUNNING = 2,
  NEO_KARTPAD_STOPPING = 3,
  NEO_KARTPAD_ENDED = 4,
};

typedef void (*NeoKartPadEventFn)(void* context, int state, const char* message);

typedef struct NeoKartPadAPI {
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
  void (*set_event_callback)(NeoKartPadEventFn callback, void* context);
  int (*session_state)(void);
  void (*set_ui_text)(const char* key, const char* value);
  const char* (*runtime_identity)(void);
} NeoKartPadAPI;

typedef const NeoKartPadAPI* (*NeoKartPadGetAPIFn)(void);

#ifdef __cplusplus
}
#endif
