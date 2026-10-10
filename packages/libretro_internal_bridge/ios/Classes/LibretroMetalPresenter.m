#import "LibretroMetalPresenter.h"

#import "LibretroShaderLibrary.h"

#include <math.h>
#include <os/lock.h>
#include <simd/simd.h>
#include <stdlib.h>
#include <string.h>

/// Command buffers kept in flight on the layer, and upload textures per
/// pixel format.
#define LIBRETRO_FRAMES_IN_FLIGHT 3
/// Pixel formats of uploaded frames: BGRA8Unorm (software frames, Vulkan),
/// RGBA8Unorm, RGB10A2Unorm and BGR10A2Unorm (Vulkan).
#define LIBRETRO_UPLOAD_FORMATS 4
#define LIBRETRO_UPLOAD_SLOTS (LIBRETRO_UPLOAD_FORMATS * LIBRETRO_FRAMES_IN_FLIGHT)
/// Window of the GPU time median, and cap of one measurement.
#define LIBRETRO_GPU_SAMPLES 120
/// LibretroShaderUniforms.parameters.
#define LIBRETRO_SHADER_SLOTS 16
/// Largest 2D texture of the Apple GPUs NeoStation runs on.
#define LIBRETRO_MAX_TEXTURE_SIZE 16384

/// Diagnostics only (session log); never shown to the user.
static NSString *const kLibretroPresenterErrorDomain = @"LibretroMetalPresenter";

typedef NS_ENUM(NSInteger, LibretroPresenterErrorCode) {
  LibretroPresenterErrorCompilation = 1,
  LibretroPresenterErrorMissingFunction = 2,
  LibretroPresenterErrorPipeline = 3,
};

static inline uint8_t Expand5(uint32_t value) { return (uint8_t)((value << 3) | (value >> 2)); }
static inline uint8_t Expand6(uint32_t value) { return (uint8_t)((value << 2) | (value >> 4)); }

/// Index of an upload pixel format, -1 when the presenter cannot sample it.
static NSInteger UploadFormatIndex(MTLPixelFormat format) {
  switch (format) {
    case MTLPixelFormatBGRA8Unorm:
      return 0;
    case MTLPixelFormatRGBA8Unorm:
      return 1;
    case MTLPixelFormatRGB10A2Unorm:
      return 2;
    case MTLPixelFormatBGR10A2Unorm:
      return 3;
    default:
      return -1;
  }
}

/// Non-empty rectangle with finite coordinates.
static BOOL RectIsUsable(LibretroRect rect) {
  return !LibretroRectIsEmpty(rect) && isfinite(rect.x) && isfinite(rect.y) && isfinite(rect.w) &&
         isfinite(rect.h);
}

/// `size` (layer drawable size, possibly fractional) describes a texture of
/// width x height pixels.
static BOOL SizeMatches(CGSize size, NSUInteger width, NSUInteger height) {
  if (!(size.width >= 1.0) || !(size.height >= 1.0)) return NO;
  return fabs((double)size.width - (double)width) <= 1.0 && fabs((double)size.height - (double)height) <= 1.0;
}

static int CompareDoubles(const void *left, const void *right) {
  const double a = *(const double *)left;
  const double b = *(const double *)right;
  return (a > b) - (a < b);
}

/// Median of `count` values (sorted in place); 0 when empty.
static double MedianOf(double *values, NSUInteger count) {
  if (count == 0) return 0.0;
  qsort(values, count, sizeof(double), CompareDoubles);
  if (count % 2 == 1) return values[count / 2];
  return (values[count / 2 - 1] + values[count / 2]) / 2.0;
}

/// Render pass on `target` cleared to black once (screens are drawn over it).
static MTLRenderPassDescriptor *ClearingPass(id<MTLTexture> target) {
  MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
  pass.colorAttachments[0].texture = target;
  pass.colorAttachments[0].loadAction = MTLLoadActionClear;
  pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
  pass.colorAttachments[0].storeAction = MTLStoreActionStore;
  return pass;
}

static NSValue *MappingValue(LibretroScreenMapping mapping) {
  return [NSValue valueWithBytes:&mapping objCType:@encode(LibretroScreenMapping)];
}

static NSArray<LibretroPresenterScreen *> *CopyScreens(NSArray *screens) {
  if (![screens isKindOfClass:[NSArray class]]) return @[];
  NSMutableArray<LibretroPresenterScreen *> *copies = [NSMutableArray arrayWithCapacity:screens.count];
  for (id screen in screens) {
    if ([screen isKindOfClass:[LibretroPresenterScreen class]]) [copies addObject:[screen copy]];
  }
  return [copies copy];
}

@implementation LibretroPresenterScreen

+ (instancetype)screenWithSource:(LibretroRect)source
                       container:(LibretroRect)container
                          format:(LibretroScreenFormat)format
                     touchScreen:(BOOL)touchScreen {
  LibretroPresenterScreen *screen = [[self alloc] init];
  screen.source = source;
  screen.container = container;
  screen.format = format;
  screen.touchScreen = touchScreen;
  return screen;
}

- (id)copyWithZone:(NSZone *)zone {
  LibretroPresenterScreen *duplicate = [[[self class] allocWithZone:zone] init];
  duplicate.source = _source;
  duplicate.container = _container;
  duplicate.format = _format;
  duplicate.touchScreen = _touchScreen;
  duplicate.nominalSize = _nominalSize;
  return duplicate;
}

@end

