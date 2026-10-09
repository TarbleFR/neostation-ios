#import "LibretroCoreHost.h"

#import "LibretroCoreOptions.h"
#import "LibretroStateCodec.h"
#import "LibretroZipReader.h"

#include <dlfcn.h>
#include <mach/mach_time.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

NSErrorDomain const LibretroHostErrorDomain = @"org.neostation.libretro.host";

/// Experimental environment numbers have been promoted over time, so the
/// experimental bit is ignored when matching a call.
#define ENV_BASE(command) ((command) & ~RETRO_ENVIRONMENT_EXPERIMENTAL)

static const NSUInteger kRecentLogLimit = 200;

typedef struct {
  void (*retro_init)(void);
  void (*retro_deinit)(void);
  unsigned (*retro_api_version)(void);
  void (*retro_get_system_info)(struct retro_system_info *);
  void (*retro_get_system_av_info)(struct retro_system_av_info *);
  void (*retro_set_environment)(retro_environment_t);
  void (*retro_set_video_refresh)(retro_video_refresh_t);
  void (*retro_set_audio_sample)(retro_audio_sample_t);
  void (*retro_set_audio_sample_batch)(retro_audio_sample_batch_t);
  void (*retro_set_input_poll)(retro_input_poll_t);
  void (*retro_set_input_state)(retro_input_state_t);
  void (*retro_reset)(void);
  void (*retro_run)(void);
  size_t (*retro_serialize_size)(void);
  bool (*retro_serialize)(void *, size_t);
  bool (*retro_unserialize)(const void *, size_t);
  void (*retro_cheat_reset)(void);
  void (*retro_cheat_set)(unsigned, bool, const char *);
  bool (*retro_load_game)(const struct retro_game_info *);
  void (*retro_unload_game)(void);
  void *(*retro_get_memory_data)(unsigned);
  size_t (*retro_get_memory_size)(unsigned);
} LibretroSymbols;

static NSError *HostError(LibretroHostError code, NSString *detail) {
  return [NSError errorWithDomain:LibretroHostErrorDomain
                             code:code
                         userInfo:@{NSLocalizedDescriptionKey : detail ?: @""}];
}

static NSString *SafeFolderName(NSString *name) {
  NSCharacterSet *forbidden = [NSCharacterSet characterSetWithCharactersInString:@"/\\:"];
  NSString *safe = [[name componentsSeparatedByCharactersInSet:forbidden] componentsJoinedByString:@"_"];
  return safe.length > 0 ? safe : @"core";
}

static uint64_t MonotonicMicroseconds(void) {
  static mach_timebase_info_data_t timebase;
  if (timebase.denom == 0) mach_timebase_info(&timebase);
  return mach_absolute_time() * timebase.numer / timebase.denom / 1000ull;
}

/// The single host whose core is loaded; libretro callbacks have no
/// context argument. Owned elsewhere for the whole session.
static __unsafe_unretained LibretroCoreHost *gActiveHost = nil;

@implementation LibretroCoreHost {
  NSString *_corePath;
  NSString *_systemDirectory;
  NSString *_saveRoot;
  NSString *_stateRoot;
  NSString *_optionsDirectory;
  NSString *_cacheDirectory;
  NSString *_saveDirectory;
  NSString *_stateDirectory;
  unsigned _language;
  BOOL _jitCapable;

  void *_library;
  LibretroSymbols _symbols;
  BOOL _coreInitialized;
  BOOL _contentLoaded;

  char *_corePathC;
  char *_systemDirectoryC;
  char *_saveDirectoryC;

  struct retro_system_av_info _avInfo;
  enum retro_pixel_format _pixelFormat;
  unsigned _rotation;
  struct retro_hw_render_callback _hwRender;
  BOOL _usesHardwareRendering;

  struct retro_frame_time_callback _frameTime;
  BOOL _hasFrameTime;
  uint64_t _lastFrameMicroseconds;
  retro_audio_buffer_status_callback_t _audioStatus;

  struct retro_disk_control_ext_callback _disk;
  BOOL _hasDisk;

  struct retro_memory_descriptor *_memoryDescriptors;
  unsigned _memoryDescriptorCount;

  struct retro_system_content_info_override *_contentOverrides;
  unsigned _contentOverrideCount;

  LibretroInputSnapshot _input;

  int16_t *_audioBuffer;
  size_t _audioCount;
  size_t _audioCapacity;

  NSData *_contentData;
  struct retro_game_info_ext _gameInfoExt;
  BOOL _gameInfoExtReady;
  char *_gameInfoStrings[5];

  NSMutableArray<NSString *> *_log;
  BOOL _supportsAchievements;
  BOOL _shutdownRequested;
  uint64_t _serializationQuirks;
}

- (instancetype)initWithCorePath:(NSString *)corePath
                 systemDirectory:(NSString *)systemDirectory
                   saveDirectory:(NSString *)saveDirectory
                  stateDirectory:(NSString *)stateDirectory
                optionsDirectory:(NSString *)optionsDirectory
                  cacheDirectory:(NSString *)cacheDirectory
                        language:(unsigned)language
                      jitCapable:(BOOL)jitCapable {
  self = [super init];
  if (self) {
    _corePath = [corePath copy];
    _systemDirectory = [systemDirectory copy];
    _saveRoot = [saveDirectory copy];
    _stateRoot = [stateDirectory copy];
    _optionsDirectory = [optionsDirectory copy];
    _cacheDirectory = [cacheDirectory copy];
    _language = language;
    _jitCapable = jitCapable;
    _pixelFormat = RETRO_PIXEL_FORMAT_0RGB1555;
    _log = [NSMutableArray array];
    _libraryName = @"";
    _libraryVersion = @"";
    _validExtensions = [NSSet set];
  }
  return self;
}

- (void)dealloc {
  if (gActiveHost == self) gActiveHost = nil;
  if (_library != NULL) dlclose(_library);
  free(_corePathC);
  free(_systemDirectoryC);
  free(_saveDirectoryC);
  free(_audioBuffer);
  [self freeMemoryDescriptors];
  [self freeContentOverrides];
  [self freeGameInfoStrings];
}

#pragma mark - Logging

- (void)appendLog:(NSString *)line {
  @synchronized(_log) {
    [_log addObject:line];
    if (_log.count > kRecentLogLimit) [_log removeObjectsInRange:NSMakeRange(0, _log.count - kRecentLogLimit)];
  }
}

