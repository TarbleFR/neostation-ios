// Behavioural test of NeoStation's shader presets on macOS. Every preset and
// the plain path compile with LibretroShaderLanguageVersion and build a
// render pipeline whose fragment buffer 0 is the 160-byte NeoUniforms
// (checked with Metal reflection). Each renders a 64x48 checkerboard that
// fills only the left half of a 128x48 texture into a 256x192 target, with
// the default parameters: finite output with alpha 1, a picture that is not
// uniformly black, and an output that does not change with the colour of the
// other half (NEO_SAMPLE clamps inside the part). The plain path reproduces
// the checkerboard exactly, also from a bottom-left origin texture; crt-lottes
// curvature changes the picture; crt-lottes shows black outside the picture
// (all-white source, CURVATURE 0.25, CORNER 0 and 1: black output corners, as
// upstream's clamp_to_border, lit centre); sharp-bilinear survives an output
// smaller than its source. Run by test/libretro_shader_test.py.
// `shader_test --dump DIR` writes every complete MSL source to DIR instead.
// Exit code 3: no Metal device (the catalog checks still ran).
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#import "LibretroShaderLibrary.h"

#include <math.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>

enum {
  kTextureWidth = 128,  // the source part is the left half
  kTextureHeight = 48,
  kPartWidth = 64,
  kTargetWidth = 256,
  kTargetHeight = 192,
  kCell = 4,  // checkerboard cell, in source pixels
  kExitNoDevice = 3,
};

static int failures = 0;

static void Check(BOOL condition, NSString *message) {
  if (condition) {
    printf("PASS %s\n", message.UTF8String);
  } else {
    printf("FAIL %s\n", message.UTF8String);
    failures++;
  }
}

static NSString *Name(LibretroShaderPreset *preset) {
  return preset != nil ? preset.identifier : @"passthrough";
}

// BGRA8Unorm pixel as stored in memory (little-endian).
static uint32_t BGRA(uint32_t red, uint32_t green, uint32_t blue) {
  return blue | (green << 8) | (red << 16) | 0xFF000000u;
}

static uint32_t CheckerPixel(NSUInteger x, NSUInteger y) {
  return ((x / kCell) + (y / kCell)) % 2 == 0 ? BGRA(240, 180, 40) : BGRA(16, 64, 200);
}

#pragma mark - Catalog (no Metal device needed)