@implementation LibretroMetalPresenter {
  CAMetalLayer *_layer;
  id<MTLCommandQueue> _queue;
  id<MTLRenderPipelineState> _passthroughPipeline;
  id<MTLSamplerState> _nearest;
  id<MTLSamplerState> _linear;
  dispatch_semaphore_t _inFlight;
  NSMutableData *_conversion;
  os_unfair_lock _lock;

  // Upload ring, emulation thread. A slot's group counts the command
  // buffers still reading its texture; the slot waits for them before it is
  // written again (a frame without drawable leaves no command buffer, so the
  // in-flight semaphore alone does not protect the ring).
  id<MTLTexture> _uploads[LIBRETRO_UPLOAD_SLOTS];
  dispatch_group_t _uploadReaders[LIBRETRO_UPLOAD_SLOTS];
  NSUInteger _uploadIndex;
  BOOL _loggedUnsupportedFormat;
  uint32_t _frameCount;

  // Last frame, emulation thread (_lastShared under _lock).
  id<MTLTexture> _lastTexture;
  unsigned _lastWidth;
  unsigned _lastHeight;
  BOOL _lastFlipped;
  NSInteger _lastSlot;
  BOOL _lastShared;
  NSUInteger _lastDrawableWidth;
  NSUInteger _lastDrawableHeight;

  // Active preset, emulation thread.
  NSMutableDictionary<NSString *, id<MTLRenderPipelineState>> *_pipelines;
  id<MTLRenderPipelineState> _presetPipeline;
  LibretroShaderFilter _presetFilter;

  // Under _lock.
  NSArray<LibretroPresenterScreen *> *_screens;
  CGSize _screensSize;
  // Layout of the drawable size before the last change: a drawable taken
  // just before a resize keeps the screens computed for its size.
  NSArray<LibretroPresenterScreen *> *_previousScreens;
  CGSize _previousSize;
  NSArray<NSValue *> *_mappings;
  NSString *_presetIdentifier;
  NSDictionary<NSString *, NSNumber *> *_parameterSlots;
  float _parameterValues[LIBRETRO_SHADER_SLOTS];
  float _parameterMinimum[LIBRETRO_SHADER_SLOTS];
  float _parameterMaximum[LIBRETRO_SHADER_SLOTS];
  uint32_t _distortMask;
  double _gpuSamples[LIBRETRO_GPU_SAMPLES];
  NSUInteger _gpuSampleCount;
  NSUInteger _gpuSampleNext;
  uint64_t _gpuGeneration;

  // Immutable after init.
  NSArray<LibretroPresenterScreen *> *_defaultScreens;
}

- (nullable instancetype)initWithLayer:(CAMetalLayer *)layer {
  self = [super init];
  if (self == nil) return nil;
  _device = MTLCreateSystemDefaultDevice();
  if (_device == nil) return nil;
  _lock = OS_UNFAIR_LOCK_INIT;
  _layer = layer;
  layer.device = _device;
  layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
  layer.framebufferOnly = YES;
  layer.maximumDrawableCount = 3;
  _queue = [_device newCommandQueue];
  if (_queue == nil) return nil;
  NSError *error = nil;
  _passthroughPipeline = [self compilePipelineForPreset:nil error:&error];
  if (_passthroughPipeline == nil) {
    NSLog(@"[Libretro] Metal pass-through pipeline failed: %@", error);
    return nil;
  }
  MTLSamplerDescriptor *sampler = [MTLSamplerDescriptor new];
  sampler.sAddressMode = MTLSamplerAddressModeClampToEdge;
  sampler.tAddressMode = MTLSamplerAddressModeClampToEdge;
  sampler.minFilter = MTLSamplerMinMagFilterNearest;
  sampler.magFilter = MTLSamplerMinMagFilterNearest;
  _nearest = [_device newSamplerStateWithDescriptor:sampler];
  sampler.minFilter = MTLSamplerMinMagFilterLinear;
  sampler.magFilter = MTLSamplerMinMagFilterLinear;
  _linear = [_device newSamplerStateWithDescriptor:sampler];
  if (_nearest == nil || _linear == nil) return nil;
  _inFlight = dispatch_semaphore_create(LIBRETRO_FRAMES_IN_FLIGHT);
  _conversion = [NSMutableData data];
  for (NSUInteger slot = 0; slot < LIBRETRO_UPLOAD_SLOTS; slot++) _uploadReaders[slot] = dispatch_group_create();
  _lastSlot = -1;
  _aspectRatio = 4.0f / 3.0f;
  _pipelines = [NSMutableDictionary dictionary];
  _presetFilter = LibretroShaderFilterFollowSmoothing;
  _parameterSlots = @{};
  _screens = @[];
  _previousScreens = @[];
  _mappings = @[];
  _defaultScreens = @[ [LibretroPresenterScreen screenWithSource:LibretroRectUnit
                                                         container:LibretroRectUnit
                                                            format:LibretroScreenFormatOriginal
                                                       touchScreen:NO] ];
  return self;
}

#pragma mark - Pipelines