- (NSArray<NSString *> *)recentLog {
  @synchronized(_log) {
    return [_log copy];
  }
}

static void HostLog(enum retro_log_level level, const char *format, ...) {
  LibretroCoreHost *host = gActiveHost;
  if (host == nil || format == NULL) return;
  char buffer[1024];
  va_list arguments;
  va_start(arguments, format);
  vsnprintf(buffer, sizeof(buffer), format, arguments);
  va_end(arguments);
  size_t length = strlen(buffer);
  while (length > 0 && (buffer[length - 1] == '\n' || buffer[length - 1] == '\r')) buffer[--length] = '\0';
  static const char *const names[] = {"DEBUG", "INFO", "WARN", "ERROR"};
  const char *name = (unsigned)level < 4 ? names[level] : "LOG";
  NSString *line = [NSString stringWithFormat:@"[%s] %s", name, buffer];
  if (line == nil) return;
  [host appendLog:line];
  if (level >= RETRO_LOG_WARN) NSLog(@"[Libretro %@] %@", host.libraryName, line);
}

#pragma mark - Performance interface

static retro_time_t PerfTimeMicroseconds(void) { return (retro_time_t)MonotonicMicroseconds(); }

static uint64_t PerfCpuFeatures(void) { return RETRO_SIMD_NEON | RETRO_SIMD_ASIMD; }

static retro_perf_tick_t PerfCounter(void) { return mach_absolute_time(); }

static void PerfRegister(struct retro_perf_counter *counter) {
  if (counter != NULL) counter->registered = true;
}

static void PerfStart(struct retro_perf_counter *counter) {
  if (counter != NULL) counter->start = mach_absolute_time();
}

static void PerfStop(struct retro_perf_counter *counter) {
  if (counter == NULL) return;
  counter->total += mach_absolute_time() - counter->start;
  counter->call_cnt++;
}

static void PerfLog(void) {}

#pragma mark - Core callbacks

static void HostVideoRefresh(const void *data, unsigned width, unsigned height, size_t pitch) {
  LibretroCoreHost *host = gActiveHost;
  if (host == nil) return;
  [host->_delegate coreHost:host videoFrame:data width:width height:height pitch:pitch];
}

static void AppendAudio(LibretroCoreHost *host, const int16_t *data, size_t frames) {
  if (frames == 0 || data == NULL) return;
  size_t needed = host->_audioCount + frames;
  if (needed > host->_audioCapacity) {
    size_t capacity = host->_audioCapacity > 0 ? host->_audioCapacity * 2 : 8192;
    while (capacity < needed) capacity *= 2;
    int16_t *grown = realloc(host->_audioBuffer, capacity * 2 * sizeof(int16_t));
    if (grown == NULL) return;
    host->_audioBuffer = grown;
    host->_audioCapacity = capacity;
  }
  memcpy(host->_audioBuffer + host->_audioCount * 2, data, frames * 2 * sizeof(int16_t));
  host->_audioCount += frames;
}

static void HostAudioSample(int16_t left, int16_t right) {
  LibretroCoreHost *host = gActiveHost;
  if (host == nil) return;
  int16_t frame[2] = {left, right};
  AppendAudio(host, frame, 1);
}

static size_t HostAudioSampleBatch(const int16_t *data, size_t frames) {
  LibretroCoreHost *host = gActiveHost;
  if (host != nil) AppendAudio(host, data, frames);
  return frames;
}

static void HostInputPoll(void) {
  LibretroCoreHost *host = gActiveHost;
  if (host == nil) return;
  [host->_delegate coreHost:host fillInput:&host->_input];
}

static int16_t HostInputState(unsigned port, unsigned device, unsigned index, unsigned identifier) {
  LibretroCoreHost *host = gActiveHost;
  if (host == nil || port >= LIBRETRO_MAX_PORTS) return 0;
  const LibretroInputSnapshot *input = &host->_input;
  switch (device & RETRO_DEVICE_MASK) {
    case RETRO_DEVICE_JOYPAD:
      if (identifier == RETRO_DEVICE_ID_JOYPAD_MASK) return (int16_t)input->buttons[port];
      return identifier < 16 ? (int16_t)((input->buttons[port] >> identifier) & 1u) : 0;
    case RETRO_DEVICE_ANALOG:
      if (index == RETRO_DEVICE_INDEX_ANALOG_BUTTON) {
        return (identifier < 16 && ((input->buttons[port] >> identifier) & 1u)) ? 0x7fff : 0;
      }
      if (index < 2 && identifier < 2) return input->analog[port][index][identifier];
      return 0;
    case RETRO_DEVICE_POINTER:
      if (port != 0 || index != 0) return 0;
      switch (identifier) {
        case RETRO_DEVICE_ID_POINTER_X:
          return input->pointerX;
        case RETRO_DEVICE_ID_POINTER_Y:
          return input->pointerY;
        case RETRO_DEVICE_ID_POINTER_PRESSED:
          return input->pointerPressed ? 1 : 0;
        case RETRO_DEVICE_ID_POINTER_COUNT:
          return input->pointerPressed ? 1 : 0;
        default:
          return 0;
      }
    default:
      return 0;
  }
}

static bool HostRumble(unsigned port, enum retro_rumble_effect effect, uint16_t strength) {
  LibretroCoreHost *host = gActiveHost;
  if (host == nil) return false;
  id<LibretroCoreHostDelegate> delegate = host->_delegate;
  if ([delegate respondsToSelector:@selector(coreHost:rumblePort:effect:strength:)]) {
    [delegate coreHost:host rumblePort:port effect:effect strength:strength];
  }
  return true;
}

static void SetOutputString(void *data, const char *value) {
  if (data != NULL) *(const char **)data = value;
}

