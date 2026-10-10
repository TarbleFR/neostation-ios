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

/// Called for SET_HW_RENDER, on the emulation thread: validates the
/// requested context, creates the EAGL context and a provisional framebuffer
/// (made current on this thread), and fills get_current_framebuffer and
/// get_proc_address. Returns nil, with the reason in `error`, for an
/// unsupported context type or when the context or its surface cannot be
/// created. Failing here refuses the hardware context while the core can
/// still fall back (PPSSPP renders in software) or give up cleanly; failing
/// after retro_load_game would unload PPSSPP while its boot thread runs,
/// which PPSSPP does not survive.
+ (nullable instancetype)rendererForCallback:(struct retro_hw_render_callback *)callback
                                      device:(id<MTLDevice>)device
                                       error:(NSError *_Nullable *_Nullable)error;

/// Grows the framebuffer to at least this size (the context exists).
- (BOOL)prepareWithWidth:(unsigned)width height:(unsigned)height error:(NSError *_Nullable *_Nullable)error;
- (void)makeCurrent;

/// Waits for the core's GL work and returns the frame as a Metal texture.
- (nullable id<MTLTexture>)finishFrame;
@property(nonatomic, readonly) BOOL bottomLeftOrigin;

- (void)teardown;

@end

NS_ASSUME_NONNULL_END