/// Prelude + preset fragment (pass-through when `preset` is nil), compiled
/// for the drawable's BGRA8 format.
- (nullable id<MTLRenderPipelineState>)compilePipelineForPreset:(nullable LibretroShaderPreset *)preset
                                                          error:(NSError *_Nullable *_Nullable)error {
  NSString *source = [LibretroShaderLibrary sourceForPreset:preset];
  MTLCompileOptions *options = [MTLCompileOptions new];
  options.languageVersion = (MTLLanguageVersion)LibretroShaderLanguageVersion;
  NSError *compileError = nil;
  id<MTLLibrary> library = [_device newLibraryWithSource:source options:options error:&compileError];
  if (library == nil) {
    if (error != NULL) {
      *error = compileError != nil ? compileError
                                   : [NSError errorWithDomain:kLibretroPresenterErrorDomain
                                                         code:LibretroPresenterErrorCompilation
                                                     userInfo:nil];
    }
    return nil;
  }
  id<MTLFunction> vertexFunction = [library newFunctionWithName:@"neostation_vertex"];
  id<MTLFunction> fragmentFunction = [library newFunctionWithName:@"neostation_fragment"];
  if (vertexFunction == nil || fragmentFunction == nil) {
    if (error != NULL) {
      NSString *missing = vertexFunction == nil ? @"neostation_vertex" : @"neostation_fragment";
      *error = [NSError errorWithDomain:kLibretroPresenterErrorDomain
                                   code:LibretroPresenterErrorMissingFunction
                               userInfo:@{@"function" : missing}];
    }
    return nil;
  }
  MTLRenderPipelineDescriptor *descriptor = [MTLRenderPipelineDescriptor new];
  descriptor.vertexFunction = vertexFunction;
  descriptor.fragmentFunction = fragmentFunction;
  descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
  NSError *pipelineError = nil;
  id<MTLRenderPipelineState> pipeline = [_device newRenderPipelineStateWithDescriptor:descriptor
                                                                                error:&pipelineError];
  if (pipeline == nil && error != NULL) {
    *error = pipelineError != nil ? pipelineError
                                  : [NSError errorWithDomain:kLibretroPresenterErrorDomain
                                                        code:LibretroPresenterErrorPipeline
                                                    userInfo:nil];
  }
  return pipeline;
}

- (BOOL)setShaderPreset:(nullable LibretroShaderPreset *)preset
             parameters:(nullable NSDictionary<NSString *, NSNumber *> *)parameters
                  error:(NSError *_Nullable *_Nullable)error {
  if (preset != nil && ![preset isKindOfClass:[LibretroShaderPreset class]]) preset = nil;
  if (preset == nil) {
    [self deactivatePreset];
    return YES;
  }
  NSString *identifier = [preset.identifier copy];
  id<MTLRenderPipelineState> pipeline = identifier != nil ? _pipelines[identifier] : nil;
  if (pipeline == nil) {
    NSError *compileError = nil;
    pipeline = [self compilePipelineForPreset:preset error:&compileError];
    if (pipeline == nil) {
      NSLog(@"[Libretro] shader preset %@ unavailable: %@", identifier, compileError);
      [self deactivatePreset];
      if (error != NULL) {
        *error = compileError != nil ? compileError
                                     : [NSError errorWithDomain:kLibretroPresenterErrorDomain
                                                           code:LibretroPresenterErrorCompilation
                                                       userInfo:nil];
      }
      return NO;
    }
    if (identifier != nil) _pipelines[identifier] = pipeline;
  }

  NSDictionary<NSString *, NSNumber *> *resolved = [preset resolvedParameters:parameters];
  float values[LIBRETRO_SHADER_SLOTS];
  float minimum[LIBRETRO_SHADER_SLOTS];
  float maximum[LIBRETRO_SHADER_SLOTS];
  memset(values, 0, sizeof(values));
  memset(minimum, 0, sizeof(minimum));
  memset(maximum, 0, sizeof(maximum));
  uint32_t distortMask = 0;
  NSMutableDictionary<NSString *, NSNumber *> *slots = [NSMutableDictionary dictionary];
  for (LibretroShaderParameter *parameter in preset.parameters) {
    const NSUInteger slot = parameter.slot;
    if (slot >= LIBRETRO_SHADER_SLOTS || parameter.identifier == nil) continue;
    NSNumber *value = resolved[parameter.identifier];
    values[slot] = value != nil ? value.floatValue : parameter.defaultValue;
    minimum[slot] = parameter.minimum;
    maximum[slot] = parameter.maximum;
    if (parameter.distortsGeometry) distortMask |= (uint32_t)1u << slot;
    slots[parameter.identifier] = @(slot);
  }

  NSDictionary<NSString *, NSNumber *> *frozenSlots = [slots copy];
  _presetPipeline = pipeline;
  _presetFilter = preset.filter;
  os_unfair_lock_lock(&_lock);
  const BOOL changed = ![_presetIdentifier isEqualToString:identifier];
  _presetIdentifier = identifier;
  _parameterSlots = frozenSlots;
  memcpy(_parameterValues, values, sizeof(values));
  memcpy(_parameterMinimum, minimum, sizeof(minimum));
  memcpy(_parameterMaximum, maximum, sizeof(maximum));
  _distortMask = distortMask;
  if (changed) {
    // Frames of the previous preset still in flight are not counted.
    _gpuGeneration++;
    _gpuSampleCount = 0;
    _gpuSampleNext = 0;
  }
  os_unfair_lock_unlock(&_lock);
  return YES;
}

/// Standard picture: pass-through pipeline, smoothing toggle.
- (void)deactivatePreset {
  _presetPipeline = nil;
  _presetFilter = LibretroShaderFilterFollowSmoothing;
  os_unfair_lock_lock(&_lock);
  const BOOL changed = _presetIdentifier != nil;
  _presetIdentifier = nil;
  _parameterSlots = @{};
  memset(_parameterValues, 0, sizeof(_parameterValues));
  memset(_parameterMinimum, 0, sizeof(_parameterMinimum));
  memset(_parameterMaximum, 0, sizeof(_parameterMaximum));
  _distortMask = 0;
  if (changed) {
    _gpuGeneration++;
    _gpuSampleCount = 0;
    _gpuSampleNext = 0;
  }
  os_unfair_lock_unlock(&_lock);
}