static void CheckCatalog(void) {
  Check(sizeof(LibretroShaderUniforms) == 160, @"LibretroShaderUniforms is 160 bytes");
  Check(LibretroShaderLanguageVersion == (NSUInteger)MTLLanguageVersion2_4,
        @"LibretroShaderLanguageVersion is MTLLanguageVersion2_4");
  NSArray<NSString *> *order = @[
    @"sharp-bilinear", @"crt-lottes-fast", @"crt-hyllian-fast", @"zfast-crt", @"scanlines-sine-abs", @"lcd3x",
    @"sameboy-lcd", @"dot", @"zfast-lcd"
  ];
  NSArray<LibretroShaderPreset *> *presets = [LibretroShaderLibrary presets];
  Check([[presets valueForKey:@"identifier"] isEqualToArray:order], @"presets in menu order");
  Check([LibretroShaderLibrary presetWithIdentifier:@"zfast-lcd"] == presets.lastObject, @"preset found by identifier");
  Check([LibretroShaderLibrary presetWithIdentifier:@"crt-royale"] == nil, @"unknown preset is nil");
  NSString *plain = [LibretroShaderLibrary sourceForPreset:nil];
  Check([plain isEqualToString:[LibretroShaderPrelude() stringByAppendingString:LibretroShaderPassthroughSource()]],
        @"nil preset gives prelude + pass-through");

  for (LibretroShaderPreset *preset in presets) {
    NSString *name = preset.identifier;
    NSString *source = [LibretroShaderLibrary sourceForPreset:preset];
    Check([source hasPrefix:LibretroShaderPrelude()] && [source hasSuffix:preset.fragmentSource],
          [NSString stringWithFormat:@"%@: source is prelude + fragment", name]);
    Check([preset.fragmentSource containsString:@"fragment float4 neostation_fragment("],
          [NSString stringWithFormat:@"%@: defines neostation_fragment", name]);
    Check(preset.license.length > 0 && preset.authors.length > 0 && [preset.upstreamPath hasSuffix:@".slang"],
          [NSString stringWithFormat:@"%@: licence, authors and upstream path", name]);
    NSMutableIndexSet *slots = [NSMutableIndexSet indexSet];
    BOOL ranges = YES;
    for (LibretroShaderParameter *parameter in preset.parameters) {
      if (parameter.slot >= 16 || [slots containsIndex:parameter.slot]) ranges = NO;
      [slots addIndex:parameter.slot];
      if (!(parameter.minimum <= parameter.defaultValue && parameter.defaultValue <= parameter.maximum)) ranges = NO;
      if (!(parameter.step > 0)) ranges = NO;
    }
    Check(ranges, [NSString stringWithFormat:@"%@: unique slots below 16, defaults inside their ranges", name]);

    NSDictionary<NSString *, NSNumber *> *defaults = [preset resolvedParameters:nil];
    BOOL defaultsMatch = defaults.count == preset.parameters.count;
    for (LibretroShaderParameter *parameter in preset.parameters) {
      if (defaults[parameter.identifier].floatValue != parameter.defaultValue) defaultsMatch = NO;
    }
    Check(defaultsMatch, [NSString stringWithFormat:@"%@: missing values resolve to defaults", name]);

    LibretroShaderParameter *first = preset.parameters.firstObject;
    if (first == nil) continue;
    NSString *key = first.identifier;
    NSDictionary *high = [preset resolvedParameters:@{key : @(first.maximum + 100.0f), @"UNKNOWN" : @1}];
    NSDictionary *low = [preset resolvedParameters:@{key : @(first.minimum - 100.0f)}];
    NSDictionary *invalid = [preset resolvedParameters:@{key : @(NAN)}];
    NSDictionary *text = [preset resolvedParameters:(NSDictionary *)@{key : @"2"}];
    Check([high[key] floatValue] == first.maximum && low[key] != nil && [low[key] floatValue] == first.minimum &&
              high[@"UNKNOWN"] == nil,
          [NSString stringWithFormat:@"%@: stored values clamped to their range, unknown ones dropped", name]);
    Check([invalid[key] floatValue] == first.defaultValue && [text[key] floatValue] == first.defaultValue,
          [NSString stringWithFormat:@"%@: invalid stored values give the default", name]);
  }
}

static BOOL DumpSources(NSString *directory) {
  NSError *error = nil;
  if (![[NSFileManager defaultManager] createDirectoryAtPath:directory
                                 withIntermediateDirectories:YES
                                                  attributes:nil
                                                       error:&error]) {
    printf("FAIL cannot create %s: %s\n", directory.UTF8String, error.localizedDescription.UTF8String);
    return NO;
  }
  NSMutableArray *presets = [NSMutableArray arrayWithObject:[NSNull null]];
  [presets addObjectsFromArray:[LibretroShaderLibrary presets]];
  for (id entry in presets) {
    LibretroShaderPreset *preset = entry == [NSNull null] ? nil : entry;
    NSString *path = [directory stringByAppendingPathComponent:[Name(preset) stringByAppendingPathExtension:@"metal"]];
    if (![[LibretroShaderLibrary sourceForPreset:preset] writeToFile:path
                                                          atomically:YES
                                                            encoding:NSUTF8StringEncoding
                                                               error:&error]) {
      printf("FAIL cannot write %s: %s\n", path.UTF8String, error.localizedDescription.UTF8String);
      return NO;
    }
    printf("wrote %s\n", path.UTF8String);
  }
  return YES;
}

#pragma mark - Metal rendering

static float HalfToFloat(uint16_t bits) {
  uint32_t exponent = (bits >> 10) & 0x1f;
  uint32_t mantissa = bits & 0x3ff;
  float value;
  if (exponent == 0) {
    value = ldexpf((float)mantissa, -24);
  } else if (exponent == 31) {
    value = mantissa != 0 ? NAN : INFINITY;
  } else {
    value = ldexpf((float)(mantissa | 0x400), (int)exponent - 25);
  }
  return (bits & 0x8000) != 0 ? -value : value;
}

