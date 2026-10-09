/*
 * Minimal libretro core used to test NeoStation's libretro host on macOS.
 * It exercises the environment calls the host answers, records what it
 * observes in its save RAM (which the host writes to disk), and draws its
 * frame counter into pixel 0 so the harness can see loads and restores.
 */
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "libretro.h"

static retro_environment_t environ_cb;
static retro_video_refresh_t video_cb;
static retro_audio_sample_batch_t audio_batch_cb;
static retro_input_poll_t input_poll_cb;
static retro_input_state_t input_state_cb;
static retro_log_printf_t log_cb;

static uint32_t framebuffer[320 * 240];
static int16_t audio[800 * 2];
static uint8_t save_ram[2048];
static uint32_t frame_counter;
static uint32_t content_checksum;
static unsigned cheat_count;
static unsigned disk_index;
static bool disk_ejected;
static char option_value[32];
static bool jit_capable;
static bool first_frame = true;
static uint8_t restored_marker;
/*
 * Option values seen by retro_init (like DeSmuME, which reads its options
 * only there) and the last value re-read after GET_VARIABLE_UPDATE. Exposed
 * as RETRO_MEMORY_SYSTEM_RAM, which the host never saves or restores:
 *   [0..15] neotest_init, [16..31] neotest_locked, [32..47] neotest_default
 *   and [48..63] neotest_mode at retro_init; [64..79] neotest_init re-read
 *   in retro_run after an update; [80] number of updates seen.
 */
#define INIT_REPORT_FIELD 16
static uint8_t init_report[96];

/*
 * neotest_hw=on: the core registers a hardware context in retro_load_game
 * and, like Azahar freeing its Vulkan renderer, asks the frontend for its
 * hardware render interface in context_destroy, retro_unload_game and
 * retro_deinit; it logs each step with interface=1 when the frontend still
 * provides it. neotest_shutdown_frame=N: at frame N the core logs an error
 * and requests RETRO_ENVIRONMENT_SHUTDOWN, as PPSSPP does when its boot
 * fails.
 */
static bool hardware_context;
static unsigned shutdown_frame;

static int interface_available(void) {
  const struct retro_hw_render_interface *interface = NULL;
  return environ_cb(RETRO_ENVIRONMENT_GET_HW_RENDER_INTERFACE, (void *)&interface) && interface != NULL ? 1 : 0;
}

static void context_reset(void) {
  if (log_cb) log_cb(RETRO_LOG_INFO, "neotest context_reset interface=%d\n", interface_available());
}

static void context_destroy(void) {
  if (log_cb) log_cb(RETRO_LOG_INFO, "neotest context_destroy interface=%d\n", interface_available());
}

static bool option_is(const char *key, const char *value) {
  struct retro_variable variable = {key, NULL};
  return environ_cb(RETRO_ENVIRONMENT_GET_VARIABLE, &variable) && variable.value != NULL &&
         strcmp(variable.value, value) == 0;
}

static void read_option(const char *key, uint8_t *field) {
  struct retro_variable variable = {key, NULL};
  memset(field, 0, INIT_REPORT_FIELD);
  if (environ_cb(RETRO_ENVIRONMENT_GET_VARIABLE, &variable) && variable.value != NULL) {
    snprintf((char *)field, INIT_REPORT_FIELD, "%s", variable.value);
  }
}

static bool set_eject_state(bool ejected) {
  disk_ejected = ejected;
  return true;
}
static bool get_eject_state(void) { return disk_ejected; }
static unsigned get_image_index(void) { return disk_index; }
static bool set_image_index(unsigned index) {
  if (index >= 2) return false;
  disk_index = index;
  return true;
}
static unsigned get_num_images(void) { return 2; }
static bool replace_image_index(unsigned index, const struct retro_game_info *info) { return false; }
static bool add_image_index(void) { return false; }
static bool set_initial_image(unsigned index, const char *path) { return true; }
static bool get_image_path(unsigned index, char *path, size_t length) { return false; }
static bool get_image_label(unsigned index, char *label, size_t length) {
  snprintf(label, length, "Test disc %u", index + 1);
  return true;
}

