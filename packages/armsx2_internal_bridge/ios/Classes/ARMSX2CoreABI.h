// SPDX-License-Identifier: GPL-3.0-or-later
// Versioned C boundary. The Flutter host never links the PCSX2 C++ ABI.
#pragma once
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
#define NEO_ARMSX2_ABI_VERSION 1u
#define NEO_ARMSX2_BOOT_DISC 1u
#define NEO_ARMSX2_BOOT_ELF 2u

typedef void (*NeoARMSX2Event)(void* context, uint64_t transaction,
                             const char* event, const char* message);
typedef struct NeoARMSX2Configuration {
  uint32_t size;
  uint64_t transaction;
  const char* data_directory;
  const char* resource_directory;
  const char* bios_directory;
  const char* bios_filename; // Empty selects a valid BIOS, never copies it.
  NeoARMSX2Event event;
  void* context;
} NeoARMSX2Configuration;

typedef struct NeoARMSX2API {
  uint32_t size;
  uint32_t version;
  const char* source_revision;
  // UIKit calls only on main. The core retains the returned UIView.
  void* (*create_render_view)(char* error, size_t capacity);
  void (*release_render_view)(void);
  // Blocking calls only off main. All VM operations run on one owned thread.
  int (*prepare)(const NeoARMSX2Configuration*, uint32_t timeout_ms, char*, size_t);
  // Must be called while the authenticated helper still owns debugserver.
  // The breakpoint requests a real GDB D detach; failure never becomes ready.
  int (*request_jit_detach)(char*, size_t);
  int (*validate_jit)(char*, size_t);
  int (*boot)(const char* absolute_path, uint32_t kind, uint32_t timeout_ms, char*, size_t);
  void (*request_stop)(void);
  int (*shutdown)(uint32_t timeout_ms, char*, size_t);
  void (*set_paused)(int paused);
  void (*set_button)(uint32_t button, int pressed);
  void (*set_sticks)(float left_x, float left_y, float right_x, float right_y);
} NeoARMSX2API;

typedef const NeoARMSX2API* (*NeoARMSX2GetAPI)(uint32_t version);
__attribute__((visibility("default"))) const NeoARMSX2API* NeoARMSX2_GetAPI(uint32_t version);
#ifdef __cplusplus
}
#endif