- (void)setShaderParameter:(NSString *)identifier value:(float)value {
  if (![identifier isKindOfClass:[NSString class]] || !isfinite(value)) return;
  os_unfair_lock_lock(&_lock);
  NSNumber *slot = _parameterSlots[identifier];
  if (slot != nil) {
    const NSUInteger index = slot.unsignedIntegerValue;
    if (index < LIBRETRO_SHADER_SLOTS) {
      _parameterValues[index] = fminf(fmaxf(value, _parameterMinimum[index]), _parameterMaximum[index]);
    }
  }
  os_unfair_lock_unlock(&_lock);
}

- (nullable NSString *)activePresetIdentifier {
  os_unfair_lock_lock(&_lock);
  NSString *identifier = _presetIdentifier;
  os_unfair_lock_unlock(&_lock);
  return identifier;
}

#pragma mark - Layout (main thread)

// The stored size and screens change under the lock BEFORE the layer gets
// the new drawable size (never inside the lock: nextDrawable may block in
// Core Animation). A drawable of the new size therefore always finds its
// screens, and a drawable taken just before the change finds the previous
// layout through _previousSize.

- (void)setDrawableSize:(CGSize)size {
  if (!(size.width >= 1.0) || !(size.height >= 1.0)) return;
  os_unfair_lock_lock(&_lock);
  if (size.width != _screensSize.width || size.height != _screensSize.height) {
    _previousScreens = _screens;
    _previousSize = _screensSize;
    _screensSize = size;
  }
  os_unfair_lock_unlock(&_lock);
  _layer.drawableSize = size;
}

- (void)setScreens:(NSArray<LibretroPresenterScreen *> *)screens {
  NSArray<LibretroPresenterScreen *> *copies = CopyScreens(screens);
  os_unfair_lock_lock(&_lock);
  _screens = copies;
  os_unfair_lock_unlock(&_lock);
}

- (void)setDrawableSize:(CGSize)size screens:(NSArray<LibretroPresenterScreen *> *)screens {
  NSArray<LibretroPresenterScreen *> *copies = CopyScreens(screens);
  const BOOL validSize = size.width >= 1.0 && size.height >= 1.0;
  os_unfair_lock_lock(&_lock);
  if (validSize && (size.width != _screensSize.width || size.height != _screensSize.height)) {
    _previousScreens = _screens;
    _previousSize = _screensSize;
    _screensSize = size;
  }
  _screens = copies;
  os_unfair_lock_unlock(&_lock);
  if (validSize) _layer.drawableSize = size;
}

- (NSArray<NSValue *> *)screenMappings {
  os_unfair_lock_lock(&_lock);
  NSArray<NSValue *> *mappings = _mappings;
  os_unfair_lock_unlock(&_lock);
  return mappings != nil ? mappings : @[];
}

/// Screens laid out for a target of width x height pixels (the default
/// full screen when none is set), and the GPU sample generation.
- (NSArray<LibretroPresenterScreen *> *)screensForWidth:(NSUInteger)width
                                                 height:(NSUInteger)height
                                             generation:(uint64_t *)generation {
  os_unfair_lock_lock(&_lock);
  NSArray<LibretroPresenterScreen *> *screens = _screens;
  if (!SizeMatches(_screensSize, width, height) && SizeMatches(_previousSize, width, height)) {
    screens = _previousScreens;
  }
  if (generation != NULL) *generation = _gpuGeneration;
  os_unfair_lock_unlock(&_lock);
  return screens.count > 0 ? screens : _defaultScreens;
}

#pragma mark - Frames (emulation thread)

/// Next upload texture of `pixelFormat` holding at least width x height,
/// once no command buffer reads it any more; -1 when unavailable.
- (NSInteger)uploadSlotForFormat:(MTLPixelFormat)pixelFormat width:(unsigned)width height:(unsigned)height {
  const NSInteger formatIndex = UploadFormatIndex(pixelFormat);
  if (formatIndex < 0 || width > LIBRETRO_MAX_TEXTURE_SIZE || height > LIBRETRO_MAX_TEXTURE_SIZE) return -1;
  const NSInteger slot = formatIndex * LIBRETRO_FRAMES_IN_FLIGHT + (NSInteger)_uploadIndex;
  _uploadIndex = (_uploadIndex + 1) % LIBRETRO_FRAMES_IN_FLIGHT;
  dispatch_group_wait(_uploadReaders[slot], DISPATCH_TIME_FOREVER);
  id<MTLTexture> texture = _uploads[slot];
  if (texture == nil || texture.width < width || texture.height < height) {
    const NSUInteger newWidth = MAX((NSUInteger)width, texture.width);
    const NSUInteger newHeight = MAX((NSUInteger)height, texture.height);
    MTLTextureDescriptor *descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:pixelFormat
                                                                                          width:newWidth
                                                                                         height:newHeight
                                                                                      mipmapped:NO];
    descriptor.usage = MTLTextureUsageShaderRead;
    descriptor.storageMode = MTLStorageModeShared;
    texture = [_device newTextureWithDescriptor:descriptor];
    if (texture == nil) return -1;
    _uploads[slot] = texture;
  }
  return slot;
}

- (void)keepLastFrame:(id<MTLTexture>)texture
                width:(unsigned)width
               height:(unsigned)height
              flipped:(BOOL)flipped
                 slot:(NSInteger)slot
               shared:(BOOL)shared {
  _lastTexture = texture;
  _lastWidth = width;
  _lastHeight = height;
  _lastFlipped = flipped;
  _lastSlot = slot;
  os_unfair_lock_lock(&_lock);
  _lastShared = shared;
  os_unfair_lock_unlock(&_lock);
}

