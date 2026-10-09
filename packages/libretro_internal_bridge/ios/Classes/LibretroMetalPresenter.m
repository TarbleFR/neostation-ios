#import "LibretroMetalPresenter.h"

#include <os/lock.h>
#include <simd/simd.h>

#define LIBRETRO_FRAMES_IN_FLIGHT 3

static NSString *const kLibretroShaderSource =
    @"#include <metal_stdlib>\n"
     "using namespace metal;\n"
     "struct LibretroVertexOut { float4 position [[position]]; float2 uv; };\n"
     "vertex LibretroVertexOut libretro_vertex(uint vid [[vertex_id]], constant float4 *quad [[buffer(0)]]) {\n"
     "  LibretroVertexOut out;\n"
     "  float4 v = quad[vid];\n"
     "  out.position = float4(v.x, v.y, 0.0, 1.0);\n"
     "  out.uv = float2(v.z, v.w);\n"
     "  return out;\n"
     "}\n"
     "fragment float4 libretro_fragment(LibretroVertexOut in [[stage_in]], texture2d<float> frame [[texture(0)]],\n"
     "                                  sampler smp [[sampler(0)]]) {\n"
     "  return float4(frame.sample(smp, in.uv).rgb, 1.0);\n"
     "}\n";

static inline uint8_t Expand5(uint32_t value) { return (uint8_t)((value << 3) | (value >> 2)); }
static inline uint8_t Expand6(uint32_t value) { return (uint8_t)((value << 2) | (value >> 4)); }

@implementation LibretroMetalPresenter {
  CAMetalLayer *_layer;
  id<MTLCommandQueue> _queue;
  id<MTLRenderPipelineState> _pipeline;
  id<MTLSamplerState> _nearest;
  id<MTLSamplerState> _linear;
  id<MTLTexture> _textures[LIBRETRO_FRAMES_IN_FLIGHT];
  NSUInteger _textureIndex;
  dispatch_semaphore_t _inFlight;
  NSMutableData *_conversion;
  os_unfair_lock _lock;
  CGRect _videoRect;
}

- (nullable instancetype)initWithLayer:(CAMetalLayer *)layer {
  self = [super init];
  if (self == nil) return nil;
  _device = MTLCreateSystemDefaultDevice();
  if (_device == nil) return nil;
  _layer = layer;
  layer.device = _device;
  layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
  layer.framebufferOnly = YES;
  layer.maximumDrawableCount = 3;
  _queue = [_device newCommandQueue];
  NSError *error = nil;
  id<MTLLibrary> library = [_device newLibraryWithSource:kLibretroShaderSource options:nil error:&error];
  if (library == nil) {
    NSLog(@"[Libretro] Metal shader compilation failed: %@", error);
    return nil;
  }
  MTLRenderPipelineDescriptor *descriptor = [MTLRenderPipelineDescriptor new];
  descriptor.vertexFunction = [library newFunctionWithName:@"libretro_vertex"];
  descriptor.fragmentFunction = [library newFunctionWithName:@"libretro_fragment"];
  descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
  _pipeline = [_device newRenderPipelineStateWithDescriptor:descriptor error:&error];
  if (_pipeline == nil) {
    NSLog(@"[Libretro] Metal pipeline creation failed: %@", error);
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
  _inFlight = dispatch_semaphore_create(LIBRETRO_FRAMES_IN_FLIGHT);
  _conversion = [NSMutableData data];
  _lock = OS_UNFAIR_LOCK_INIT;
  _videoRect = CGRectMake(0, 0, 1, 1);
  _aspectRatio = 4.0f / 3.0f;
  return self;
}

- (void)setDrawableSize:(CGSize)size {
  if (size.width < 1 || size.height < 1) return;
  _layer.drawableSize = size;
}

- (CGRect)normalizedVideoRect {
  os_unfair_lock_lock(&_lock);
  CGRect rect = _videoRect;
  os_unfair_lock_unlock(&_lock);
  return rect;
}

- (id<MTLTexture>)nextTextureForWidth:(unsigned)width height:(unsigned)height {
  NSUInteger index = _textureIndex;
  _textureIndex = (_textureIndex + 1) % LIBRETRO_FRAMES_IN_FLIGHT;
  id<MTLTexture> texture = _textures[index];
  if (texture == nil || texture.width < width || texture.height < height) {
    NSUInteger newWidth = MAX((NSUInteger)width, texture.width);
    NSUInteger newHeight = MAX((NSUInteger)height, texture.height);
    MTLTextureDescriptor *descriptor =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                           width:newWidth
                                                          height:newHeight
                                                       mipmapped:NO];
    descriptor.usage = MTLTextureUsageShaderRead;
    descriptor.storageMode = MTLStorageModeShared;
    texture = [_device newTextureWithDescriptor:descriptor];
    _textures[index] = texture;
  }
  return texture;
}