static bool HostEnvironment(unsigned command, void *data) {
  LibretroCoreHost *host = gActiveHost;
  if (host == nil || (command & RETRO_ENVIRONMENT_PRIVATE) != 0) return false;
  id<LibretroCoreHostDelegate> delegate = host->_delegate;
  switch (ENV_BASE(command)) {
    case RETRO_ENVIRONMENT_SET_ROTATION:
      if (data == NULL) return false;
      host->_rotation = *(const unsigned *)data % 4;
      if ([delegate respondsToSelector:@selector(coreHost:rotationChanged:)]) {
        [delegate coreHost:host rotationChanged:host->_rotation];
      }
      return true;
    case RETRO_ENVIRONMENT_GET_OVERSCAN:
      if (data != NULL) *(bool *)data = false;
      return true;
    case RETRO_ENVIRONMENT_GET_CAN_DUPE:
      if (data != NULL) *(bool *)data = true;
      return true;
    case RETRO_ENVIRONMENT_SET_MESSAGE: {
      const struct retro_message *message = data;
      if (message != NULL && message->msg != NULL) {
        NSString *text = [NSString stringWithUTF8String:message->msg] ?: @"";
        [host appendLog:[@"[MSG] " stringByAppendingString:text]];
        if ([delegate respondsToSelector:@selector(coreHost:message:durationMilliseconds:)]) {
          [delegate coreHost:host message:text durationMilliseconds:message->frames * 1000u / 60u];
        }
      }
      return true;
    }
    case RETRO_ENVIRONMENT_SHUTDOWN:
      host->_shutdownRequested = YES;
      if ([delegate respondsToSelector:@selector(coreHostRequestedShutdown:)]) {
        [delegate coreHostRequestedShutdown:host];
      }
      return true;
    case RETRO_ENVIRONMENT_SET_PERFORMANCE_LEVEL:
      return true;
    case RETRO_ENVIRONMENT_GET_SYSTEM_DIRECTORY:
    case RETRO_ENVIRONMENT_GET_CORE_ASSETS_DIRECTORY:
      SetOutputString(data, host->_systemDirectoryC);
      return host->_systemDirectoryC != NULL;
    case RETRO_ENVIRONMENT_SET_PIXEL_FORMAT: {
      if (data == NULL) return false;
      enum retro_pixel_format format = *(const enum retro_pixel_format *)data;
      if (format != RETRO_PIXEL_FORMAT_0RGB1555 && format != RETRO_PIXEL_FORMAT_XRGB8888 &&
          format != RETRO_PIXEL_FORMAT_RGB565) {
        return false;
      }
      host->_pixelFormat = format;
      return true;
    }
    case RETRO_ENVIRONMENT_SET_INPUT_DESCRIPTORS:
    case RETRO_ENVIRONMENT_SET_KEYBOARD_CALLBACK:
    case RETRO_ENVIRONMENT_SET_SUPPORT_NO_GAME:
    case RETRO_ENVIRONMENT_SET_PROC_ADDRESS_CALLBACK:
    case RETRO_ENVIRONMENT_SET_SUBSYSTEM_INFO:
    case RETRO_ENVIRONMENT_SET_CONTROLLER_INFO:
    case ENV_BASE(RETRO_ENVIRONMENT_SET_HW_SHARED_CONTEXT):
    case RETRO_ENVIRONMENT_SET_MINIMUM_AUDIO_LATENCY:
      return true;
    case RETRO_ENVIRONMENT_SET_DISK_CONTROL_INTERFACE: {
      const struct retro_disk_control_callback *callback = data;
      if (callback == NULL) return false;
      memset(&host->_disk, 0, sizeof(host->_disk));
      host->_disk.set_eject_state = callback->set_eject_state;
      host->_disk.get_eject_state = callback->get_eject_state;
      host->_disk.get_image_index = callback->get_image_index;
      host->_disk.set_image_index = callback->set_image_index;
      host->_disk.get_num_images = callback->get_num_images;
      host->_disk.replace_image_index = callback->replace_image_index;
      host->_disk.add_image_index = callback->add_image_index;
      host->_hasDisk = YES;
      return true;
    }
    case RETRO_ENVIRONMENT_SET_DISK_CONTROL_EXT_INTERFACE: {
      const struct retro_disk_control_ext_callback *callback = data;
      if (callback == NULL) return false;
      host->_disk = *callback;
      host->_hasDisk = YES;
      return true;
    }
    case RETRO_ENVIRONMENT_GET_DISK_CONTROL_INTERFACE_VERSION:
      if (data != NULL) *(unsigned *)data = 1;
      return true;
    case RETRO_ENVIRONMENT_SET_HW_RENDER: {
      struct retro_hw_render_callback *callback = data;
      if (callback == NULL || ![delegate respondsToSelector:@selector(coreHost:prepareHardwareRender:)]) return false;
      if (![delegate coreHost:host prepareHardwareRender:callback]) {
        [host appendLog:[NSString stringWithFormat:@"[HOST] hardware context %u refused", callback->context_type]];
        return false;
      }
      host->_hwRender = *callback;
      host->_usesHardwareRendering = YES;
      return true;
    }
    case RETRO_ENVIRONMENT_GET_PREFERRED_HW_RENDER:
      if (data == NULL || ![delegate respondsToSelector:@selector(preferredHardwareContextForCoreHost:)]) return false;
      *(unsigned *)data = [delegate preferredHardwareContextForCoreHost:host];
      return true;
    case ENV_BASE(RETRO_ENVIRONMENT_GET_HW_RENDER_INTERFACE): {
      if (data == NULL || ![delegate respondsToSelector:@selector(hardwareRenderInterfaceForCoreHost:)]) return false;
      const struct retro_hw_render_interface *interface = [delegate hardwareRenderInterfaceForCoreHost:host];
      *(const struct retro_hw_render_interface **)data = interface;
      return interface != NULL;
    }
    case ENV_BASE(RETRO_ENVIRONMENT_SET_HW_RENDER_CONTEXT_NEGOTIATION_INTERFACE):
      if (data == NULL || ![delegate respondsToSelector:@selector(coreHost:setNegotiationInterface:)]) return false;
      return [delegate coreHost:host setNegotiationInterface:data];
    case ENV_BASE(RETRO_ENVIRONMENT_GET_HW_RENDER_CONTEXT_NEGOTIATION_INTERFACE_SUPPORT): {
      struct retro_hw_render_context_negotiation_interface *query = data;
      if (query == NULL) return false;
      unsigned version = 0;
      if ([delegate respondsToSelector:@selector(coreHost:negotiationVersionForType:)]) {
        version = [delegate coreHost:host negotiationVersionForType:query->interface_type];
      }
      query->interface_version = version;
      return true;
    }
    case RETRO_ENVIRONMENT_GET_VARIABLE: {
      struct retro_variable *variable = data;
      if (variable == NULL || variable->key == NULL) return false;
      variable->value = [host->_options valueForKey:variable->key];
      return variable->value != NULL;
    }
    case RETRO_ENVIRONMENT_SET_VARIABLES:
      return [host->_options declareVariables:data];
    case RETRO_ENVIRONMENT_GET_VARIABLE_UPDATE:
      if (data != NULL) *(bool *)data = [host->_options consumeUpdate];
      return true;
    case RETRO_ENVIRONMENT_SET_VARIABLE: {
      const struct retro_variable *variable = data;
      if (variable == NULL || variable->key == NULL) return true;
      if (variable->value == NULL) return false;
      NSString *key = [NSString stringWithUTF8String:variable->key];
      NSString *value = [NSString stringWithUTF8String:variable->value];
      if (key == nil || value == nil) return false;
      return [host->_options setValue:value forKey:key persist:NO];
    }
    case RETRO_ENVIRONMENT_GET_CORE_OPTIONS_VERSION:
      if (data != NULL) *(unsigned *)data = 2;
      return true;
    case RETRO_ENVIRONMENT_SET_CORE_OPTIONS:
      return [host->_options declareDefinitions:data local:NULL];
    case RETRO_ENVIRONMENT_SET_CORE_OPTIONS_INTL: {
      const struct retro_core_options_intl *intl = data;
      if (intl == NULL) return false;
      return [host->_options declareDefinitions:intl->us local:intl->local];
    }
    case RETRO_ENVIRONMENT_SET_CORE_OPTIONS_V2:
      return [host->_options declareV2:data local:NULL];
    case RETRO_ENVIRONMENT_SET_CORE_OPTIONS_V2_INTL: {
      const struct retro_core_options_v2_intl *intl = data;
      if (intl == NULL) return false;
      return [host->_options declareV2:intl->us local:intl->local];
    }
    case RETRO_ENVIRONMENT_SET_CORE_OPTIONS_DISPLAY:
      [host->_options setDisplay:data];
      return true;
    case RETRO_ENVIRONMENT_SET_CORE_OPTIONS_UPDATE_DISPLAY_CALLBACK: {
      const struct retro_core_options_update_display_callback *callback = data;
      host->_options.updateDisplayCallback = callback != NULL ? callback->callback : NULL;
      return true;
    }
    case RETRO_ENVIRONMENT_GET_LIBRETRO_PATH:
      SetOutputString(data, host->_corePathC);
      return host->_corePathC != NULL;
    case RETRO_ENVIRONMENT_SET_FRAME_TIME_CALLBACK: {
      const struct retro_frame_time_callback *callback = data;
      if (callback == NULL) return false;
      host->_frameTime = *callback;
      host->_hasFrameTime = callback->callback != NULL;
      host->_lastFrameMicroseconds = 0;
      return true;
    }
    case RETRO_ENVIRONMENT_GET_RUMBLE_INTERFACE: {
      struct retro_rumble_interface *rumble = data;
      if (rumble == NULL) return false;
      rumble->set_rumble_state = HostRumble;
      return true;
    }
    case RETRO_ENVIRONMENT_GET_INPUT_DEVICE_CAPABILITIES:
      if (data != NULL) {
        *(uint64_t *)data = (1ull << RETRO_DEVICE_JOYPAD) | (1ull << RETRO_DEVICE_ANALOG) | (1ull << RETRO_DEVICE_POINTER);
      }
      return true;
    case RETRO_ENVIRONMENT_GET_LOG_INTERFACE: {
      struct retro_log_callback *log = data;
      if (log == NULL) return false;
      log->log = HostLog;
      return true;
    }
    case RETRO_ENVIRONMENT_GET_PERF_INTERFACE: {
      struct retro_perf_callback *perf = data;
      if (perf == NULL) return false;
      perf->get_time_usec = PerfTimeMicroseconds;
      perf->get_cpu_features = PerfCpuFeatures;
      perf->get_perf_counter = PerfCounter;
      perf->perf_register = PerfRegister;
      perf->perf_start = PerfStart;
      perf->perf_stop = PerfStop;
      perf->perf_log = PerfLog;
      return true;
    }
    case RETRO_ENVIRONMENT_GET_SAVE_DIRECTORY:
      SetOutputString(data, host->_saveDirectoryC);
      return host->_saveDirectoryC != NULL;
    case RETRO_ENVIRONMENT_SET_SYSTEM_AV_INFO: {
      const struct retro_system_av_info *info = data;
      if (info == NULL) return false;
      host->_avInfo = *info;
      if ([delegate respondsToSelector:@selector(coreHost:timingChanged:)]) {
        [delegate coreHost:host timingChanged:host->_avInfo];
      }
      return true;
    }
    case ENV_BASE(RETRO_ENVIRONMENT_SET_MEMORY_MAPS):
      [host storeMemoryMap:data];
      return true;
    case RETRO_ENVIRONMENT_SET_GEOMETRY: {
      const struct retro_game_geometry *geometry = data;
      if (geometry == NULL) return false;
      host->_avInfo.geometry.base_width = geometry->base_width;
      host->_avInfo.geometry.base_height = geometry->base_height;
      host->_avInfo.geometry.aspect_ratio = geometry->aspect_ratio;
      if ([delegate respondsToSelector:@selector(coreHost:geometryChanged:)]) {
        [delegate coreHost:host geometryChanged:host->_avInfo.geometry];
      }
      return true;
    }
    case RETRO_ENVIRONMENT_GET_USERNAME:
      SetOutputString(data, "NeoStation");
      return true;
    case RETRO_ENVIRONMENT_GET_LANGUAGE:
      if (data != NULL) *(unsigned *)data = host->_language;
      return true;
    case ENV_BASE(RETRO_ENVIRONMENT_SET_SUPPORT_ACHIEVEMENTS):
      host->_supportsAchievements = data != NULL && *(const bool *)data;
      return true;
    case ENV_BASE(RETRO_ENVIRONMENT_GET_AUDIO_VIDEO_ENABLE):
      if (data != NULL) *(int *)data = 3;
      return true;
    case ENV_BASE(RETRO_ENVIRONMENT_GET_FASTFORWARDING):
      if (data != NULL) *(bool *)data = host->_fastForwarding;
      return true;
    case ENV_BASE(RETRO_ENVIRONMENT_GET_TARGET_REFRESH_RATE):
      if (data != NULL) *(float *)data = 60.0f;
      return true;
    case ENV_BASE(RETRO_ENVIRONMENT_GET_INPUT_BITMASKS):
      return true;
    case RETRO_ENVIRONMENT_GET_MESSAGE_INTERFACE_VERSION:
      if (data != NULL) *(unsigned *)data = 1;
      return true;
    case RETRO_ENVIRONMENT_SET_MESSAGE_EXT: {
      const struct retro_message_ext *message = data;
      if (message == NULL || message->msg == NULL) return false;
      NSString *text = [NSString stringWithUTF8String:message->msg] ?: @"";
      [host appendLog:[@"[MSG] " stringByAppendingString:text]];
      if (message->target != RETRO_MESSAGE_TARGET_LOG &&
          [delegate respondsToSelector:@selector(coreHost:message:durationMilliseconds:)]) {
        [delegate coreHost:host message:text durationMilliseconds:message->duration];
      }
      return true;
    }
    case RETRO_ENVIRONMENT_GET_INPUT_MAX_USERS:
      if (data != NULL) *(unsigned *)data = LIBRETRO_MAX_PORTS;
      return true;
    case RETRO_ENVIRONMENT_SET_AUDIO_BUFFER_STATUS_CALLBACK: {
      const struct retro_audio_buffer_status_callback *callback = data;
      host->_audioStatus = callback != NULL ? callback->callback : NULL;
      return true;
    }
    case RETRO_ENVIRONMENT_SET_CONTENT_INFO_OVERRIDE:
      if (data == NULL) return true;
      [host storeContentOverrides:data];
      return true;
    case RETRO_ENVIRONMENT_GET_GAME_INFO_EXT:
      if (data == NULL || !host->_gameInfoExtReady) return false;
      *(const struct retro_game_info_ext **)data = &host->_gameInfoExt;
      return true;
    case ENV_BASE(RETRO_ENVIRONMENT_GET_THROTTLE_STATE): {
      struct retro_throttle_state *throttle = data;
      if (throttle == NULL) return false;
      throttle->mode = host->_fastForwarding ? RETRO_THROTTLE_FAST_FORWARD : RETRO_THROTTLE_VSYNC;
      throttle->rate = (float)(host->_avInfo.timing.fps * (host->_fastForwarding ? 3.0 : 1.0));
      return true;
    }
    case ENV_BASE(RETRO_ENVIRONMENT_GET_SAVESTATE_CONTEXT):
      if (data != NULL) *(enum retro_savestate_context *)data = RETRO_SAVESTATE_CONTEXT_NORMAL;
      return true;
    case RETRO_ENVIRONMENT_GET_JIT_CAPABLE:
      if (data != NULL) *(bool *)data = host->_jitCapable;
      return true;
    case RETRO_ENVIRONMENT_SET_SERIALIZATION_QUIRKS:
      if (data != NULL) host->_serializationQuirks = *(const uint64_t *)data;
      return true;
    default:
      return false;
  }
}