/// The checkerboard in the left half, `outside` in the right half. With
/// `bottomUp`, rows are stored bottom-left origin (OpenGL frames).
static id<MTLTexture> MakeSource(id<MTLDevice> device, uint32_t outside, BOOL bottomUp) {
  MTLTextureDescriptor *descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                        width:kTextureWidth
                                                                                       height:kTextureHeight
                                                                                    mipmapped:NO];
  descriptor.usage = MTLTextureUsageShaderRead;
  descriptor.storageMode = MTLStorageModeManaged;
  id<MTLTexture> texture = [device newTextureWithDescriptor:descriptor];
  NSMutableData *pixels = [NSMutableData dataWithLength:kTextureWidth * kTextureHeight * 4];
  uint32_t *data = pixels.mutableBytes;
  for (NSUInteger y = 0; y < kTextureHeight; y++) {
    NSUInteger row = bottomUp ? kTextureHeight - 1 - y : y;
    for (NSUInteger x = 0; x < kTextureWidth; x++) {
      data[row * kTextureWidth + x] = x < kPartWidth ? CheckerPixel(x, y) : outside;
    }
  }
  [texture replaceRegion:MTLRegionMake2D(0, 0, kTextureWidth, kTextureHeight)
             mipmapLevel:0
               withBytes:pixels.bytes
             bytesPerRow:kTextureWidth * 4];
  return texture;
}

/// Every texel of the texture (part and other half) is `color`.
static id<MTLTexture> MakeSolidSource(id<MTLDevice> device, uint32_t color) {
  MTLTextureDescriptor *descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                        width:kTextureWidth
                                                                                       height:kTextureHeight
                                                                                    mipmapped:NO];
  descriptor.usage = MTLTextureUsageShaderRead;
  descriptor.storageMode = MTLStorageModeManaged;
  id<MTLTexture> texture = [device newTextureWithDescriptor:descriptor];
  NSMutableData *pixels = [NSMutableData dataWithLength:kTextureWidth * kTextureHeight * 4];
  uint32_t *data = pixels.mutableBytes;
  for (NSUInteger index = 0; index < (NSUInteger)(kTextureWidth * kTextureHeight); index++) data[index] = color;
  [texture replaceRegion:MTLRegionMake2D(0, 0, kTextureWidth, kTextureHeight)
             mipmapLevel:0
               withBytes:pixels.bytes
             bytesPerRow:kTextureWidth * 4];
  return texture;
}

static id<MTLSamplerState> MakeSampler(id<MTLDevice> device, BOOL linear) {
  MTLSamplerDescriptor *descriptor = [MTLSamplerDescriptor new];
  descriptor.sAddressMode = MTLSamplerAddressModeClampToEdge;
  descriptor.tAddressMode = MTLSamplerAddressModeClampToEdge;
  descriptor.minFilter = linear ? MTLSamplerMinMagFilterLinear : MTLSamplerMinMagFilterNearest;
  descriptor.magFilter = descriptor.minFilter;
  return [device newSamplerStateWithDescriptor:descriptor];
}

/// What the presenter would pass for the left half of the texture.
static LibretroShaderUniforms MakeUniforms(LibretroShaderPreset *preset, NSDictionary *stored) {
  LibretroShaderUniforms uniforms;
  memset(&uniforms, 0, sizeof(uniforms));
  uniforms.SourceSize = simd_make_float4(kPartWidth, kTextureHeight, 1.0f / kPartWidth, 1.0f / kTextureHeight);
  uniforms.OriginalSize = uniforms.SourceSize;
  uniforms.OutputSize = simd_make_float4(kTargetWidth, kTargetHeight, 1.0f / kTargetWidth, 1.0f / kTargetHeight);
  uniforms.uvOrigin = simd_make_float2(0.0f, 0.0f);
  uniforms.uvExtent = simd_make_float2((float)kPartWidth / kTextureWidth, 1.0f);
  uniforms.uvMin = simd_make_float2(0.5f / kTextureWidth, 0.5f / kTextureHeight);
  uniforms.uvMax = simd_make_float2((kPartWidth - 0.5f) / kTextureWidth, (kTextureHeight - 0.5f) / kTextureHeight);
  NSDictionary<NSString *, NSNumber *> *values = [preset resolvedParameters:stored];
  for (LibretroShaderParameter *parameter in preset.parameters) {
    uniforms.parameters[parameter.slot] = values[parameter.identifier].floatValue;
  }
  return uniforms;
}