RETRO_API void retro_set_environment(retro_environment_t cb) {
  environ_cb = cb;
  static struct retro_core_option_v2_definition definitions[] = {
      {"neotest_mode", "Mode", NULL, "Test mode", NULL, NULL, {{"alpha", "Alpha"}, {"beta", "Beta"}, {NULL, NULL}}, "alpha"},
      {"neotest_init", "Init", NULL, "Read in retro_init", NULL, NULL,
       {{"one", "One"}, {"two", "Two"}, {"three", "Three"}, {NULL, NULL}}, "one"},
      {"neotest_locked", "Locked", NULL, "Locked by the frontend", NULL, NULL,
       {{"free", "Free"}, {"user", "User"}, {"fixed", "Fixed"}, {NULL, NULL}}, "free"},
      {"neotest_default", "Default", NULL, "Frontend default", NULL, NULL,
       {{"core", "Core"}, {"neo", "Neo"}, {NULL, NULL}}, "core"},
      {"neotest_hw", "Hardware context", NULL, "Register a hardware context", NULL, NULL,
       {{"off", "Off"}, {"on", "On"}, {NULL, NULL}}, "off"},
      {"neotest_shutdown_frame", "Shutdown frame", NULL, "Request shutdown at this frame", NULL, NULL,
       {{"0", "Never"}, {"3", "Frame 3"}, {NULL, NULL}}, "0"},
      {NULL, NULL, NULL, NULL, NULL, NULL, {{NULL, NULL}}, NULL},
  };
  static struct retro_core_options_v2 options = {NULL, definitions};
  cb(RETRO_ENVIRONMENT_SET_CORE_OPTIONS_V2, &options);
}

RETRO_API void retro_set_video_refresh(retro_video_refresh_t cb) { video_cb = cb; }
RETRO_API void retro_set_audio_sample(retro_audio_sample_t cb) {}
RETRO_API void retro_set_audio_sample_batch(retro_audio_sample_batch_t cb) { audio_batch_cb = cb; }
RETRO_API void retro_set_input_poll(retro_input_poll_t cb) { input_poll_cb = cb; }
RETRO_API void retro_set_input_state(retro_input_state_t cb) { input_state_cb = cb; }

RETRO_API void retro_init(void) {
  struct retro_log_callback logging;
  if (environ_cb(RETRO_ENVIRONMENT_GET_LOG_INTERFACE, &logging)) log_cb = logging.log;
  if (log_cb) log_cb(RETRO_LOG_INFO, "neotest init\n");
  enum retro_pixel_format format = RETRO_PIXEL_FORMAT_XRGB8888;
  environ_cb(RETRO_ENVIRONMENT_SET_PIXEL_FORMAT, &format);
  static struct retro_disk_control_ext_callback disk = {
      set_eject_state, get_eject_state, get_image_index, set_image_index, get_num_images,
      replace_image_index, add_image_index, set_initial_image, get_image_path, get_image_label,
  };
  environ_cb(RETRO_ENVIRONMENT_SET_DISK_CONTROL_EXT_INTERFACE, &disk);
  bool jit = false;
  if (environ_cb(RETRO_ENVIRONMENT_GET_JIT_CAPABLE, &jit)) jit_capable = jit;
  memset(init_report, 0, sizeof(init_report));
  read_option("neotest_init", init_report);
  read_option("neotest_locked", init_report + 16);
  read_option("neotest_default", init_report + 32);
  read_option("neotest_mode", init_report + 48);
}

RETRO_API void retro_deinit(void) {
  if (hardware_context && log_cb) log_cb(RETRO_LOG_INFO, "neotest deinit interface=%d\n", interface_available());
  hardware_context = false;
}
RETRO_API unsigned retro_api_version(void) { return RETRO_API_VERSION; }

RETRO_API void retro_get_system_info(struct retro_system_info *info) {
  memset(info, 0, sizeof(*info));
  info->library_name = "NeoTest";
  info->library_version = "1.0";
  info->valid_extensions = "ntc|bin";
  info->need_fullpath = false;
}

RETRO_API void retro_get_system_av_info(struct retro_system_av_info *info) {
  memset(info, 0, sizeof(*info));
  info->geometry.base_width = 320;
  info->geometry.base_height = 240;
  info->geometry.max_width = 320;
  info->geometry.max_height = 240;
  info->geometry.aspect_ratio = 4.0f / 3.0f;
  info->timing.fps = 60.0;
  info->timing.sample_rate = 48000.0;
}

RETRO_API void retro_set_controller_port_device(unsigned port, unsigned device) {}

RETRO_API void retro_reset(void) { frame_counter = 0; }

