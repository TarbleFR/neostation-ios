#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>

#import "LibretroGeometry.h"

#include "libretro.h"

@class LibretroShaderPreset;

NS_ASSUME_NONNULL_BEGIN

/// One game screen drawn by the presenter.
@interface LibretroPresenterScreen : NSObject <NSCopying>
/// Normalized part of the core image (top-left origin, before rotation).
@property(nonatomic, assign) LibretroRect source;
/// Normalized rectangle of the drawable (0-1, top-left) the screen may use:
/// the skin's game area or output frame. The picture is fitted inside it
/// with `format`.
@property(nonatomic, assign) LibretroRect container;
@property(nonatomic, assign) LibretroScreenFormat format;
@property(nonatomic, assign) BOOL touchScreen;
/// Console pixels of this screen (PSP 480x272, 3DS top 400x240...) for the
/// shaders' SourceSize; {0,0} = the texels of the source part.
@property(nonatomic, assign) LibretroSize nominalSize;
+ (instancetype)screenWithSource:(LibretroRect)source
                       container:(LibretroRect)container
                          format:(LibretroScreenFormat)format
                     touchScreen:(BOOL)touchScreen;
@end

/// Draws core frames into the session's CAMetalLayer. Software frames are
/// converted to BGRA8 and uploaded; OpenGL ES frames arrive as a Metal
/// texture sharing the same IOSurface; Vulkan frames arrive as pixels copied
/// by LibretroVulkanRenderer. Every frame is drawn once per screen (DS/3DS
/// skins crop the top and bottom screens), fitted with the screen format and
/// optionally through a post-processing preset. Rendering happens on the
/// emulation thread; setters are called from the main thread and are
/// thread-safe.
@interface LibretroMetalPresenter : NSObject

- (nullable instancetype)initWithLayer:(CAMetalLayer *)layer;

@property(nonatomic, readonly) id<MTLDevice> device;
/// Linear (YES) or nearest (NO) sampling when no preset is active; a preset
/// uses its own filter.
@property(atomic, assign) BOOL smooth;
/// Display aspect of the whole core image (retro_game_geometry).
@property(atomic, assign) float aspectRatio;
@property(atomic, assign) unsigned rotation;

/// Main thread, from layout: size of the layer in pixels.
- (void)setDrawableSize:(CGSize)size;

/// Main thread. Empty array: one screen showing the whole picture in the
/// whole drawable with the Original format (the historical behaviour).
- (void)setScreens:(NSArray<LibretroPresenterScreen *> *)screens;

/// Main thread: drawable size and screens in one locked update, so no frame
/// mixes a new size with an old layout (rotation).
- (void)setDrawableSize:(CGSize)size screens:(NSArray<LibretroPresenterScreen *> *)screens;

/// Where each screen was drawn for the last presented frame, normalized to
/// the drawable (output) with its source and the rotation: input for touch
/// mapping. Same order as the screens.
- (NSArray<NSValue *> *)screenMappings;  // NSValue of LibretroScreenMapping

/// Compiles (MTLCompileOptions.languageVersion =
/// LibretroShaderLanguageVersion, pipelines cached per preset) and activates
/// a preset (nil = none) with parameter values {identifier: value}. Call it
/// on the emulation thread (never the main thread). When the preset cannot
/// be compiled, NO preset is active afterwards (standard picture), NO is
/// returned and `error` gets the Metal message for the log; the caller must
/// not save that preset.
- (BOOL)setShaderPreset:(nullable LibretroShaderPreset *)preset
             parameters:(nullable NSDictionary<NSString *, NSNumber *> *)parameters
                  error:(NSError *_Nullable *_Nullable)error;
/// Thread-safe; takes effect at the next draw.
- (void)setShaderParameter:(NSString *)identifier value:(float)value;
@property(atomic, copy, readonly, nullable) NSString *activePresetIdentifier;

/// Median GPU time of the presenter's command buffers over the last 120
/// frames, in milliseconds; 0 until measured.
@property(atomic, readonly) double gpuMilliseconds;

/// Emulation thread: draws the last frame `iterations` times into an
/// off-screen texture of the drawable's size with the current screens and
/// preset, and returns the median GPU time in milliseconds (0 when no frame
/// or no timing). Measures a preset right after it is chosen, while paused.
- (double)measureLastFrameGPUTime:(NSUInteger)iterations;

/// Releases the reference to the last frame's texture (call before the
/// OpenGL renderer reallocates its IOSurface).
- (void)invalidateLastFrame;

- (void)presentSoftwareFrame:(const void *)data
                       width:(unsigned)width
                      height:(unsigned)height
                       pitch:(size_t)pitch
                      format:(enum retro_pixel_format)format;

/// `flipped` is YES for OpenGL frames whose origin is the bottom-left.
/// `completion` runs once the GPU has finished reading the texture.
- (void)presentTexture:(id<MTLTexture>)texture
                 width:(unsigned)width
                height:(unsigned)height
               flipped:(BOOL)flipped
            completion:(nullable dispatch_block_t)completion;

/// Pixels read back from a Vulkan core (BGRA8Unorm, RGBA8Unorm or
/// RGB10A2Unorm, top-left origin). Copied before returning.
- (void)presentPixels:(const void *)pixels
                width:(unsigned)width
               height:(unsigned)height
          bytesPerRow:(size_t)bytesPerRow
          pixelFormat:(MTLPixelFormat)pixelFormat;

/// Draws the last frame again with the current screens, format and preset
/// (paused game, rotation, menu changes). Emulation thread, only while the
/// application is active. Returns NO when no frame is kept. `completion` as
/// in presentTexture. The presenter keeps its own copy of the last software
/// / Vulkan frame (the upload ring is reused) and a reference to the last
/// OpenGL texture.
- (BOOL)representLastFrameWithCompletion:(nullable dispatch_block_t)completion;

/// YES when the last frame came from presentTexture (OpenGL IOSurface):
/// the session must hold its GL frame semaphore while re-presenting it.
@property(atomic, readonly) BOOL lastFrameIsSharedTexture;

/// Clears the layer, for instance while content is loading.
- (void)presentBlack;

@end

NS_ASSUME_NONNULL_END