/// Draws the quad into a fresh target and returns its pixels (tightly packed).
static NSData *Render(id<MTLDevice> device, id<MTLCommandQueue> queue, id<MTLRenderPipelineState> pipeline,
                      MTLPixelFormat format, NSUInteger bytesPerPixel, id<MTLTexture> source,
                      id<MTLSamplerState> sampler, LibretroShaderUniforms uniforms) {
  MTLTextureDescriptor *descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format
                                                                                        width:kTargetWidth
                                                                                       height:kTargetHeight
                                                                                    mipmapped:NO];
  descriptor.usage = MTLTextureUsageRenderTarget;
  descriptor.storageMode = MTLStorageModePrivate;
  id<MTLTexture> target = [device newTextureWithDescriptor:descriptor];
  NSUInteger bytesPerRow = kTargetWidth * bytesPerPixel;
  id<MTLBuffer> readback = [device newBufferWithLength:bytesPerRow * kTargetHeight
                                               options:MTLResourceStorageModeShared];
  if (target == nil || readback == nil) return nil;

  MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
  pass.colorAttachments[0].texture = target;
  pass.colorAttachments[0].loadAction = MTLLoadActionClear;
  pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
  pass.colorAttachments[0].storeAction = MTLStoreActionStore;
  // Same strip as the presenter: left-top, left-bottom, right-top, right-bottom.
  const simd_float4 quad[4] = {
      {-1.0f, 1.0f, 0.0f, 0.0f},
      {-1.0f, -1.0f, 0.0f, 1.0f},
      {1.0f, 1.0f, 1.0f, 0.0f},
      {1.0f, -1.0f, 1.0f, 1.0f},
  };
  id<MTLCommandBuffer> buffer = [queue commandBuffer];
  id<MTLRenderCommandEncoder> encoder = [buffer renderCommandEncoderWithDescriptor:pass];
  [encoder setRenderPipelineState:pipeline];
  [encoder setVertexBytes:quad length:sizeof(quad) atIndex:0];
  [encoder setFragmentTexture:source atIndex:0];
  [encoder setFragmentSamplerState:sampler atIndex:0];
  [encoder setFragmentBytes:&uniforms length:sizeof(uniforms) atIndex:0];
  [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
  [encoder endEncoding];
  id<MTLBlitCommandEncoder> blit = [buffer blitCommandEncoder];
  [blit copyFromTexture:target
                   sourceSlice:0
                   sourceLevel:0
                  sourceOrigin:MTLOriginMake(0, 0, 0)
                    sourceSize:MTLSizeMake(kTargetWidth, kTargetHeight, 1)
                      toBuffer:readback
             destinationOffset:0
        destinationBytesPerRow:bytesPerRow
      destinationBytesPerImage:bytesPerRow * kTargetHeight];
  [blit endEncoding];
  [buffer commit];
  [buffer waitUntilCompleted];
  if (buffer.status != MTLCommandBufferStatusCompleted) {
    printf("command buffer error: %s\n", buffer.error.localizedDescription.UTF8String);
    return nil;
  }
  return [NSData dataWithBytes:readback.contents length:readback.length];
}