- (void)presentSoftwareFrame:(const void *)data
                       width:(unsigned)width
                      height:(unsigned)height
                       pitch:(size_t)pitch
                      format:(enum retro_pixel_format)format {
  if (data == NULL || width == 0 || height == 0) return;
  dispatch_semaphore_wait(_inFlight, DISPATCH_TIME_FOREVER);
  const NSInteger slot = [self uploadSlotForFormat:MTLPixelFormatBGRA8Unorm width:width height:height];
  if (slot < 0) {
    dispatch_semaphore_signal(_inFlight);
    return;
  }
  id<MTLTexture> texture = _uploads[slot];
  MTLRegion region = MTLRegionMake2D(0, 0, width, height);
  if (format == RETRO_PIXEL_FORMAT_XRGB8888) {
    [texture replaceRegion:region mipmapLevel:0 withBytes:data bytesPerRow:pitch];
  } else {
    size_t needed = (size_t)width * height * 4;
    if (_conversion.length < needed) _conversion.length = needed;
    uint32_t *output = _conversion.mutableBytes;
    for (unsigned row = 0; row < height; row++) {
      const uint16_t *source = (const uint16_t *)((const uint8_t *)data + row * pitch);
      uint32_t *target = output + (size_t)row * width;
      if (format == RETRO_PIXEL_FORMAT_RGB565) {
        for (unsigned column = 0; column < width; column++) {
          uint32_t pixel = source[column];
          uint32_t red = Expand5((pixel >> 11) & 0x1F);
          uint32_t green = Expand6((pixel >> 5) & 0x3F);
          uint32_t blue = Expand5(pixel & 0x1F);
          target[column] = 0xFF000000u | (red << 16) | (green << 8) | blue;
        }
      } else {
        for (unsigned column = 0; column < width; column++) {
          uint32_t pixel = source[column];
          uint32_t red = Expand5((pixel >> 10) & 0x1F);
          uint32_t green = Expand5((pixel >> 5) & 0x1F);
          uint32_t blue = Expand5(pixel & 0x1F);
          target[column] = 0xFF000000u | (red << 16) | (green << 8) | blue;
        }
      }
    }
    [texture replaceRegion:region mipmapLevel:0 withBytes:output bytesPerRow:(NSUInteger)width * 4];
  }
  _frameCount++;
  [self keepLastFrame:texture width:width height:height flipped:NO slot:slot shared:NO];
  [self drawTexture:texture width:width height:height flipped:NO uploadSlot:slot completion:nil];
}

- (void)presentTexture:(id<MTLTexture>)texture
                 width:(unsigned)width
                height:(unsigned)height
               flipped:(BOOL)flipped
            completion:(nullable dispatch_block_t)completion {
  dispatch_semaphore_wait(_inFlight, DISPATCH_TIME_FOREVER);
  _frameCount++;
  if (texture != nil && width > 0 && height > 0) {
    [self keepLastFrame:texture width:width height:height flipped:flipped slot:-1 shared:YES];
  }
  [self drawTexture:texture width:width height:height flipped:flipped uploadSlot:-1 completion:completion];
}

- (void)presentPixels:(const void *)pixels
                width:(unsigned)width
               height:(unsigned)height
          bytesPerRow:(size_t)bytesPerRow
          pixelFormat:(MTLPixelFormat)pixelFormat {
  if (pixels == NULL || width == 0 || height == 0) return;
  if (UploadFormatIndex(pixelFormat) < 0) {
    if (!_loggedUnsupportedFormat) {
      _loggedUnsupportedFormat = YES;
      NSLog(@"[Libretro] presenter: unsupported pixel format %lu, frames dropped", (unsigned long)pixelFormat);
    }
    return;
  }
  // Every accepted format has 4 bytes per pixel.
  if (bytesPerRow < (size_t)width * 4) return;
  dispatch_semaphore_wait(_inFlight, DISPATCH_TIME_FOREVER);
  const NSInteger slot = [self uploadSlotForFormat:pixelFormat width:width height:height];
  if (slot < 0) {
    dispatch_semaphore_signal(_inFlight);
    return;
  }
  id<MTLTexture> texture = _uploads[slot];
  [texture replaceRegion:MTLRegionMake2D(0, 0, width, height)
             mipmapLevel:0
               withBytes:pixels
             bytesPerRow:bytesPerRow];
  _frameCount++;
  [self keepLastFrame:texture width:width height:height flipped:NO slot:slot shared:NO];
  [self drawTexture:texture width:width height:height flipped:NO uploadSlot:slot completion:nil];
}

/// `completion` always runs exactly once, also when NO is returned.
- (BOOL)representLastFrameWithCompletion:(nullable dispatch_block_t)completion {
  id<MTLTexture> texture = _lastTexture;
  if (texture == nil || _lastWidth == 0 || _lastHeight == 0) {
    if (completion != nil) completion();
    return NO;
  }
  dispatch_semaphore_wait(_inFlight, DISPATCH_TIME_FOREVER);
  [self drawTexture:texture
              width:_lastWidth
             height:_lastHeight
            flipped:_lastFlipped
         uploadSlot:_lastSlot
         completion:completion];
  return YES;
}

- (BOOL)lastFrameIsSharedTexture {
  os_unfair_lock_lock(&_lock);
  const BOOL shared = _lastShared;
  os_unfair_lock_unlock(&_lock);
  return shared;
}

