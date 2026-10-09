#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>

#include "libretro.h"

NS_ASSUME_NONNULL_BEGIN

/// Draws core frames into the session's CAMetalLayer, aspect-fitted and
/// rotated as the core requests. Software frames are converted to BGRA8 and
/// uploaded; OpenGL ES frames arrive as a Metal texture sharing the same
/// IOSurface. Rendering happens on the emulation thread.
@interface LibretroMetalPresenter : NSObject

- (nullable instancetype)initWithLayer:(CAMetalLayer *)layer;

@property(nonatomic, readonly) id<MTLDevice> device;
@property(nonatomic, assign) BOOL smooth;
@property(nonatomic, assign) float aspectRatio;
@property(nonatomic, assign) unsigned rotation;

/// Main thread, from layout: size of the layer in pixels.
- (void)setDrawableSize:(CGSize)size;

/// Video rectangle in normalised layer coordinates (0-1, origin top-left),
/// used to map touches to RETRO_DEVICE_POINTER.
@property(nonatomic, readonly) CGRect normalizedVideoRect;

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

/// Clears the layer, for instance while content is loading.
- (void)presentBlack;

@end

NS_ASSUME_NONNULL_END