- (void)presentSoftwareFrame:(const void *)data
                       width:(unsigned)width
                      height:(unsigned)height
                       pitch:(size_t)pitch
                      format:(enum retro_pixel_format)format {
  if (data == NULL || width == 0 || height == 0) return;
  dispatch_semaphore_wait(_inFlight, DISPATCH_TIME_FOREVER);
  id<MTLTexture> texture = [self nextTextureForWidth:width height:height];
  if (texture == nil) {
    dispatch_semaphore_signal(_inFlight);
    return;
  }
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
  [self encodeTexture:texture width:width height:height flipped:NO completion:nil];
}

- (void)presentTexture:(id<MTLTexture>)texture
                 width:(unsigned)width
                height:(unsigned)height
               flipped:(BOOL)flipped
            completion:(dispatch_block_t)completion {
  dispatch_semaphore_wait(_inFlight, DISPATCH_TIME_FOREVER);
  [self encodeTexture:texture width:width height:height flipped:flipped completion:completion];
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

- (void)encodeTexture:(id<MTLTexture>)texture
                width:(unsigned)width
               height:(unsigned)height
              flipped:(BOOL)flipped
           completion:(dispatch_block_t)completion {
  id<CAMetalDrawable> drawable = [_layer nextDrawable];
  if (drawable == nil || texture == nil || width == 0 || height == 0) {
    dispatch_semaphore_signal(_inFlight);
    if (completion != nil) completion();
    return;
  }
  const double drawableWidth = (double)drawable.texture.width;
  const double drawableHeight = (double)drawable.texture.height;
  double aspect = self.aspectRatio > 0 ? self.aspectRatio : (double)width / (double)height;
  const unsigned rotation = self.rotation % 4;
  if (rotation % 2 == 1) aspect = 1.0 / aspect;
  double videoWidth = drawableWidth;
  double videoHeight = drawableWidth / aspect;
  if (videoHeight > drawableHeight) {
    videoHeight = drawableHeight;
    videoWidth = drawableHeight * aspect;
  }
  const double originX = (drawableWidth - videoWidth) / 2.0;
  const double originY = (drawableHeight - videoHeight) / 2.0;
  os_unfair_lock_lock(&_lock);
  _videoRect = CGRectMake(originX / drawableWidth, originY / drawableHeight, videoWidth / drawableWidth,
                          videoHeight / drawableHeight);
  os_unfair_lock_unlock(&_lock);

  const float left = (float)(originX / drawableWidth * 2.0 - 1.0);
  const float right = (float)((originX + videoWidth) / drawableWidth * 2.0 - 1.0);
  const float top = (float)(1.0 - originY / drawableHeight * 2.0);
  const float bottom = (float)(1.0 - (originY + videoHeight) / drawableHeight * 2.0);
  const float maxU = (float)width / (float)texture.width;
  const float maxV = (float)height / (float)texture.height;
  // Image corners clockwise from top-left. A rotation of N quarter turns
  // counter-clockwise shows image corner (i + N) at screen corner i.
  simd_float2 corners[4] = {
      {0.0f, flipped ? maxV : 0.0f},
      {maxU, flipped ? maxV : 0.0f},
      {maxU, flipped ? 0.0f : maxV},
      {0.0f, flipped ? 0.0f : maxV},
  };
  simd_float2 topLeft = corners[(0 + rotation) % 4];
  simd_float2 topRight = corners[(1 + rotation) % 4];
  simd_float2 bottomRight = corners[(2 + rotation) % 4];
  simd_float2 bottomLeft = corners[(3 + rotation) % 4];
  const simd_float4 quad[4] = {
      {left, top, topLeft.x, topLeft.y},
      {left, bottom, bottomLeft.x, bottomLeft.y},
      {right, top, topRight.x, topRight.y},
      {right, bottom, bottomRight.x, bottomRight.y},
  };

  MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
  pass.colorAttachments[0].texture = drawable.texture;
  pass.colorAttachments[0].loadAction = MTLLoadActionClear;
  pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
  pass.colorAttachments[0].storeAction = MTLStoreActionStore;
  id<MTLCommandBuffer> buffer = [_queue commandBuffer];
  id<MTLRenderCommandEncoder> encoder = [buffer renderCommandEncoderWithDescriptor:pass];
  [encoder setRenderPipelineState:_pipeline];
  [encoder setVertexBytes:quad length:sizeof(quad) atIndex:0];
  [encoder setFragmentTexture:texture atIndex:0];
  [encoder setFragmentSamplerState:(self.smooth ? _linear : _nearest) atIndex:0];
  [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
  [encoder endEncoding];
  [buffer presentDrawable:drawable];
  dispatch_semaphore_t semaphore = _inFlight;
  [buffer addCompletedHandler:^(__unused id<MTLCommandBuffer> completed) {
    dispatch_semaphore_signal(semaphore);
    if (completion != nil) completion();
  }];
  [buffer commit];
}

@end