#pragma mark - Core loading

- (BOOL)loadCore:(NSError **)error {
  if (gActiveHost != nil && gActiveHost != self) {
    if (error) *error = HostError(LibretroHostErrorCoreIncompatible, @"another libretro core is still loaded");
    return NO;
  }
  if (![[NSFileManager defaultManager] fileExistsAtPath:_corePath]) {
    if (error) *error = HostError(LibretroHostErrorCoreMissing, _corePath);
    return NO;
  }
  _library = dlopen(_corePath.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
  if (_library == NULL) {
    const char *reason = dlerror();
    if (error) *error = HostError(LibretroHostErrorCoreUnloadable, reason ? @(reason) : _corePath);
    return NO;
  }
#define LOAD_SYMBOL(name)                                                                          \
  do {                                                                                             \
    *(void **)(&_symbols.name) = dlsym(_library, #name);                                           \
    if (_symbols.name == NULL) {                                                                   \
      if (error) *error = HostError(LibretroHostErrorCoreIncompatible, @"missing symbol " @ #name); \
      dlclose(_library);                                                                           \
      _library = NULL;                                                                             \
      return NO;                                                                                   \
    }                                                                                              \
  } while (0)
  LOAD_SYMBOL(retro_init);
  LOAD_SYMBOL(retro_deinit);
  LOAD_SYMBOL(retro_api_version);
  LOAD_SYMBOL(retro_get_system_info);
  LOAD_SYMBOL(retro_get_system_av_info);
  LOAD_SYMBOL(retro_set_environment);
  LOAD_SYMBOL(retro_set_video_refresh);
  LOAD_SYMBOL(retro_set_audio_sample);
  LOAD_SYMBOL(retro_set_audio_sample_batch);
  LOAD_SYMBOL(retro_set_input_poll);
  LOAD_SYMBOL(retro_set_input_state);
  LOAD_SYMBOL(retro_reset);
  LOAD_SYMBOL(retro_run);
  LOAD_SYMBOL(retro_serialize_size);
  LOAD_SYMBOL(retro_serialize);
  LOAD_SYMBOL(retro_unserialize);
  LOAD_SYMBOL(retro_cheat_reset);
  LOAD_SYMBOL(retro_cheat_set);
  LOAD_SYMBOL(retro_load_game);
  LOAD_SYMBOL(retro_unload_game);
  LOAD_SYMBOL(retro_get_memory_data);
  LOAD_SYMBOL(retro_get_memory_size);
#undef LOAD_SYMBOL
  unsigned version = _symbols.retro_api_version();
  if (version != RETRO_API_VERSION) {
    if (error) {
      *error = HostError(LibretroHostErrorCoreIncompatible,
                         [NSString stringWithFormat:@"libretro API %u, expected %u", version, RETRO_API_VERSION]);
    }
    dlclose(_library);
    _library = NULL;
    return NO;
  }
  struct retro_system_info info;
  memset(&info, 0, sizeof(info));
  _symbols.retro_get_system_info(&info);
  _libraryName = info.library_name ? ([NSString stringWithUTF8String:info.library_name] ?: @"") : @"";
  if (_libraryName.length == 0) _libraryName = _corePath.lastPathComponent.stringByDeletingPathExtension;
  _libraryVersion = info.library_version ? ([NSString stringWithUTF8String:info.library_version] ?: @"") : @"";
  NSMutableSet<NSString *> *extensions = [NSMutableSet set];
  if (info.valid_extensions != NULL) {
    NSString *list = [NSString stringWithUTF8String:info.valid_extensions] ?: @"";
    for (NSString *extension in [list componentsSeparatedByString:@"|"]) {
      if (extension.length > 0) [extensions addObject:extension.lowercaseString];
    }
  }
  _validExtensions = [extensions copy];
  _needFullpath = info.need_fullpath;
  _blockExtract = info.block_extract;

  NSString *folder = SafeFolderName(_libraryName);
  _saveDirectory = [_saveRoot stringByAppendingPathComponent:folder];
  _stateDirectory = [_stateRoot stringByAppendingPathComponent:folder];
  NSFileManager *files = [NSFileManager defaultManager];
  for (NSString *directory in @[ _systemDirectory, _saveDirectory, _stateDirectory, _optionsDirectory, _cacheDirectory ]) {
    [files createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
  }
  _corePathC = strdup(_corePath.fileSystemRepresentation);
  _systemDirectoryC = strdup(_systemDirectory.fileSystemRepresentation);
  _saveDirectoryC = strdup(_saveDirectory.fileSystemRepresentation);
  NSString *optionsPath = [_optionsDirectory stringByAppendingPathComponent:[folder stringByAppendingPathExtension:@"json"]];
  _options = [[LibretroCoreOptions alloc] initWithStorePath:optionsPath];

  gActiveHost = self;
  _symbols.retro_set_environment(HostEnvironment);
  _symbols.retro_set_video_refresh(HostVideoRefresh);
  _symbols.retro_set_audio_sample(HostAudioSample);
  _symbols.retro_set_audio_sample_batch(HostAudioSampleBatch);
  _symbols.retro_set_input_poll(HostInputPoll);
  _symbols.retro_set_input_state(HostInputState);
  _symbols.retro_init();
  _coreInitialized = YES;
  [self appendLog:[NSString stringWithFormat:@"[HOST] loaded %@ %@", _libraryName, _libraryVersion]];
  return YES;
}

#pragma mark - Content

- (BOOL)contentNeedsFullpathForExtension:(NSString *)extension {
  for (unsigned index = 0; index < _contentOverrideCount; index++) {
    const char *list = _contentOverrides[index].extensions;
    if (list == NULL) continue;
    NSString *extensions = [NSString stringWithUTF8String:list] ?: @"";
    for (NSString *candidate in [extensions componentsSeparatedByString:@"|"]) {
      if ([candidate.lowercaseString isEqualToString:extension]) return _contentOverrides[index].need_fullpath;
    }
  }
  return _needFullpath;
}

- (BOOL)loadContentAtPath:(NSString *)path error:(NSError **)error {
  if (!_coreInitialized) {
    if (error) *error = HostError(LibretroHostErrorCoreUnloadable, @"core not loaded");
    return NO;
  }
  NSFileManager *files = [NSFileManager defaultManager];
  if (![files fileExistsAtPath:path]) {
    if (error) *error = HostError(LibretroHostErrorContentMissing, path);
    return NO;
  }
  _contentName = path.lastPathComponent.stringByDeletingPathExtension;
  NSString *contentPath = path;
  NSString *extension = path.pathExtension.lowercaseString;
  BOOL archive = [extension isEqualToString:@"zip"] || [extension isEqualToString:@"7z"];
  if (archive && !_blockExtract && ![_validExtensions containsObject:extension]) {
    if (![extension isEqualToString:@"zip"]) {
      if (error) *error = HostError(LibretroHostErrorContentUnsupported, extension);
      return NO;
    }
    NSString *directory = [[_cacheDirectory stringByAppendingPathComponent:@"Content"]
        stringByAppendingPathComponent:SafeFolderName(_contentName)];
    [files removeItemAtPath:directory error:nil];
    NSMutableSet<NSString *> *wanted = [_validExtensions mutableCopy];
    [wanted removeObject:@"zip"];
    [wanted removeObject:@"7z"];
    NSError *zipError = nil;
    NSString *extracted = [LibretroZipReader extractContentFromArchive:path
                                                            extensions:wanted
                                                           toDirectory:directory
                                                                 error:&zipError];
    if (extracted == nil) {
      if (error) *error = HostError(LibretroHostErrorContentUnsupported, zipError.localizedDescription);
      return NO;
    }
    contentPath = extracted;
    extension = extracted.pathExtension.lowercaseString;
  }
  BOOL fullpath = [self contentNeedsFullpathForExtension:extension];
  _contentData = nil;
  if (!fullpath) {
    NSError *readError = nil;
    _contentData = [NSData dataWithContentsOfFile:contentPath options:NSDataReadingMappedIfSafe error:&readError];
    if (_contentData == nil) {
      if (error) *error = HostError(LibretroHostErrorContentMissing, readError.localizedDescription ?: contentPath);
      return NO;
    }
  }
  [self prepareGameInfoExtForPath:contentPath extension:extension];
  struct retro_game_info game;
  memset(&game, 0, sizeof(game));
  game.path = contentPath.fileSystemRepresentation;
  game.data = _contentData.bytes;
  game.size = _contentData.length;
  game.meta = NULL;
  if (!_symbols.retro_load_game(&game)) {
    _gameInfoExtReady = NO;
    if (error) *error = HostError(LibretroHostErrorContentRejected, contentPath.lastPathComponent);
    return NO;
  }
  _contentLoaded = YES;
  _loadedContentPath = [contentPath copy];
  memset(&_avInfo, 0, sizeof(_avInfo));
  _symbols.retro_get_system_av_info(&_avInfo);
  if (_avInfo.timing.fps <= 0) _avInfo.timing.fps = 60.0;
  if (_avInfo.timing.sample_rate <= 0) _avInfo.timing.sample_rate = 44100.0;
  _saveRAMPath = [_saveDirectory stringByAppendingPathComponent:[_contentName stringByAppendingPathExtension:@"srm"]];
  [self loadMemory:RETRO_MEMORY_SAVE_RAM fromPath:_saveRAMPath];
  [self loadMemory:RETRO_MEMORY_RTC
          fromPath:[_saveDirectory stringByAppendingPathComponent:[_contentName stringByAppendingPathExtension:@"rtc"]]];
  [self appendLog:[NSString stringWithFormat:@"[HOST] content %@ %ux%u %.3f fps %.0f Hz", contentPath.lastPathComponent,
                                             _avInfo.geometry.base_width, _avInfo.geometry.base_height,
                                             _avInfo.timing.fps, _avInfo.timing.sample_rate]];
  return YES;
}

- (void)prepareGameInfoExtForPath:(NSString *)path extension:(NSString *)extension {
  [self freeGameInfoStrings];
  _gameInfoStrings[0] = strdup(path.fileSystemRepresentation);
  _gameInfoStrings[1] = strdup(path.stringByDeletingLastPathComponent.fileSystemRepresentation);
  _gameInfoStrings[2] = strdup((path.lastPathComponent.stringByDeletingPathExtension ?: @"").UTF8String);
  _gameInfoStrings[3] = strdup((extension ?: @"").UTF8String);
  memset(&_gameInfoExt, 0, sizeof(_gameInfoExt));
  _gameInfoExt.full_path = _gameInfoStrings[0];
  _gameInfoExt.dir = _gameInfoStrings[1];
  _gameInfoExt.name = _gameInfoStrings[2];
  _gameInfoExt.ext = _gameInfoStrings[3];
  _gameInfoExt.data = _contentData.bytes;
  _gameInfoExt.size = _contentData.length;
  _gameInfoExt.file_in_archive = false;
  _gameInfoExt.persistent_data = _contentData != nil;
  _gameInfoExtReady = YES;
}

- (void)freeGameInfoStrings {
  for (unsigned index = 0; index < 5; index++) {
    free(_gameInfoStrings[index]);
    _gameInfoStrings[index] = NULL;
  }
  _gameInfoExtReady = NO;
}

- (void)storeContentOverrides:(const struct retro_system_content_info_override *)overrides {
  [self freeContentOverrides];
  unsigned count = 0;
  while (overrides[count].extensions != NULL) count++;
  if (count == 0) return;
  _contentOverrides = calloc(count, sizeof(*_contentOverrides));
  if (_contentOverrides == NULL) return;
  for (unsigned index = 0; index < count; index++) {
    _contentOverrides[index] = overrides[index];
    _contentOverrides[index].extensions = strdup(overrides[index].extensions);
  }
  _contentOverrideCount = count;
}

- (void)freeContentOverrides {
  for (unsigned index = 0; index < _contentOverrideCount; index++) free((void *)_contentOverrides[index].extensions);
  free(_contentOverrides);
  _contentOverrides = NULL;
  _contentOverrideCount = 0;
}

- (void)storeMemoryMap:(const struct retro_memory_map *)map {
  [self freeMemoryDescriptors];
  if (map == NULL || map->descriptors == NULL || map->num_descriptors == 0) return;
  _memoryDescriptors = calloc(map->num_descriptors, sizeof(struct retro_memory_descriptor));
  if (_memoryDescriptors == NULL) return;
  for (unsigned index = 0; index < map->num_descriptors; index++) {
    _memoryDescriptors[index] = map->descriptors[index];
    if (map->descriptors[index].addrspace != NULL) {
      _memoryDescriptors[index].addrspace = strdup(map->descriptors[index].addrspace);
    }
  }
  _memoryDescriptorCount = map->num_descriptors;
}

- (void)freeMemoryDescriptors {
  for (unsigned index = 0; index < _memoryDescriptorCount; index++) free((void *)_memoryDescriptors[index].addrspace);
  free(_memoryDescriptors);
  _memoryDescriptors = NULL;
  _memoryDescriptorCount = 0;
}

- (const struct retro_memory_descriptor *)memoryDescriptors:(unsigned *)count {
  if (count != NULL) *count = _memoryDescriptorCount;
  return _memoryDescriptors;
}

- (void *)memoryDataForIdentifier:(unsigned)identifier size:(size_t *)size {
  if (!_contentLoaded) {
    if (size != NULL) *size = 0;
    return NULL;
  }
  if (size != NULL) *size = _symbols.retro_get_memory_size(identifier);
  return _symbols.retro_get_memory_data(identifier);
}

#pragma mark - Save RAM

- (void)loadMemory:(unsigned)identifier fromPath:(NSString *)path {
  size_t size = _symbols.retro_get_memory_size(identifier);
  void *memory = _symbols.retro_get_memory_data(identifier);
  if (size == 0 || memory == NULL) return;
  NSData *file = [NSData dataWithContentsOfFile:path];
  if (file == nil) return;
  NSData *payload = [LibretroStateCodec decompressRzipIfNeeded:file error:nil];
  if (payload == nil) return;
  memcpy(memory, payload.bytes, MIN(size, payload.length));
  [self appendLog:[NSString stringWithFormat:@"[HOST] restored %@", path.lastPathComponent]];
}

- (BOOL)writeMemory:(unsigned)identifier toPath:(NSString *)path error:(NSError **)error {
  size_t size = _symbols.retro_get_memory_size(identifier);
  void *memory = _symbols.retro_get_memory_data(identifier);
  if (size == 0 || memory == NULL) return YES;
  NSData *payload = [NSData dataWithBytes:memory length:size];
  NSError *writeError = nil;
  if (![payload writeToFile:path options:NSDataWritingAtomic error:&writeError]) {
    if (error) *error = HostError(LibretroHostErrorSaveFailed, writeError.localizedDescription ?: path);
    return NO;
  }
  return YES;
}

- (BOOL)flushSaveRAM:(NSError **)error {
  if (!_contentLoaded || _saveRAMPath == nil) return YES;
  if (![self writeMemory:RETRO_MEMORY_SAVE_RAM toPath:_saveRAMPath error:error]) return NO;
  NSString *rtc = [_saveDirectory stringByAppendingPathComponent:[_contentName stringByAppendingPathExtension:@"rtc"]];
  return [self writeMemory:RETRO_MEMORY_RTC toPath:rtc error:error];
}

#pragma mark - Running

- (void)hardwareContextReset {
  if (_usesHardwareRendering && _hwRender.context_reset != NULL) _hwRender.context_reset();
}

- (void)hardwareContextDestroy {
  if (_usesHardwareRendering && _hwRender.context_destroy != NULL) _hwRender.context_destroy();
}

- (void)runFrame {
  if (!_contentLoaded) return;
  if (_hasFrameTime) {
    uint64_t now = MonotonicMicroseconds();
    retro_usec_t reference = _frameTime.reference > 0 ? _frameTime.reference
                                                       : (retro_usec_t)(1000000.0 / _avInfo.timing.fps);
    retro_usec_t delta = _lastFrameMicroseconds == 0 ? reference : (retro_usec_t)(now - _lastFrameMicroseconds);
    if (delta < reference / 4 || delta > reference * 4) delta = reference;
    _lastFrameMicroseconds = now;
    _frameTime.callback(delta);
  }
  if (_audioStatus != NULL) {
    unsigned occupancy = 50;
    id<LibretroCoreHostDelegate> delegate = _delegate;
    if ([delegate respondsToSelector:@selector(audioBufferOccupancyForCoreHost:)]) {
      occupancy = MIN(100u, [delegate audioBufferOccupancyForCoreHost:self]);
    }
    _audioStatus(true, occupancy, occupancy < 25);
  }
  _audioCount = 0;
  _symbols.retro_run();
  if (_audioCount > 0) [_delegate coreHost:self audioFrames:_audioBuffer count:_audioCount];
}

- (void)resetContent {
  if (_contentLoaded) _symbols.retro_reset();
}

#pragma mark - Save states

- (NSString *)statePathForSlot:(NSInteger)slot {
  NSString *name = _contentName ?: @"content";
  NSString *extension = slot <= 0 ? @"state" : [NSString stringWithFormat:@"state%ld", (long)slot];
  return [_stateDirectory stringByAppendingPathComponent:[name stringByAppendingPathExtension:extension]];
}

- (NSData *)serializeState:(NSError **)error {
  if (!_contentLoaded) {
    if (error) *error = HostError(LibretroHostErrorStateUnavailable, @"no content");
    return nil;
  }
  size_t size = _symbols.retro_serialize_size();
  if (size == 0) {
    if (error) *error = HostError(LibretroHostErrorStateUnavailable, @"core does not serialize");
    return nil;
  }
  NSMutableData *state = [NSMutableData dataWithLength:size];
  if (!_symbols.retro_serialize(state.mutableBytes, size)) {
    if (error) *error = HostError(LibretroHostErrorStateUnavailable, @"retro_serialize failed");
    return nil;
  }
  return state;
}

- (BOOL)unserializeState:(NSData *)state error:(NSError **)error {
  if (!_contentLoaded || state.length == 0) {
    if (error) *error = HostError(LibretroHostErrorStateRejected, @"no content or empty state");
    return NO;
  }
  if (!_symbols.retro_unserialize(state.bytes, state.length)) {
    if (error) *error = HostError(LibretroHostErrorStateRejected, @"retro_unserialize failed");
    return NO;
  }
  return YES;
}

- (BOOL)saveStateToSlot:(NSInteger)slot error:(NSError **)error {
  NSData *state = [self serializeState:error];
  if (state == nil) return NO;
  NSData *container = [LibretroStateCodec containerForCoreState:state];
  NSError *writeError = nil;
  if (![container writeToFile:[self statePathForSlot:slot] options:NSDataWritingAtomic error:&writeError]) {
    if (error) *error = HostError(LibretroHostErrorSaveFailed, writeError.localizedDescription);
    return NO;
  }
  return YES;
}

- (BOOL)loadStateFromSlot:(NSInteger)slot error:(NSError **)error {
  NSData *file = [NSData dataWithContentsOfFile:[self statePathForSlot:slot]];
  if (file == nil) {
    if (error) *error = HostError(LibretroHostErrorStateUnavailable, @"no state in slot");
    return NO;
  }
  NSError *decodeError = nil;
  NSData *state = [LibretroStateCodec coreStateFromFileData:file error:&decodeError];
  if (state == nil) {
    if (error) *error = HostError(LibretroHostErrorStateRejected, decodeError.localizedDescription);
    return NO;
  }
  return [self unserializeState:state error:error];
}

#pragma mark - Disk control and cheats

- (BOOL)supportsDiskControl {
  return _hasDisk && _disk.get_num_images != NULL && _disk.set_image_index != NULL;
}

- (unsigned)diskCount {
  return self.supportsDiskControl ? _disk.get_num_images() : 0;
}

- (unsigned)diskIndex {
  return self.supportsDiskControl && _disk.get_image_index != NULL ? _disk.get_image_index() : 0;
}

- (BOOL)selectDisk:(unsigned)index {
  if (!self.supportsDiskControl || index >= self.diskCount) return NO;
  if (_disk.set_eject_state != NULL) _disk.set_eject_state(true);
  bool selected = _disk.set_image_index(index);
  if (_disk.set_eject_state != NULL) _disk.set_eject_state(false);
  return selected;
}

- (NSString *)labelForDisk:(unsigned)index {
  if (_disk.get_image_label == NULL) return nil;
  char label[256] = {0};
  if (!_disk.get_image_label(index, label, sizeof(label)) || label[0] == '\0') return nil;
  return [NSString stringWithUTF8String:label];
}

- (void)applyCheats:(NSArray<NSString *> *)codes {
  if (!_contentLoaded) return;
  _symbols.retro_cheat_reset();
  unsigned index = 0;
  for (NSString *code in codes) {
    if (code.length == 0) continue;
    _symbols.retro_cheat_set(index++, true, code.UTF8String);
  }
}

#pragma mark - Unloading

- (void)unloadWithHardwareTeardown:(void (^)(void))beforeUnload {
  if (_contentLoaded) [self flushSaveRAM:nil];
  if (beforeUnload != nil) beforeUnload();
  if (_contentLoaded) {
    _symbols.retro_unload_game();
    _contentLoaded = NO;
  }
  if (_coreInitialized) {
    _symbols.retro_deinit();
    _coreInitialized = NO;
  }
  [_options save];
  if (gActiveHost == self) gActiveHost = nil;
  if (_library != NULL) {
    dlclose(_library);
    _library = NULL;
  }
  memset(&_symbols, 0, sizeof(_symbols));
  _contentData = nil;
  _usesHardwareRendering = NO;
  _hasDisk = NO;
  _hasFrameTime = NO;
  _audioStatus = NULL;
  [self freeGameInfoStrings];
  [self freeMemoryDescriptors];
  [self freeContentOverrides];
  [self appendLog:@"[HOST] unloaded"];
}

@end
