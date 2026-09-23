// SPDX-License-Identifier: GPL-3.0-or-later
// Versioned C boundary. The Flutter host never links the PCSX2 C++ ABI.
#pragma once
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
#define NEO_ARMSX2_ABI_VERSION 5u
#define NEO_ARMSX2_BOOT_DISC 1u
#define NEO_ARMSX2_BOOT_ELF 2u
// No ROM: use the installed BIOS and the same owned VM lifecycle.
#define NEO_ARMSX2_BOOT_BIOS 3u
#define NEO_ARMSX2_RA_ENABLED 1u
#define NEO_ARMSX2_RA_HARDCORE 2u
#define NEO_ARMSX2_RA_NOTIFICATIONS 3u
#define NEO_ARMSX2_RA_LEADERBOARDS 4u
#define NEO_ARMSX2_RA_OVERLAYS 5u

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

  // In-game ARMSX2 controls/settings. Settings target the running game's
  // per-game INI and are live-applied by the upstream ARMSX2 bridge.
  float (*get_upscale_multiplier)(void);
  uint32_t (*get_aspect_ratio)(void);
  int (*get_cheats_enabled)(void);
  int (*set_upscale_multiplier)(float value, char* error, size_t capacity);
  int (*set_aspect_ratio)(uint32_t value, char* error, size_t capacity);
  int (*set_cheats_enabled)(int enabled, char* error, size_t capacity);
  int (*reload_cheats)(char* error, size_t capacity);

  // Native catalogue from patches.zip, patches/ and cheats/. JSON includes
  // typed item IDs, unlabelled command counts and actual active counts.
  int (*get_available_patches_json)(char* output, size_t capacity);
  // Accepts a catalogue item ID (neo-patch-v1: + JSON [isCheat,name]) or a
  // legacy patch name. -1 automatic (presentation patches only), 0 off, 1 on.
  int (*set_patch_state)(const char* name, int state, char* error, size_t capacity);

  int (*has_save_state)(uint32_t slot);
  int (*save_state)(uint32_t slot, uint32_t timeout_ms, char* error, size_t capacity);
  int (*load_state)(uint32_t slot, uint32_t timeout_ms, char* error, size_t capacity);

  // RetroAchievements is implemented by upstream ARMSX2/PCSX2. The host only
  // exposes that native state and its persisted settings through this stable C ABI.
  int (*get_retroachievements_state_json)(char* output, size_t capacity);
  int (*set_retroachievements_option)(uint32_t option, int enabled,
                                      uint32_t timeout_ms, char* error, size_t capacity);
  int (*login_retroachievements)(const char* username, const char* password,
                                 uint32_t timeout_ms, char* error, size_t capacity);
  int (*logout_retroachievements)(uint32_t timeout_ms, char* error, size_t capacity);

  // Whitelisted per-game GS hacks. -1 removes this game's explicit override;
  // 0/1 select off/on. Effective state comes from the upstream GS/GameDB path.
  int (*get_graphics_hacks_json)(char* output, size_t capacity);
  int (*set_graphics_hack)(const char* key, int value, char* error, size_t capacity);
} NeoARMSX2API;

typedef const NeoARMSX2API* (*NeoARMSX2GetAPI)(uint32_t version);
__attribute__((visibility("default"))) const NeoARMSX2API* NeoARMSX2_GetAPI(uint32_t version);
#ifdef __cplusplus
}
#endif
