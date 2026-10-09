#import <Foundation/Foundation.h>

#include "libretro.h"

@class LibretroCoreOptions;

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSErrorDomain const LibretroHostErrorDomain;

/// Stable codes Dart maps to translated messages; the technical detail
/// stays in NSLocalizedDescriptionKey.
typedef NS_ERROR_ENUM(LibretroHostErrorDomain, LibretroHostError) {
  LibretroHostErrorCoreMissing = 1,
  LibretroHostErrorCoreUnloadable = 2,
  LibretroHostErrorCoreIncompatible = 3,
  LibretroHostErrorContentMissing = 4,
  LibretroHostErrorContentUnsupported = 5,
  LibretroHostErrorContentRejected = 6,
  LibretroHostErrorStateUnavailable = 7,
  LibretroHostErrorStateRejected = 8,
  LibretroHostErrorSaveFailed = 9,
  LibretroHostErrorHardwareRenderUnavailable = 10,
  LibretroHostErrorBiosMissing = 11,
};

#define LIBRETRO_MAX_PORTS 4

/// Input state filled by the platform layer once per input poll and read
/// by the core through retro_input_state_t without leaving C.
typedef struct {
  uint16_t buttons[LIBRETRO_MAX_PORTS];
  int16_t analog[LIBRETRO_MAX_PORTS][2][2];
  int16_t pointerX;
  int16_t pointerY;
  bool pointerPressed;
} LibretroInputSnapshot;

@class LibretroCoreHost;

@protocol LibretroCoreHostDelegate <NSObject>
/// `data` is NULL for a duplicated frame and RETRO_HW_FRAME_BUFFER_VALID
/// for a frame rendered through the hardware context.
- (void)coreHost:(LibretroCoreHost *)host
    videoFrame:(const void *_Nullable)data
         width:(unsigned)width
        height:(unsigned)height
         pitch:(size_t)pitch;
- (void)coreHost:(LibretroCoreHost *)host audioFrames:(const int16_t *)frames count:(size_t)count;
- (void)coreHost:(LibretroCoreHost *)host fillInput:(LibretroInputSnapshot *)snapshot;
@optional
/// Called for SET_HW_RENDER. Returns NO for an unsupported context type;
/// on YES the receiver has filled get_current_framebuffer and
/// get_proc_address in `callback`.
- (BOOL)coreHost:(LibretroCoreHost *)host prepareHardwareRender:(struct retro_hw_render_callback *)callback;
- (unsigned)preferredHardwareContextForCoreHost:(LibretroCoreHost *)host;
- (const struct retro_hw_render_interface *_Nullable)hardwareRenderInterfaceForCoreHost:(LibretroCoreHost *)host;
- (BOOL)coreHost:(LibretroCoreHost *)host
    setNegotiationInterface:(const struct retro_hw_render_context_negotiation_interface *)negotiation;
- (unsigned)coreHost:(LibretroCoreHost *)host
    negotiationVersionForType:(enum retro_hw_render_context_negotiation_interface_type)type;
- (void)coreHost:(LibretroCoreHost *)host geometryChanged:(struct retro_game_geometry)geometry;
- (void)coreHost:(LibretroCoreHost *)host timingChanged:(struct retro_system_av_info)avInfo;
- (void)coreHost:(LibretroCoreHost *)host rotationChanged:(unsigned)rotation;
- (void)coreHost:(LibretroCoreHost *)host
    rumblePort:(unsigned)port
        effect:(enum retro_rumble_effect)effect
      strength:(uint16_t)strength;
- (void)coreHost:(LibretroCoreHost *)host message:(NSString *)message durationMilliseconds:(unsigned)duration;
- (void)coreHostRequestedShutdown:(LibretroCoreHost *)host;
- (unsigned)audioBufferOccupancyForCoreHost:(LibretroCoreHost *)host;
@end

/// Portable libretro frontend core: loads one core library, answers its
/// environment calls, feeds it content and input, and owns save RAM and
/// save states. Platform presentation (Metal, audio output, controllers,
/// hardware contexts) lives in the delegate. Only one host may have a core
/// loaded at a time because libretro callbacks carry no context pointer.
@interface LibretroCoreHost : NSObject

- (instancetype)initWithCorePath:(NSString *)corePath
                 systemDirectory:(NSString *)systemDirectory
                   saveDirectory:(NSString *)saveDirectory
                  stateDirectory:(NSString *)stateDirectory
                optionsDirectory:(NSString *)optionsDirectory
                  cacheDirectory:(NSString *)cacheDirectory
                        language:(unsigned)language
                      jitCapable:(BOOL)jitCapable NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@property(nonatomic, weak, nullable) id<LibretroCoreHostDelegate> delegate;

