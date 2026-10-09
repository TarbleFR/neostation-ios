#import <Foundation/Foundation.h>

#include <simd/simd.h>

NS_ASSUME_NONNULL_BEGIN

/// Uniforms bound at fragment buffer 0 for every preset. Mirrors the MSL
/// `NeoUniforms` of LibretroShaderPrelude() byte for byte (160 bytes,
/// checked by _Static_assert in LibretroShaderLibrary.m and by the macOS
/// test against the compiled Metal reflection).
typedef struct {
  /// w, h, 1/w, 1/h of the screen's picture in console pixels: the
  /// console's nominal size for that screen when known (PSP 480x272 even if
  /// PPSSPP renders 960x544), else the size of the source part in texels.
  simd_float4 SourceSize;
  /// Same as SourceSize (single pass).
  simd_float4 OriginalSize;
  /// w, h, 1/w, 1/h of the destination rectangle in drawable pixels,
  /// expressed along the picture's own axes (swapped for odd rotations).
  simd_float4 OutputSize;
  simd_float2 uvOrigin;  // texture coordinates of the source part (top-left, before flip)
  simd_float2 uvExtent;  // texture-coordinate size of the source part
  simd_float2 uvMin;     // clamp limits: half a texel inside the part
  simd_float2 uvMax;
  uint32_t FrameCount;
  uint32_t flipped;      // 1 for bottom-left origin OpenGL frames
  uint32_t padding[2];
  float parameters[16];
} LibretroShaderUniforms;

/// How the source texture is sampled.
typedef NS_ENUM(NSInteger, LibretroShaderFilter) {
  LibretroShaderFilterNearest = 0,
  LibretroShaderFilterLinear,
  /// The preset does not set filter_linear0: follow the "Smooth picture"
  /// toggle, like RetroArch's global setting.
  LibretroShaderFilterFollowSmoothing,
};

/// One exposed parameter of a preset (RetroArch "#pragma parameter").
@interface LibretroShaderParameter : NSObject
@property(nonatomic, copy, readonly) NSString *identifier;  // e.g. "MASK_INTENSITY"
/// LibretroLocale key of the translated label (e.g. "paramMaskIntensity").
@property(nonatomic, copy, readonly) NSString *labelKey;
@property(nonatomic, readonly) float minimum;
@property(nonatomic, readonly) float maximum;
@property(nonatomic, readonly) float step;
@property(nonatomic, readonly) float defaultValue;
/// Index in LibretroShaderUniforms.parameters (0..15).
@property(nonatomic, readonly) NSUInteger slot;
/// Curvature / corner warp: forced to 0 on touch screens so the drawn
/// picture keeps matching the flat touch mapping.
@property(nonatomic, readonly) BOOL distortsGeometry;
@end

/// A post-processing preset NeoStation ships, hand-ported to Metal Shading
/// Language from libretro/slang-shaders. Single pass, applied to each game
/// screen separately, never to the skin or the menu. NeoStation does NOT
/// load RetroArch .slangp / .glslp / .cgp files.
@interface LibretroShaderPreset : NSObject
@property(nonatomic, copy, readonly) NSString *identifier;   // e.g. "crt-lottes-fast"
@property(nonatomic, copy, readonly) NSString *nameKey;      // LibretroLocale key of the translated name
@property(nonatomic, copy, readonly) NSString *category;     // "crt", "scanlines", "lcd", "scaling"
/// Upstream file it was ported from (relative to libretro/slang-shaders).
@property(nonatomic, copy, readonly) NSString *upstreamPath;
@property(nonatomic, copy, readonly) NSString *license;      // e.g. "Public domain", "MIT", "GPL-2.0-or-later"
@property(nonatomic, copy, readonly) NSString *authors;
@property(nonatomic, readonly) LibretroShaderFilter filter;
@property(nonatomic, copy, readonly) NSArray<LibretroShaderParameter *> *parameters;
/// MSL body defining exactly
///   fragment float4 neostation_fragment(NeoVertexOut in [[stage_in]],
///       texture2d<float> source [[texture(0)]], sampler smp [[sampler(0)]],
///       constant NeoUniforms &u [[buffer(0)]])
/// plus its own helper functions; the upstream copyright / licence header
/// is kept as a comment at its top.
@property(nonatomic, copy, readonly) NSString *fragmentSource;
/// Parameter values clamped to their ranges, defaults for missing ones.
- (NSDictionary<NSString *, NSNumber *> *)resolvedParameters:(nullable NSDictionary<NSString *, NSNumber *> *)stored;
@end

/// MSL language version used at runtime and by the macOS test
/// (MTLLanguageVersion2_4, available on iOS 15 and macOS 12).
FOUNDATION_EXPORT const NSUInteger LibretroShaderLanguageVersion;

/// Shared MSL prelude: `NeoVertexOut { float4 position [[position]]; float2
/// coord; }`, `NeoUniforms` (see LibretroShaderUniforms), the vertex
/// function `neostation_vertex` (quad of 4 vertices from buffer 0:
/// float4(ndc.x, ndc.y, coord.x, coord.y)), and the helpers
///   float4 NEO_SAMPLE(texture2d<float> source, sampler smp, constant NeoUniforms &u, float2 coord)
///   float NEO_PARAM(constant NeoUniforms &u, uint slot)
/// `coord` is in [0,1] over the screen's picture, top-left origin, with the
/// rotation already undone: the same meaning as vTexCoord in a slang shader
/// whose Source is exactly that picture. NEO_SAMPLE maps it into the
/// texture (origin, extent, flip) and clamps it to [uvMin, uvMax] so a DS /
/// 3DS screen never samples the other screen. Exactly:
///   uv = clamp(uvOrigin + float2(coord.x, flipped ? 1 - coord.y : coord.y) * uvExtent, uvMin, uvMax)
/// uvOrigin / uvExtent are the part's rectangle as stored in the texture
/// (smallest corner and size); `flipped` mirrors the picture vertically
/// inside that rectangle. Presets read parameter values with
/// NEO_PARAM(u, LibretroShaderParameter.slot).
FOUNDATION_EXPORT NSString *LibretroShaderPrelude(void);
/// Fragment of the "no shader" path (plain NEO_SAMPLE).
FOUNDATION_EXPORT NSString *LibretroShaderPassthroughSource(void);

@interface LibretroShaderLibrary : NSObject
/// Presets in menu order: sharp-bilinear, crt-lottes-fast,
/// crt-hyllian-fast, zfast-crt, scanlines-sine-abs, lcd3x, sameboy-lcd,
/// dot, zfast-lcd.
+ (NSArray<LibretroShaderPreset *> *)presets;
+ (nullable LibretroShaderPreset *)presetWithIdentifier:(NSString *)identifier;
/// Complete MSL source for a preset (prelude + fragment), or prelude +
/// pass-through when `preset` is nil.
+ (NSString *)sourceForPreset:(nullable LibretroShaderPreset *)preset;
@end

NS_ASSUME_NONNULL_END
