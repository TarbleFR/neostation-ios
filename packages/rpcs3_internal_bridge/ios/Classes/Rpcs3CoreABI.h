#pragma once

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef int32_t rpcs3_ios_status;

typedef void (*rpcs3_ios_log_callback)(void* context,
                                       int32_t level,
                                       const char* message);
typedef void (*rpcs3_ios_dispatch_function)(void* context);
typedef void (*rpcs3_ios_dispatch_callback)(
    void* context,
    rpcs3_ios_dispatch_function function,
    void* function_context);
typedef void (*rpcs3_ios_progress_callback)(void* context,
                                            uint32_t current,
                                            uint32_t total,
                                            const char* detail);

typedef struct rpcs3_ios_init_options {
  uint32_t abi_version;
  uint32_t size;
  const char* support_path;
  const char* cache_path;
  rpcs3_ios_log_callback log_callback;
  rpcs3_ios_dispatch_callback dispatch_callback;
  void* context;
  uint32_t expanded_jit_region;
  uint32_t reserved;
} rpcs3_ios_init_options;

typedef struct rpcs3_ios_display_surface {
  uint32_t size;
  uint32_t width;
  uint32_t height;
  float refresh_rate;
  void* metal_layer;
} rpcs3_ios_display_surface;

// Keep this layout and bit assignment byte-for-byte compatible with the pinned
// XITRIX RPCS3 iOS ABI (rpcs3/ios/RPCS3IOS.h, ABI 30).
typedef enum rpcs3_ios_pad_button_bits {
  rpcs3_ios_pad_up       = 1u << 0,
  rpcs3_ios_pad_down     = 1u << 1,
  rpcs3_ios_pad_left     = 1u << 2,
  rpcs3_ios_pad_right    = 1u << 3,
  rpcs3_ios_pad_square   = 1u << 4,
  rpcs3_ios_pad_cross    = 1u << 5,
  rpcs3_ios_pad_circle   = 1u << 6,
  rpcs3_ios_pad_triangle = 1u << 7,
  rpcs3_ios_pad_l1       = 1u << 8,
  rpcs3_ios_pad_l2       = 1u << 9,
  rpcs3_ios_pad_r1       = 1u << 10,
  rpcs3_ios_pad_r2       = 1u << 11,
  rpcs3_ios_pad_l3       = 1u << 12,
  rpcs3_ios_pad_r3       = 1u << 13,
  rpcs3_ios_pad_select   = 1u << 14,
  rpcs3_ios_pad_start    = 1u << 15,
  rpcs3_ios_pad_ps       = 1u << 16,
} rpcs3_ios_pad_button_bits;

typedef struct rpcs3_ios_pad_state {
  uint32_t size;
  uint32_t buttons;
  float left_x;
  float left_y;
  float right_x;
  float right_y;
  float l2;
  float r2;
} rpcs3_ios_pad_state;

typedef struct rpcs3_ios_api {
  void* handle;
  uint32_t (*abi_version)(void);
  const char* (*build_info)(void);
  rpcs3_ios_status (*initialize)(const rpcs3_ios_init_options*);
  const char* (*firmware_version)(void);
  rpcs3_ios_status (*install_firmware)(const char*, rpcs3_ios_progress_callback, void*);
  rpcs3_ios_status (*install_package)(const char*, rpcs3_ios_progress_callback, void*);
  rpcs3_ios_status (*install_iso)(const char*, const char*, rpcs3_ios_progress_callback, void*);
  rpcs3_ios_status (*install_zip)(const char*, rpcs3_ios_progress_callback, void*);
  rpcs3_ios_status (*install_folder)(const char*, rpcs3_ios_progress_callback, void*);
  rpcs3_ios_status (*set_display_surface)(const rpcs3_ios_display_surface*);
  rpcs3_ios_status (*set_pad_state)(uint32_t, const rpcs3_ios_pad_state*);
  rpcs3_ios_status (*boot_game)(const char*, const char*);
  int32_t (*get_emulation_state)(void);
  rpcs3_ios_status (*stop_emulation)(void);
  rpcs3_ios_status (*shutdown)(void);
  const char* (*last_error)(void);
} rpcs3_ios_api;

#ifdef __cplusplus
}
#endif