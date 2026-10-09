#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>

#include "libretro.h"

NS_ASSUME_NONNULL_BEGIN

/// Vulkan hardware context for libretro cores, through the MoltenVK
/// framework embedded with the cores. Implements the libretro Vulkan render
/// interface (v5) and context negotiation (v1 and v2): the core's image is
/// blitted, aspect-fitted, into a swapchain on the session's CAMetalLayer.
/// Every method except `setDrawableSize:` runs on the emulation thread.
@interface LibretroVulkanRenderer : NSObject

+ (nullable instancetype)rendererForCallback:(struct retro_hw_render_callback *)callback
                                       layer:(CAMetalLayer *)layer;

+ (unsigned)negotiationVersionForType:(enum retro_hw_render_context_negotiation_interface_type)type;
- (BOOL)setNegotiationInterface:(const struct retro_hw_render_context_negotiation_interface *)negotiation;

/// Instance, surface, device and swapchain; call before context_reset.
- (BOOL)prepare:(NSError *_Nullable *_Nullable)error;
- (const struct retro_hw_render_interface *_Nullable)renderInterface;

- (void)beginFrame;
/// `valid` is NO for a duplicated frame; the last image is shown again.
- (void)endFrameWithWidth:(unsigned)width height:(unsigned)height valid:(BOOL)valid;

@property(nonatomic, assign) BOOL smooth;
@property(nonatomic, assign) float aspectRatio;
@property(nonatomic, readonly) CGRect normalizedVideoRect;

/// Waits for the GPU; the core's context_destroy must run after this and
/// before `teardown`.
- (void)waitIdle;
- (void)teardown;

@end

NS_ASSUME_NONNULL_END