/// RGBA16Float pixels: every colour finite, alpha 1, colours in [0, 8].
static BOOL FiniteAndOpaque(NSData *pixels, float *maximum) {
  if (pixels == nil) return NO;
  const uint16_t *halves = pixels.bytes;
  NSUInteger count = pixels.length / sizeof(uint16_t);
  BOOL valid = YES;
  float brightest = 0;
  for (NSUInteger index = 0; index + 3 < count; index += 4) {
    for (NSUInteger channel = 0; channel < 3; channel++) {
      float value = HalfToFloat(halves[index + channel]);
      if (!isfinite(value) || value < -0.001f || value > 8.0f) valid = NO;
      if (isfinite(value) && value > brightest) brightest = value;
    }
    if (fabsf(HalfToFloat(halves[index + 3]) - 1.0f) > 0.001f) valid = NO;
  }
  if (maximum != NULL) *maximum = brightest;
  return valid;
}

static int MaxDifference(NSData *a, NSData *b) {
  if (a == nil || b == nil || a.length != b.length) return 256;
  const uint8_t *x = a.bytes;
  const uint8_t *y = b.bytes;
  int worst = 0;
  for (NSUInteger index = 0; index < a.length; index++) {
    int difference = abs((int)x[index] - (int)y[index]);
    if (difference > worst) worst = difference;
  }
  return worst;
}

static NSUInteger DifferentPixels(NSData *a, NSData *b, int tolerance) {
  if (a == nil || b == nil || a.length != b.length) return NSUIntegerMax;
  const uint8_t *x = a.bytes;
  const uint8_t *y = b.bytes;
  NSUInteger count = 0;
  for (NSUInteger index = 0; index + 3 < a.length; index += 4) {
    for (NSUInteger channel = 0; channel < 4; channel++) {
      if (abs((int)x[index + channel] - (int)y[index + channel]) > tolerance) {
        count++;
        break;
      }
    }
  }
  return count;
}

/// BGRA8 picture: opaque, some pixel at least 64/255 bright and not uniform.
static BOOL VisiblePicture(NSData *pixels) {
  if (pixels == nil) return NO;
  const uint32_t *data = pixels.bytes;
  NSUInteger count = pixels.length / 4;
  uint32_t brightest = 0;
  BOOL uniform = YES;
  for (NSUInteger index = 0; index < count; index++) {
    uint32_t pixel = data[index];
    if ((pixel >> 24) != 0xFF) return NO;
    for (uint32_t shift = 0; shift < 24; shift += 8) {
      uint32_t channel = (pixel >> shift) & 0xFF;
      if (channel > brightest) brightest = channel;
    }
    if (pixel != data[0]) uniform = NO;
  }
  return brightest >= 64 && !uniform;
}

/// Largest colour channel (0-255) of the target's BGRA8 pixel (x, y).
static uint32_t Brightness(NSData *pixels, NSUInteger x, NSUInteger y) {
  if (pixels == nil || (y * kTargetWidth + x + 1) * 4 > pixels.length) return 255;
  const uint32_t *data = pixels.bytes;
  const uint32_t pixel = data[y * kTargetWidth + x];
  uint32_t brightest = 0;
  for (uint32_t shift = 0; shift < 24; shift += 8) brightest = MAX(brightest, (pixel >> shift) & 0xFF);
  return brightest;
}

static BOOL ReproducesCheckerboard(NSData *pixels) {
  if (pixels == nil) return NO;
  const uint32_t *data = pixels.bytes;
  for (NSUInteger y = 0; y < kTargetHeight; y++) {
    for (NSUInteger x = 0; x < kTargetWidth; x++) {
      uint32_t expected = CheckerPixel(x * kPartWidth / kTargetWidth, y * kTextureHeight / kTargetHeight);
      if (data[y * kTargetWidth + x] != expected) {
        printf("pixel (%lu, %lu) is %08x, expected %08x\n", (unsigned long)x, (unsigned long)y,
               data[y * kTargetWidth + x], expected);
        return NO;
      }
    }
  }
  return YES;
}

@interface Fixture : NSObject
@property(nonatomic) id<MTLDevice> device;
@property(nonatomic) id<MTLCommandQueue> queue;
/// Checkerboard part, white or black right half.
@property(nonatomic) id<MTLTexture> sourceWhiteOutside;
@property(nonatomic) id<MTLTexture> sourceBlackOutside;
/// Checkerboard part stored bottom-left origin.
@property(nonatomic) id<MTLTexture> sourceBottomUp;
/// White everywhere, part and other half.
@property(nonatomic) id<MTLTexture> sourceWhite;
@property(nonatomic) id<MTLSamplerState> nearest;
@property(nonatomic) id<MTLSamplerState> linear;
@end

