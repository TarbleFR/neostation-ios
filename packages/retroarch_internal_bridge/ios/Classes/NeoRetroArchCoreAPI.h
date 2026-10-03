#pragma once
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define NEO_RETROARCH_ABI_VERSION 1u
#define NEO_RETROARCH_RUNTIME_IDENTITY "neostation-retroarch-curated-v1"

/* The host owns its UIViewController and all user-visible Documents directories.
 * ABI methods are called on the main thread. The backend owns its runloop and
 * must not block start()/request_stop() waiting for emulation or a first frame.
 * No callback may outlive the acknowledged STOPPED/FAILED event for its session.
 * A RUNNING event means a rendered frame, not merely a successful retro_load_game.
 */
enum NeoRetroArchSessionState {
  NEO_RA_IDLE = 0,
  NEO_RA_STARTING = 1,
  NEO_RA_RUNNING = 2,
  NEO_RA_PAUSED = 3,
  NEO_RA_STOPPING = 4,
  NEO_RA_STOPPED = 5,
  NEO_RA_FAILED = 6,
};

enum NeoRetroArchEvent {
  NEO_RA_EVENT_STATE = 1,
  NEO_RA_EVENT_MENU_REQUESTED = 2,
  NEO_RA_EVENT_DIAGNOSTIC = 3,
  // detail_json {command,success,errorCode,detail}, after a pending command
  // actually changes the renderer/task state; never optimistic confirmation.
  NEO_RA_EVENT_COMMAND_RESULT = 4,
};

enum NeoRetroArchCapability {
  NEO_RA_CAP_SAVE_STATES = 1ull << 0,
  NEO_RA_CAP_CORE_OPTIONS = 1ull << 1,
  NEO_RA_CAP_SHADERS = 1ull << 2,
  NEO_RA_CAP_OVERLAYS = 1ull << 3,
  NEO_RA_CAP_CHEATS = 1ull << 4,
};

typedef void (*NeoRetroArchEventFn)(void* context, uint64_t session_id,
                                  uint32_t event, uint32_t state,
                                  const char* detail_json);

typedef struct NeoRetroArchPaths {
  uint32_t size;
  const char* root_path;
  const char* system_path;
  const char* save_path;
  const char* state_path;
  const char* config_path;
  const char* shader_path;
  const char* overlay_path;
  const char* cheat_path;
  const char* log_path;
} NeoRetroArchPaths;

typedef struct NeoRetroArchLaunch {
  uint32_t size;
  uint64_t session_id;
  const char* core_path;
  const char* game_path;
  const char* locale;
  void* host_view; /* UIView*, valid through STOPPED/FAILED. */
} NeoRetroArchLaunch;

/* command() executes one operation between emulation frames, on the main
 * thread. Returns 0 on success; JSON always contains success/errorCode/detail.
 * A insufficient response buffer is an error, never truncated success.
 * Commands: readStates, saveState {slot}, loadState {slot}, readOptions,
 * setOption {key,value}, readShaders, applyShader {path}, readOverlays,
 * applyOverlay {path}, readCheats, setCheat {index,enabled},
 * addCheat {description,code,enabled}, deleteCheat {index},
 * importCheats {path}. Paths must remain in the corresponding Documents folder.
 * Read lists return items:[{title,value,...}], options may also contain choices.
 * readStates returns slots:[{slot,exists,modified}]. The host does not manufacture
 * capabilities or report unsupported commands as successful.
 */
typedef struct NeoRetroArchCoreAPI {
  uint32_t abi_version;
  uint32_t struct_size;
  const char* (*runtime_identity)(void);
  int (*initialize)(const NeoRetroArchPaths* paths, char* error, size_t error_size);
  void (*set_event_callback)(NeoRetroArchEventFn callback, void* context);
  int (*start)(const NeoRetroArchLaunch* launch, char* error, size_t error_size);
  int (*request_stop)(uint64_t session_id, char* error, size_t error_size);
  int (*set_paused)(uint64_t session_id, int paused, char* error, size_t error_size);
  uint32_t (*session_state)(uint64_t session_id);
  uint64_t (*capabilities)(uint64_t session_id);
  int (*command)(uint64_t session_id, const char* request_json,
                 char* response_json, size_t response_size,
                 char* error, size_t error_size);
} NeoRetroArchCoreAPI;

typedef const NeoRetroArchCoreAPI* (*NeoRetroArchGetAPIFn)(void);
const NeoRetroArchCoreAPI* NeoRetroArch_GetAPI(void);

#ifdef __cplusplus
}
#endif