- (void)invalidateLastFrame {
  _lastTexture = nil;
  _lastWidth = 0;
  _lastHeight = 0;
  _lastFlipped = NO;
  _lastSlot = -1;
  os_unfair_lock_lock(&_lock);
  _lastShared = NO;
  os_unfair_lock_unlock(&_lock);
}

- (void)presentBlack {
  dispatch_semaphore_wait(_inFlight, DISPATCH_TIME_FOREVER);
  id<CAMetalDrawable> drawable = [_layer nextDrawable];
  if (drawable == nil) {
    dispatch_semaphore_signal(_inFlight);
    return;
  }
  MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
  pass.colorAttachments[0].texture = drawable.texture;
  pass.colorAttachments[0].loadAction = MTLLoadActionClear;
  pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
  pass.colorAttachments[0].storeAction = MTLStoreActionStore;
  id<MTLCommandBuffer> buffer = [_queue commandBuffer];
  [[buffer renderCommandEncoderWithDescriptor:pass] endEncoding];
  [buffer presentDrawable:drawable];
  dispatch_semaphore_t semaphore = _inFlight;
  [buffer addCompletedHandler:^(__unused id<MTLCommandBuffer> completed) {
    dispatch_semaphore_signal(semaphore);
  }];
  [buffer commit];
}

#pragma mark - Drawing (emulation thread)

/// Draws `texture` on the next drawable. The caller holds one in-flight
/// slot; it is released when the GPU has finished (at once when nothing is
/// drawn), then `completion` runs.
- (void)drawTexture:(nullable id<MTLTexture>)texture
              width:(unsigned)width
             height:(unsigned)height
            flipped:(BOOL)flipped
         uploadSlot:(NSInteger)slot
         completion:(nullable dispatch_block_t)completion {
  dispatch_semaphore_t semaphore = _inFlight;
  id<CAMetalDrawable> drawable = nil;
  if (texture != nil && width > 0 && height > 0) drawable = [_layer nextDrawable];
  id<MTLTexture> target = drawable.texture;
  const NSUInteger targetWidth = target.width;
  const NSUInteger targetHeight = target.height;
  id<MTLCommandBuffer> buffer = (target != nil && targetWidth > 0 && targetHeight > 0) ? [_queue commandBuffer] : nil;
  if (buffer == nil) {
    dispatch_semaphore_signal(semaphore);
    if (completion != nil) completion();
    return;
  }
  uint64_t generation = 0;
  NSArray<LibretroPresenterScreen *> *screens = [self screensForWidth:targetWidth
                                                               height:targetHeight
                                                           generation:&generation];
  id<MTLRenderCommandEncoder> encoder = [buffer renderCommandEncoderWithDescriptor:ClearingPass(target)];
  NSArray<NSValue *> *mappings = [self encodeScreens:screens
                                             encoder:encoder
                                             texture:texture
                                               width:width
                                              height:height
                                             flipped:flipped
                                         outputWidth:(double)targetWidth
                                        outputHeight:(double)targetHeight];
  [encoder endEncoding];
  [buffer presentDrawable:drawable];
  _lastDrawableWidth = targetWidth;
  _lastDrawableHeight = targetHeight;
  os_unfair_lock_lock(&_lock);
  _mappings = mappings;
  os_unfair_lock_unlock(&_lock);

  dispatch_group_t readers = nil;
  if (slot >= 0 && slot < LIBRETRO_UPLOAD_SLOTS) {
    readers = _uploadReaders[slot];
    dispatch_group_enter(readers);
  }
  __weak LibretroMetalPresenter *weakSelf = self;
  [buffer addCompletedHandler:^(id<MTLCommandBuffer> completed) {
    if (readers != nil) dispatch_group_leave(readers);
    dispatch_semaphore_signal(semaphore);
    [weakSelf recordGPUTimeOfBuffer:completed generation:generation];
    if (completion != nil) completion();
  }];
  [buffer commit];
}