@implementation Fixture
@end

static void CheckReflection(MTLRenderPipelineReflection *reflection, NSString *name) {
  id<MTLBufferBinding> uniforms = nil;
  for (id<MTLBinding> binding in reflection.fragmentBindings) {
    if (binding.type == MTLBindingTypeBuffer && binding.index == 0) uniforms = (id<MTLBufferBinding>)binding;
  }
  Check(uniforms != nil && uniforms.bufferDataSize == sizeof(LibretroShaderUniforms),
        [NSString stringWithFormat:@"%@: fragment buffer 0 is %lu bytes (reflection)", name,
                                   (unsigned long)(uniforms != nil ? uniforms.bufferDataSize : 0)]);
  MTLStructType *layout = uniforms.bufferStructType;
  const struct {
    const char *member;
    size_t offset;
  } members[] = {
      {"SourceSize", offsetof(LibretroShaderUniforms, SourceSize)},
      {"OriginalSize", offsetof(LibretroShaderUniforms, OriginalSize)},
      {"OutputSize", offsetof(LibretroShaderUniforms, OutputSize)},
      {"uvOrigin", offsetof(LibretroShaderUniforms, uvOrigin)},
      {"uvExtent", offsetof(LibretroShaderUniforms, uvExtent)},
      {"uvMin", offsetof(LibretroShaderUniforms, uvMin)},
      {"uvMax", offsetof(LibretroShaderUniforms, uvMax)},
      {"FrameCount", offsetof(LibretroShaderUniforms, FrameCount)},
      {"flipped", offsetof(LibretroShaderUniforms, flipped)},
      {"parameters", offsetof(LibretroShaderUniforms, parameters)},
  };
  BOOL offsets = layout != nil;
  for (size_t index = 0; index < sizeof(members) / sizeof(members[0]); index++) {
    MTLStructMember *member = [layout memberByName:@(members[index].member)];
    if (member == nil) {
      printf("NOTE %s: member %s not reflected\n", name.UTF8String, members[index].member);
    } else if (member.offset != members[index].offset) {
      printf("%s: %s at %lu in Metal, %zu in C\n", name.UTF8String, members[index].member,
             (unsigned long)member.offset, members[index].offset);
      offsets = NO;
    }
  }
  Check(offsets, [NSString stringWithFormat:@"%@: NeoUniforms member offsets match LibretroShaderUniforms", name]);
}

/// crt-lottes-fast at full curvature with CORNER 0 and 1: the warp pushes the
/// output corners outside the picture and the corner vignette is not zero
/// there, so every tap of those pixels must read upstream's black border
/// (clamp_to_border), never the edge colour of an all-white source. The
/// centre stays lit. The other half is white too: only the border emulation
/// can make the corners black.
static void TestLottesCorners(Fixture *fixture, LibretroShaderPreset *preset, id<MTLRenderPipelineState> pipeline,
                              id<MTLSamplerState> sampler) {
  const NSUInteger corners[4][2] = {
      {0, 0}, {kTargetWidth - 1, 0}, {0, kTargetHeight - 1}, {kTargetWidth - 1, kTargetHeight - 1}};
  for (NSNumber *corner in @[ @0, @1 ]) {
    LibretroShaderUniforms uniforms = MakeUniforms(preset, @{@"CURVATURE" : @0.25, @"CORNER" : corner});
    NSData *pixels = Render(fixture.device, fixture.queue, pipeline, MTLPixelFormatBGRA8Unorm, 4, fixture.sourceWhite,
                            sampler, uniforms);
    uint32_t brightest = 0;
    for (NSUInteger index = 0; index < 4; index++) {
      brightest = MAX(brightest, Brightness(pixels, corners[index][0], corners[index][1]));
    }
    Check(pixels != nil && brightest <= 2,
          [NSString stringWithFormat:@"crt-lottes-fast: CURVATURE 0.25, CORNER %@: the four output corners are black "
                                     @"on a white source (brightest %u/255)",
                                     corner, brightest]);
    const uint32_t centre = Brightness(pixels, kTargetWidth / 2, kTargetHeight / 2);
    Check(pixels != nil && centre >= 64,
          [NSString stringWithFormat:@"crt-lottes-fast: CURVATURE 0.25, CORNER %@: the centre is lit (%u/255)", corner,
                                     centre]);
  }
}

