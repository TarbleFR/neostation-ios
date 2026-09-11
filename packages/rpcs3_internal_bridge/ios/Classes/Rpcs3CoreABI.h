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

// Exact byte layout and bit assignments of the pinned XITRIX RPCS3 iOS ABI 30.
// Local names retain the existing NeoStation call sites; comments show upstream names.
typedef enum rpcs3_ios_pad_button_bits {
  rpcs3_ios_pad_up       = 1ull << 0,
  rpcs3_ios_pad_down     = 1ull << 1,
  rpcs3_ios_pad_left     = 1ull << 2,
  rpcs3_ios_pad_right    = 1ull << 3,
  rpcs3_ios_pad_cross    = 1ull << 4,
  rpcs3_ios_pad_circle   = 1ull << 5,
  rpcs3_ios_pad_square   = 1ull << 6,
  rpcs3_ios_pad_triangle = 1ull << 7,
  rpcs3_ios_pad_l1       = 1ull << 8,
  rpcs3_ios_pad_r1       = 1ull << 9,
  rpcs3_ios_pad_l2       = 1ull << 10,
  rpcs3_ios_pad_r2       = 1ull << 11,
  rpcs3_ios_pad_l3       = 1ull << 12,
  rpcs3_ios_pad_r3       = 1ull << 13,
  rpcs3_ios_pad_start    = 1ull << 14,
  rpcs3_ios_pad_select   = 1ull << 15,
  rpcs3_ios_pad_ps       = 1ull << 16,
} rpcs3_ios_pad_button_bits;

typedef struct rpcs3_ios_pad_state {
  uint32_t size;       // upstream: struct_size
  uint32_t connected;
  uint64_t buttons;
  float left_x;        // upstream: left_stick_x
  float left_y;        // upstream: left_stick_y
  float right_x;       // upstream: right_stick_x
  float right_y;       // upstream: right_stick_y
  float l2;            // upstream: left_trigger
  float r2;            // upstream: right_trigger
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