/// One draw per screen into the current render pass of a target of
/// outputWidth x outputHeight pixels. Returns where each screen was drawn,
/// normalized to the target, in screen order (empty output for a screen
/// that cannot be drawn).
- (NSArray<NSValue *> *)encodeScreens:(NSArray<LibretroPresenterScreen *> *)screens
                              encoder:(id<MTLRenderCommandEncoder>)encoder
                              texture:(id<MTLTexture>)texture
                                width:(unsigned)width
                               height:(unsigned)height
                              flipped:(BOOL)flipped
                          outputWidth:(double)outputWidth
                         outputHeight:(double)outputHeight {
  float parameters[LIBRETRO_SHADER_SLOTS];
  os_unfair_lock_lock(&_lock);
  memcpy(parameters, _parameterValues, sizeof(parameters));
  const uint32_t distortMask = _distortMask;
  os_unfair_lock_unlock(&_lock);

  id<MTLRenderPipelineState> pipeline = _presetPipeline != nil ? _presetPipeline : _passthroughPipeline;
  BOOL linear = self.smooth;
  if (_presetPipeline != nil) {
    if (_presetFilter == LibretroShaderFilterNearest) {
      linear = NO;
    } else if (_presetFilter == LibretroShaderFilterLinear) {
      linear = YES;
    }
  }
  [encoder setRenderPipelineState:pipeline];
  [encoder setFragmentTexture:texture atIndex:0];
  [encoder setFragmentSamplerState:(linear ? _linear : _nearest) atIndex:0];

  const unsigned rotation = self.rotation % 4;
  const BOOL quarterTurn = (rotation % 2) == 1;
  const double textureWidth = (double)MAX(texture.width, (NSUInteger)1);
  const double textureHeight = (double)MAX(texture.height, (NSUInteger)1);
  // Valid frame region inside the (possibly larger) texture.
  const double frameWidth = fmin((double)width, textureWidth);
  const double frameHeight = fmin((double)height, textureHeight);
  double coreAspect = (double)self.aspectRatio;
  if (!(coreAspect > 0.0) || isinf(coreAspect)) coreAspect = frameWidth / frameHeight;

  // Picture corners clockwise from top-left, in the picture coordinate the
  // shaders receive ([0,1], top-left origin, flip handled by NEO_SAMPLE). A
  // rotation of N quarter turns counter-clockwise shows picture corner
  // (i + N) at screen corner i (LibretroPointerFromPoint undoes the same).
  const simd_float2 corners[4] = {{0.0f, 0.0f}, {1.0f, 0.0f}, {1.0f, 1.0f}, {0.0f, 1.0f}};
  const simd_float2 topLeft = corners[(0 + rotation) % 4];
  const simd_float2 topRight = corners[(1 + rotation) % 4];
  const simd_float2 bottomRight = corners[(2 + rotation) % 4];
  const simd_float2 bottomLeft = corners[(3 + rotation) % 4];
  const double halfTexelU = 0.5 / textureWidth;
  const double halfTexelV = 0.5 / textureHeight;

  NSMutableArray<NSValue *> *mappings = [NSMutableArray arrayWithCapacity:screens.count];
  for (LibretroPresenterScreen *screen in screens) {
    LibretroScreenMapping mapping;
    memset(&mapping, 0, sizeof(mapping));
    mapping.rotation = rotation;
    const LibretroRect source = LibretroRectIntersection(screen.source, LibretroRectUnit);
    mapping.source = source;
    const LibretroRect container = screen.container;
    LibretroRect output = LibretroRectMake(0.0, 0.0, 0.0, 0.0);
    if (RectIsUsable(source) && RectIsUsable(container)) {
      const LibretroRect containerPixels = LibretroRectMake(container.x * outputWidth, container.y * outputHeight,
                                                            container.w * outputWidth, container.h * outputHeight);
      output = LibretroFitScreen(containerPixels, LibretroSourceAspect(coreAspect, source, rotation), screen.format);
    }
    if (!RectIsUsable(output)) {
      [mappings addObject:MappingValue(mapping)];
      continue;
    }
    mapping.output = LibretroRectMake(output.x / outputWidth, output.y / outputHeight, output.w / outputWidth,
                                      output.h / outputHeight);
    [mappings addObject:MappingValue(mapping)];

    const float left = (float)(output.x / outputWidth * 2.0 - 1.0);
    const float right = (float)((output.x + output.w) / outputWidth * 2.0 - 1.0);
    const float top = (float)(1.0 - output.y / outputHeight * 2.0);
    const float bottom = (float)(1.0 - (output.y + output.h) / outputHeight * 2.0);
    // Triangle strip: left-top, left-bottom, right-top, right-bottom.
    const simd_float4 quad[4] = {
        {left, top, topLeft.x, topLeft.y},
        {left, bottom, bottomLeft.x, bottomLeft.y},
        {right, top, topRight.x, topRight.y},
        {right, bottom, bottomRight.x, bottomRight.y},
    };

    LibretroShaderUniforms uniforms;
    memset(&uniforms, 0, sizeof(uniforms));
    // The part as stored in the texture (smallest corner and size): a
    // bottom-left origin frame keeps its picture rows upside down.
    const double partU = source.x * frameWidth / textureWidth;
    const double partWidth = source.w * frameWidth / textureWidth;
    const double partHeight = source.h * frameHeight / textureHeight;
    const double partV = (flipped ? (1.0 - source.y - source.h) : source.y) * frameHeight / textureHeight;
    double minU = partU + halfTexelU;
    double maxU = partU + partWidth - halfTexelU;
    if (maxU < minU) minU = maxU = partU + partWidth / 2.0;
    double minV = partV + halfTexelV;
    double maxV = partV + partHeight - halfTexelV;
    if (maxV < minV) minV = maxV = partV + partHeight / 2.0;
    uniforms.uvOrigin = simd_make_float2((float)partU, (float)partV);
    uniforms.uvExtent = simd_make_float2((float)partWidth, (float)partHeight);
    uniforms.uvMin = simd_make_float2((float)minU, (float)minV);
    uniforms.uvMax = simd_make_float2((float)maxU, (float)maxV);

    // The console's pixels only when this frame is a uniform upscale of them
    // (PSP 960x544 -> 480x272); otherwise the part's real texels, compared
    // with every frame (Nestopia crops the NES frame to 256x224, a Mega
    // Drive game switches between 256 and 320 wide).
    const LibretroSize texels = {source.w * frameWidth, source.h * frameHeight};
    const LibretroSize sourceSize = LibretroShaderSourceSize(texels, screen.nominalSize);
    uniforms.SourceSize = simd_make_float4((float)sourceSize.w, (float)sourceSize.h, (float)(1.0 / sourceSize.w),
                                           (float)(1.0 / sourceSize.h));
    uniforms.OriginalSize = uniforms.SourceSize;
    // Along the picture's own axes: a quarter turn swaps the drawn sides.
    const double outputAlongX = fmax(quarterTurn ? output.h : output.w, 1.0);
    const double outputAlongY = fmax(quarterTurn ? output.w : output.h, 1.0);
    uniforms.OutputSize = simd_make_float4((float)outputAlongX, (float)outputAlongY, (float)(1.0 / outputAlongX),
                                           (float)(1.0 / outputAlongY));
    uniforms.FrameCount = _frameCount;
    uniforms.flipped = flipped ? 1u : 0u;
    for (NSUInteger index = 0; index < LIBRETRO_SHADER_SLOTS; index++) {
      const BOOL flatten = screen.touchScreen && (distortMask & ((uint32_t)1u << index)) != 0;
      uniforms.parameters[index] = flatten ? 0.0f : parameters[index];
    }

    [encoder setVertexBytes:quad length:sizeof(quad) atIndex:0];
    [encoder setFragmentBytes:&uniforms length:sizeof(uniforms) atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
  }
  return [mappings copy];
}

#pragma mark - GPU time

- (void)recordGPUTimeOfBuffer:(id<MTLCommandBuffer>)buffer generation:(uint64_t)generation {
  if (buffer.status != MTLCommandBufferStatusCompleted) return;
  const double milliseconds = (buffer.GPUEndTime - buffer.GPUStartTime) * 1000.0;
  if (!(milliseconds > 0.0) || !isfinite(milliseconds)) return;
  os_unfair_lock_lock(&_lock);
  if (generation == _gpuGeneration) {
    _gpuSamples[_gpuSampleNext] = milliseconds;
    _gpuSampleNext = (_gpuSampleNext + 1) % LIBRETRO_GPU_SAMPLES;
    if (_gpuSampleCount < LIBRETRO_GPU_SAMPLES) _gpuSampleCount++;
  }
  os_unfair_lock_unlock(&_lock);
}

- (double)gpuMilliseconds {
  double samples[LIBRETRO_GPU_SAMPLES];
  os_unfair_lock_lock(&_lock);
  const NSUInteger count = _gpuSampleCount;
  // Until the window is full the samples are the first `count` entries.
  memcpy(samples, _gpuSamples, count * sizeof(double));
  os_unfair_lock_unlock(&_lock);
  return MedianOf(samples, count);
}

- (double)measureLastFrameGPUTime:(NSUInteger)iterations {
  id<MTLTexture> texture = _lastTexture;
  if (texture == nil || _lastWidth == 0 || _lastHeight == 0 || iterations == 0) return 0.0;
  const NSUInteger count = MIN(iterations, (NSUInteger)LIBRETRO_GPU_SAMPLES);

  os_unfair_lock_lock(&_lock);
  const CGSize size = _screensSize;
  const uint64_t generation = _gpuGeneration;
  os_unfair_lock_unlock(&_lock);
  NSUInteger targetWidth = _lastDrawableWidth;
  NSUInteger targetHeight = _lastDrawableHeight;
  if (size.width >= 1.0 && size.height >= 1.0) {
    targetWidth = (NSUInteger)llround((double)size.width);
    targetHeight = (NSUInteger)llround((double)size.height);
  }
  if (targetWidth == 0 || targetHeight == 0) return 0.0;
  targetWidth = MIN(targetWidth, (NSUInteger)LIBRETRO_MAX_TEXTURE_SIZE);
  targetHeight = MIN(targetHeight, (NSUInteger)LIBRETRO_MAX_TEXTURE_SIZE);

  MTLTextureDescriptor *descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                        width:targetWidth
                                                                                       height:targetHeight
                                                                                    mipmapped:NO];
  descriptor.usage = MTLTextureUsageRenderTarget;
  descriptor.storageMode = MTLStorageModePrivate;
  id<MTLTexture> target = [_device newTextureWithDescriptor:descriptor];
  if (target == nil) return 0.0;
  NSArray<LibretroPresenterScreen *> *screens = [self screensForWidth:targetWidth height:targetHeight generation:NULL];

  double samples[LIBRETRO_GPU_SAMPLES];
  NSUInteger measured = 0;
  for (NSUInteger iteration = 0; iteration < count; iteration++) {
    @autoreleasepool {
      id<MTLCommandBuffer> buffer = [_queue commandBuffer];
      if (buffer == nil) break;
      id<MTLRenderCommandEncoder> encoder = [buffer renderCommandEncoderWithDescriptor:ClearingPass(target)];
      [self encodeScreens:screens
                  encoder:encoder
                  texture:texture
                    width:_lastWidth
                   height:_lastHeight
                  flipped:_lastFlipped
              outputWidth:(double)targetWidth
             outputHeight:(double)targetHeight];
      [encoder endEncoding];
      [buffer commit];
      [buffer waitUntilCompleted];
      if (buffer.status != MTLCommandBufferStatusCompleted) continue;
      const double milliseconds = (buffer.GPUEndTime - buffer.GPUStartTime) * 1000.0;
      if (milliseconds > 0.0 && isfinite(milliseconds)) samples[measured++] = milliseconds;
    }
  }
  if (measured == 0) return 0.0;
  // The measured draws are presenter command buffers with the current
  // preset: they also feed gpuMilliseconds, so it is current while paused.
  os_unfair_lock_lock(&_lock);
  if (generation == _gpuGeneration) {
    for (NSUInteger index = 0; index < measured; index++) {
      _gpuSamples[_gpuSampleNext] = samples[index];
      _gpuSampleNext = (_gpuSampleNext + 1) % LIBRETRO_GPU_SAMPLES;
      if (_gpuSampleCount < LIBRETRO_GPU_SAMPLES) _gpuSampleCount++;
    }
  }
  os_unfair_lock_unlock(&_lock);
  return MedianOf(samples, measured);
}

@end