static void TestPreset(Fixture *fixture, LibretroShaderPreset *preset) {
  NSString *name = Name(preset);
  id<MTLDevice> device = fixture.device;
  MTLCompileOptions *options = [MTLCompileOptions new];
  options.languageVersion = (MTLLanguageVersion)LibretroShaderLanguageVersion;
  NSError *error = nil;
  id<MTLLibrary> library = [device newLibraryWithSource:[LibretroShaderLibrary sourceForPreset:preset]
                                                options:options
                                                  error:&error];
  if (error != nil) {
    // Warnings come back with a library; errors without one.
    printf("%s compiler output:\n%s\n", name.UTF8String, error.localizedDescription.UTF8String);
  }
  Check(library != nil, [NSString stringWithFormat:@"%@: compiles as MSL 2.4", name]);
  if (library == nil) return;

  MTLRenderPipelineDescriptor *descriptor = [MTLRenderPipelineDescriptor new];
  descriptor.vertexFunction = [library newFunctionWithName:@"neostation_vertex"];
  descriptor.fragmentFunction = [library newFunctionWithName:@"neostation_fragment"];
  descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
  MTLAutoreleasedRenderPipelineReflection reflection = nil;
  error = nil;
  id<MTLRenderPipelineState> pipeline =
      [device newRenderPipelineStateWithDescriptor:descriptor
                                           options:MTLPipelineOptionBindingInfo | MTLPipelineOptionBufferTypeInfo
                                        reflection:&reflection
                                             error:&error];
  Check(pipeline != nil, [NSString stringWithFormat:@"%@: BGRA8Unorm pipeline (%@)", name,
                                                    error.localizedDescription ?: @"ok"]);
  if (pipeline == nil) return;
  CheckReflection(reflection, name);
  descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA16Float;
  id<MTLRenderPipelineState> floatPipeline = [device newRenderPipelineStateWithDescriptor:descriptor error:&error];
  Check(floatPipeline != nil, [NSString stringWithFormat:@"%@: RGBA16Float pipeline", name]);
  if (floatPipeline == nil) return;

  LibretroShaderFilter filter = preset != nil ? preset.filter : LibretroShaderFilterNearest;
  id<MTLSamplerState> sampler = filter == LibretroShaderFilterNearest ? fixture.nearest : fixture.linear;
  LibretroShaderUniforms uniforms = MakeUniforms(preset, nil);
  id<MTLCommandQueue> queue = fixture.queue;

  float brightest = 0;
  NSData *floats = Render(device, queue, floatPipeline, MTLPixelFormatRGBA16Float, 8, fixture.sourceWhiteOutside,
                          sampler, uniforms);
  BOOL finite = FiniteAndOpaque(floats, &brightest);
  Check(finite, [NSString stringWithFormat:@"%@: finite colours in [0, 8] and alpha 1 everywhere (brightest %.3f)",
                                           name, brightest]);
  if (filter == LibretroShaderFilterFollowSmoothing) {
    NSData *nearest = Render(device, queue, floatPipeline, MTLPixelFormatRGBA16Float, 8, fixture.sourceWhiteOutside,
                             fixture.nearest, uniforms);
    Check(FiniteAndOpaque(nearest, NULL), [NSString stringWithFormat:@"%@: also finite with nearest sampling", name]);
  }

  NSData *white = Render(device, queue, pipeline, MTLPixelFormatBGRA8Unorm, 4, fixture.sourceWhiteOutside, sampler,
                         uniforms);
  NSData *black = Render(device, queue, pipeline, MTLPixelFormatBGRA8Unorm, 4, fixture.sourceBlackOutside, sampler,
                         uniforms);
  Check(VisiblePicture(white), [NSString stringWithFormat:@"%@: opaque picture, not uniformly black", name]);
  int leak = MaxDifference(white, black);
  Check(leak <= 2, [NSString stringWithFormat:@"%@: the other half of the texture never shows (difference %d/255)",
                                              name, leak]);

  if (preset == nil) {
    Check(ReproducesCheckerboard(white), @"passthrough: reproduces the source part exactly");
    uniforms.flipped = 1;
    NSData *flipped = Render(device, queue, pipeline, MTLPixelFormatBGRA8Unorm, 4, fixture.sourceBottomUp,
                             fixture.nearest, uniforms);
    Check(ReproducesCheckerboard(flipped), @"passthrough: bottom-left origin texture shown upright");
    return;
  }

  for (LibretroShaderParameter *parameter in preset.parameters) {
    if (!parameter.distortsGeometry || ![parameter.identifier isEqualToString:@"CURVATURE"]) continue;
    LibretroShaderUniforms flat = MakeUniforms(preset, @{parameter.identifier : @0});
    NSData *straight = Render(device, queue, pipeline, MTLPixelFormatBGRA8Unorm, 4, fixture.sourceWhiteOutside,
                              sampler, flat);
    NSUInteger changed = DifferentPixels(white, straight, 2);
    Check(changed != NSUIntegerMax && changed >= 200,
          [NSString stringWithFormat:@"%@: curvature 0 changes %lu pixels against the default", name,
                                     (unsigned long)changed]);
  }

  if ([preset.identifier isEqualToString:@"crt-lottes-fast"]) {
    TestLottesCorners(fixture, preset, pipeline, sampler);
  }

  if ([preset.identifier isEqualToString:@"sharp-bilinear"]) {
    // The source is taller than the output: upstream's automatic prescale
    // floors to 0 and divides by it.
    LibretroShaderUniforms small = MakeUniforms(preset, @{@"AUTO_PRESCALE" : @1});
    small.OutputSize = simd_make_float4(32.0f, 24.0f, 1.0f / 32.0f, 1.0f / 24.0f);
    NSData *guarded = Render(device, queue, floatPipeline, MTLPixelFormatRGBA16Float, 8,
                             fixture.sourceWhiteOutside, sampler, small);
    Check(FiniteAndOpaque(guarded, NULL), @"sharp-bilinear: automatic prescale never divides by zero");
  }
}