RETRO_API void retro_run(void) {
  if (first_frame) {
    restored_marker = save_ram[1];
    first_frame = false;
  }
  bool updated = false;
  if (environ_cb(RETRO_ENVIRONMENT_GET_VARIABLE_UPDATE, &updated) && updated) {
    read_option("neotest_init", init_report + 64);
    init_report[80]++;
  }
  input_poll_cb();
  int16_t buttons = input_state_cb(0, RETRO_DEVICE_JOYPAD, 0, RETRO_DEVICE_ID_JOYPAD_MASK);
  frame_counter++;
  if (shutdown_frame != 0 && frame_counter == shutdown_frame) {
    if (log_cb) log_cb(RETRO_LOG_ERROR, "neotest boot failed: simulated\n");
    environ_cb(RETRO_ENVIRONMENT_SHUTDOWN, NULL);
  }
  for (unsigned index = 0; index < 320 * 240; index++) framebuffer[index] = frame_counter;
  framebuffer[1] = restored_marker;
  save_ram[0] = (uint8_t)frame_counter;
  save_ram[1] = 0x5A;
  save_ram[2] = (uint8_t)option_value[0];
  save_ram[3] = jit_capable ? 1 : 0;
  save_ram[4] = (uint8_t)cheat_count;
  save_ram[5] = (uint8_t)disk_index;
  memcpy(save_ram + 6, &content_checksum, sizeof(content_checksum));
  save_ram[10] = (uint8_t)(buttons & 0xFF);
  video_cb(framebuffer, 320, 240, 320 * sizeof(uint32_t));
  audio_batch_cb(audio, 800);
}

RETRO_API size_t retro_serialize_size(void) { return 8; }

RETRO_API bool retro_serialize(void *data, size_t size) {
  if (size < 8) return false;
  memcpy(data, &frame_counter, 4);
  memcpy((uint8_t *)data + 4, &content_checksum, 4);
  return true;
}

RETRO_API bool retro_unserialize(const void *data, size_t size) {
  if (size != 8) return false;
  memcpy(&frame_counter, data, 4);
  return true;
}

RETRO_API void retro_cheat_reset(void) { cheat_count = 0; }
RETRO_API void retro_cheat_set(unsigned index, bool enabled, const char *code) {
  if (enabled && code != NULL && code[0] != '\0') cheat_count++;
}

RETRO_API bool retro_load_game(const struct retro_game_info *game) {
  if (game == NULL || game->data == NULL || game->size == 0) return false;
  content_checksum = 0;
  for (size_t index = 0; index < game->size; index++) content_checksum += ((const uint8_t *)game->data)[index];
  struct retro_variable variable = {"neotest_mode", NULL};
  if (environ_cb(RETRO_ENVIRONMENT_GET_VARIABLE, &variable) && variable.value != NULL) {
    snprintf(option_value, sizeof(option_value), "%s", variable.value);
  }
  shutdown_frame = option_is("neotest_shutdown_frame", "3") ? 3 : 0;
  hardware_context = false;
  if (option_is("neotest_hw", "on")) {
    static struct retro_hw_render_callback hw;
    memset(&hw, 0, sizeof(hw));
    hw.context_type = RETRO_HW_CONTEXT_OPENGLES3;
    hw.context_reset = context_reset;
    hw.context_destroy = context_destroy;
    if (!environ_cb(RETRO_ENVIRONMENT_SET_HW_RENDER, &hw)) return false;
    hardware_context = true;
  }
  return true;
}

RETRO_API bool retro_load_game_special(unsigned type, const struct retro_game_info *info, size_t count) {
  return false;
}

RETRO_API void retro_unload_game(void) {
  if (hardware_context && log_cb) log_cb(RETRO_LOG_INFO, "neotest unload_game interface=%d\n", interface_available());
}
RETRO_API unsigned retro_get_region(void) { return RETRO_REGION_NTSC; }

RETRO_API void *retro_get_memory_data(unsigned id) {
  if (id == RETRO_MEMORY_SAVE_RAM) return save_ram;
  if (id == RETRO_MEMORY_SYSTEM_RAM) return init_report;
  return NULL;
}

RETRO_API size_t retro_get_memory_size(unsigned id) {
  if (id == RETRO_MEMORY_SAVE_RAM) return sizeof(save_ram);
  if (id == RETRO_MEMORY_SYSTEM_RAM) return sizeof(init_report);
  return 0;
}