/// Option values given to the option store by `loadCore:` right after it is
/// created, BEFORE retro_set_environment and retro_init: some cores
/// (DeSmuME) read their options only in retro_init. Set them before
/// `loadCore:`.
/// - `initialOptionDefaults`: NeoStation defaults (used while the user has
///   stored no value);
/// - `initialSessionOverrides`: session values that win over stored ones
///   (no-JIT interpreters);
/// - `lockedSessionOverrides`: session values the user cannot change during
///   this session (screen layout and pointer type NeoStation needs to crop
///   the DS / 3DS screens); `setValue:forKey:persist:` refuses those keys.
@property(nonatomic, copy, nullable) NSDictionary<NSString *, NSString *> *initialOptionDefaults;
@property(nonatomic, copy, nullable) NSDictionary<NSString *, NSString *> *initialSessionOverrides;
@property(nonatomic, copy, nullable) NSDictionary<NSString *, NSString *> *lockedSessionOverrides;

/// dlopen, symbol resolution, API version check, callbacks, retro_init.
- (BOOL)loadCore:(NSError *_Nullable *_Nullable)error;

@property(nonatomic, copy, readonly) NSString *libraryName;
@property(nonatomic, copy, readonly) NSString *libraryVersion;
@property(nonatomic, copy, readonly) NSSet<NSString *> *validExtensions;
@property(nonatomic, readonly) BOOL needFullpath;
@property(nonatomic, readonly) BOOL blockExtract;
@property(nonatomic, readonly, nullable) LibretroCoreOptions *options;

/// Extracts archives when needed, loads the content, then save RAM.
- (BOOL)loadContentAtPath:(NSString *)path error:(NSError *_Nullable *_Nullable)error;

@property(nonatomic, readonly) struct retro_system_av_info avInfo;
@property(nonatomic, readonly) enum retro_pixel_format pixelFormat;
@property(nonatomic, readonly) unsigned rotation;
@property(nonatomic, readonly) BOOL usesHardwareRendering;
@property(nonatomic, readonly) struct retro_hw_render_callback hardwareRender;
@property(nonatomic, copy, readonly, nullable) NSString *contentName;
/// Path handed to the core: the extracted file when the content was zipped.
@property(nonatomic, copy, readonly, nullable) NSString *loadedContentPath;
@property(nonatomic, copy, readonly, nullable) NSString *saveRAMPath;
@property(nonatomic, assign) BOOL fastForwarding;
@property(nonatomic, readonly) BOOL shutdownRequested;
@property(nonatomic, readonly) BOOL supportsAchievements;

/// Calls the core's context_reset / context_destroy for its hardware context.
- (void)hardwareContextReset;
- (void)hardwareContextDestroy;

- (void)runFrame;
- (void)resetContent;

- (NSString *)statePathForSlot:(NSInteger)slot;
- (BOOL)saveStateToSlot:(NSInteger)slot error:(NSError *_Nullable *_Nullable)error;
- (BOOL)loadStateFromSlot:(NSInteger)slot error:(NSError *_Nullable *_Nullable)error;
- (nullable NSData *)serializeState:(NSError *_Nullable *_Nullable)error;
- (BOOL)unserializeState:(NSData *)state error:(NSError *_Nullable *_Nullable)error;

- (BOOL)flushSaveRAM:(NSError *_Nullable *_Nullable)error;

/// Writes save RAM, then retro_unload_game, retro_deinit and dlclose.
/// `beforeUnload` runs first so a hardware context can be torn down while
/// the core is still loaded.
- (void)unloadWithHardwareTeardown:(void (^_Nullable)(void))beforeUnload;

@property(nonatomic, readonly) BOOL supportsDiskControl;
@property(nonatomic, readonly) unsigned diskCount;
@property(nonatomic, readonly) unsigned diskIndex;
- (BOOL)selectDisk:(unsigned)index;
- (nullable NSString *)labelForDisk:(unsigned)index;

- (void)applyCheats:(NSArray<NSString *> *)codes;

- (void *_Nullable)memoryDataForIdentifier:(unsigned)identifier size:(size_t *)size;
- (const struct retro_memory_descriptor *_Nullable)memoryDescriptors:(unsigned *)count;

@property(nonatomic, copy, readonly) NSArray<NSString *> *recentLog;

@end

NS_ASSUME_NONNULL_END