int main(int argc, const char *argv[]) {
  @autoreleasepool {
    CheckCatalog();
    if (argc == 3 && strcmp(argv[1], "--dump") == 0) {
      NSString *directory = [NSString stringWithUTF8String:argv[2]];
      if (directory == nil || !DumpSources(directory)) return 1;
      return failures == 0 ? 0 : 1;
    }

    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (device == nil) device = MTLCopyAllDevices().firstObject;
    if (device == nil) {
      printf("NO METAL DEVICE\n");
      return failures == 0 ? kExitNoDevice : 1;
    }
    printf("Metal device: %s\n", device.name.UTF8String);

    Fixture *fixture = [Fixture new];
    fixture.device = device;
    fixture.queue = [device newCommandQueue];
    fixture.sourceWhiteOutside = MakeSource(device, BGRA(255, 255, 255), NO);
    fixture.sourceBlackOutside = MakeSource(device, BGRA(0, 0, 0), NO);
    fixture.sourceBottomUp = MakeSource(device, BGRA(255, 0, 255), YES);
    fixture.sourceWhite = MakeSolidSource(device, BGRA(255, 255, 255));
    fixture.nearest = MakeSampler(device, NO);
    fixture.linear = MakeSampler(device, YES);

    TestPreset(fixture, nil);
    for (LibretroShaderPreset *preset in [LibretroShaderLibrary presets]) {
      TestPreset(fixture, preset);
    }
  }
  if (failures != 0) {
    printf("%d shader check(s) failed\n", failures);
    return 1;
  }
  printf("All shader checks passed\n");
  return 0;
}
