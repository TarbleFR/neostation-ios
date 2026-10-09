#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include "libretro.h"

NS_ASSUME_NONNULL_BEGIN

/// OpenGL ES hardware context for libretro cores (RETRO_HW_CONTEXT_OPENGLES2,
/// OPENGLES3 and OPENGLES_VERSION up to 3.0; iOS has no desktop OpenGL).
///
/// The core renders into a framebuffer whose colour attachment is an
/// IOSurface-backed CVPixelBuffer that Metal samples directly, so frames
/// reach the CAMetalLayer without a copy. Every method runs on the
/// emulation thread, where the context stays current.
@interface LibretroGLRenderer : NSObject

/// Validates the requested context and fills get_current_framebuffer and
/// get_proc_address. Returns nil for an unsupported context type.
+ (nullable instancetype)rendererForCallback:(struct retro_hw_render_callback *)callback
                                      device:(id<MTLDevice>)device;

/// Creates the EAGL context and a framebuffer of at least this size.
- (BOOL)prepareWithWidth:(unsigned)width height:(unsigned)height error:(NSError *_Nullable *_Nullable)error;
- (void)makeCurrent;

/// Waits for the core's GL work and returns the frame as a Metal texture.
- (nullable id<MTLTexture>)finishFrame;
@property(nonatomic, readonly) BOOL bottomLeftOrigin;

- (void)teardown;

@end

NS_ASSUME_NONNULL_END
