#import "LibretroShaderLibrary.h"

#include <math.h>
#include <stddef.h>

// The C mirror must keep the MSL layout of NeoUniforms: float4 members are
// 16-byte aligned, float2 members 8-byte aligned, scalar arrays packed.
_Static_assert(sizeof(LibretroShaderUniforms) == 160, "LibretroShaderUniforms must stay 160 bytes");
_Static_assert(offsetof(LibretroShaderUniforms, SourceSize) == 0, "SourceSize offset");
_Static_assert(offsetof(LibretroShaderUniforms, OriginalSize) == 16, "OriginalSize offset");
_Static_assert(offsetof(LibretroShaderUniforms, OutputSize) == 32, "OutputSize offset");
_Static_assert(offsetof(LibretroShaderUniforms, uvOrigin) == 48, "uvOrigin offset");
_Static_assert(offsetof(LibretroShaderUniforms, uvExtent) == 56, "uvExtent offset");
_Static_assert(offsetof(LibretroShaderUniforms, uvMin) == 64, "uvMin offset");
_Static_assert(offsetof(LibretroShaderUniforms, uvMax) == 72, "uvMax offset");
_Static_assert(offsetof(LibretroShaderUniforms, FrameCount) == 80, "FrameCount offset");
_Static_assert(offsetof(LibretroShaderUniforms, flipped) == 84, "flipped offset");
_Static_assert(offsetof(LibretroShaderUniforms, parameters) == 96, "parameters offset");
_Static_assert(sizeof(((LibretroShaderUniforms *)0)->parameters) == 16 * sizeof(float), "16 parameter slots");

// MTLLanguageVersion2_4 is (2 << 16) + 4; this file does not import Metal.
const NSUInteger LibretroShaderLanguageVersion = (2 << 16) + 4;

// Shaders below: hand-ported from libretro/slang-shaders (master). Each
// fragment keeps its upstream copyright / licence header and lists the
// upstream "#pragma parameter" lines it exposes (checked by
// test/libretro_shader_catalog_test.py against the parameters declared in
// +[LibretroShaderLibrary presets]).

static NSString *const kPreludeSource =
    @"// NeoStation shader prelude, shared by every preset and the plain path.\n"
     "#include <metal_stdlib>\n"
     "using namespace metal;\n"
     "\n"
     "struct NeoVertexOut {\n"
     "  float4 position [[position]];\n"
     "  float2 coord;\n"
     "};\n"
     "\n"
     "// Same layout as LibretroShaderUniforms (LibretroShaderLibrary.h): 160 bytes.\n"
     "struct NeoUniforms {\n"
     "  float4 SourceSize;\n"
     "  float4 OriginalSize;\n"
     "  float4 OutputSize;\n"
     "  float2 uvOrigin;\n"
     "  float2 uvExtent;\n"
     "  float2 uvMin;\n"
     "  float2 uvMax;\n"
     "  uint FrameCount;\n"
     "  uint flipped;\n"
     "  uint padding[2];\n"
     "  float parameters[16];\n"
     "};\n"
     "\n"
     "// Triangle strip of 4 vertices: float4(ndc.x, ndc.y, coord.x, coord.y).\n"
     "vertex NeoVertexOut neostation_vertex(uint vid [[vertex_id]], constant float4 *quad [[buffer(0)]]) {\n"
     "  NeoVertexOut out;\n"
     "  float4 v = quad[vid];\n"
     "  out.position = float4(v.x, v.y, 0.0, 1.0);\n"
     "  out.coord = float2(v.z, v.w);\n"
     "  return out;\n"
     "}\n"
     "\n"
     "// coord: [0,1] over the screen's picture, top-left origin (vTexCoord of a\n"
     "// slang shader whose Source is that picture). It is mapped into the source\n"
     "// part of the texture, mirrored vertically inside the part for bottom-left\n"
     "// origin frames, then clamped half a texel inside the part.\n"
     "inline float4 NEO_SAMPLE(texture2d<float> source, sampler smp, constant NeoUniforms &u, float2 coord) {\n"
     "  float2 c = coord;\n"
     "  if (u.flipped != 0u) {\n"
     "    c.y = 1.0 - c.y;\n"
     "  }\n"
     "  return source.sample(smp, clamp(u.uvOrigin + c * u.uvExtent, u.uvMin, u.uvMax));\n"
     "}\n"
     "\n"
     "// Value of the preset parameter stored in `slot` (LibretroShaderParameter.slot).\n"
     "inline float NEO_PARAM(constant NeoUniforms &u, uint slot) {\n"
     "  return u.parameters[min(slot, 15u)];\n"
     "}\n";

static NSString *const kPassthroughSource =
    @"// NeoStation plain path: the picture without post-processing.\n"
     "fragment float4 neostation_fragment(NeoVertexOut in [[stage_in]], texture2d<float> source [[texture(0)]],\n"
     "                                    sampler smp [[sampler(0)]], constant NeoUniforms &u [[buffer(0)]]) {\n"
     "  return float4(NEO_SAMPLE(source, smp, u, in.coord).rgb, 1.0);\n"
     "}\n";

static NSString *const kSharpBilinearSource =
    @"/*\n"
     " * sharp-bilinear.slang\n"
     " * Author: Themaister\n"
     " * License: Public domain\n"
     " *\n"
     " * Does a bilinear stretch, with a preapplied Nx nearest-neighbor scale, giving a\n"
     " * sharper image than plain bilinear.\n"
     " */\n"
     "// Ported to Metal for NeoStation from libretro/slang-shaders\n"
     "// pixel-art-scaling/shaders/sharp-bilinear.slang (preset: filter_linear0 = true).\n"
     "// Upstream parameters:\n"
     "// #pragma parameter SHARP_BILINEAR_PRE_SCALE \"Sharp Bilinear Prescale\" 4.0 1.0 10.0 1.0\n"
     "// #pragma parameter AUTO_PRESCALE \"Automatic Prescale\" 1.0 0.0 1.0 1.0\n"
     "\n"
     "fragment float4 neostation_fragment(NeoVertexOut in [[stage_in]], texture2d<float> source [[texture(0)]],\n"
     "                                    sampler smp [[sampler(0)]], constant NeoUniforms &u [[buffer(0)]]) {\n"
     "  float SHARP_BILINEAR_PRE_SCALE = NEO_PARAM(u, 0);\n"
     "  float AUTO_PRESCALE = NEO_PARAM(u, 1);\n"
     "\n"
     "  float2 texel = in.coord * u.SourceSize.xy;\n"
     "  float2 texel_floored = floor(texel);\n"
     "  float2 s = fract(texel);\n"
     "  // NeoStation: the automatic prescale is at least 1 (the ARMSX2 \"prescale\n"
     "  // zero guard\"). Upstream floors it to 0 when the source is taller than the\n"
     "  // output, then divides by it.\n"
     "  float scale = (AUTO_PRESCALE > 0.5) ? max(floor(u.OutputSize.y / u.SourceSize.y + 0.01), 1.0)\n"
     "                                      : SHARP_BILINEAR_PRE_SCALE;\n"
     "  float region_range = 0.5 - 0.5 / scale;\n"
     "\n"
     "  // Figure out where in the texel to sample to get correct pre-scaled bilinear.\n"
     "  // Uses the hardware bilinear interpolator to avoid having to sample 4 times manually.\n"
     "\n"
     "  float2 center_dist = s - 0.5;\n"
     "  float2 f = (center_dist - clamp(center_dist, float2(-region_range), float2(region_range))) * scale + 0.5;\n"
     "\n"
     "  float2 mod_texel = texel_floored + f;\n"
     "\n"
     "  return float4(NEO_SAMPLE(source, smp, u, mod_texel / u.SourceSize.xy).rgb, 1.0);\n"
     "}\n";

static NSString *const kCrtLottesFastSource =
    @"//_____________________________/\\_______________________________\n"
     "//==============================================================\n"
     "//\n"
     "//\n"
     "//      [CRTS] PUBLIC DOMAIN CRT-STYLED SCALAR - 20180120b\n"
     "//\n"
     "//                      by Timothy Lottes\n"
     "//             https://www.shadertoy.com/view/MtSfRK\n"
     "//               adapted for RetroArch by hunterk\n"
     "//\n"
     "//\n"
     "//==============================================================\n"
     "//_____________________________/\\_______________________________\n"
     "//==============================================================\n"
     "//\n"
     "//          LICENSE = UNLICENSE (aka PUBLIC DOMAIN)\n"
     "//\n"
     "//--------------------------------------------------------------\n"
     "// This is free and unencumbered software released into the\n"
     "// public domain.\n"
     "//--------------------------------------------------------------\n"
     "// Anyone is free to copy, modify, publish, use, compile, sell,\n"
     "// or distribute this software, either in source code form or as\n"
     "// a compiled binary, for any purpose, commercial or\n"
     "// non-commercial, and by any means.\n"
     "//--------------------------------------------------------------\n"
     "// In jurisdictions that recognize copyright laws, the author or\n"
     "// authors of this software dedicate any and all copyright\n"
     "// interest in the software to the public domain. We make this\n"
     "// dedication for the benefit of the public at large and to the\n"
     "// detriment of our heirs and successors. We intend this\n"
     "// dedication to be an overt act of relinquishment in perpetuity\n"
     "// of all present and future rights to this software under\n"
     "// copyright law.\n"
     "//--------------------------------------------------------------\n"
     "// THE SOFTWARE IS PROVIDED \"AS IS\", WITHOUT WARRANTY OF ANY\n"
     "// KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE\n"
     "// WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR\n"
     "// PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS BE\n"
     "// LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN\n"
     "// AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT\n"
     "// OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER\n"
     "// DEALINGS IN THE SOFTWARE.\n"
     "//--------------------------------------------------------------\n"
     "// For more information, please refer to\n"
     "// <http://unlicense.org/>\n"
     "//==============================================================\n"
     "// Ported to Metal for NeoStation from libretro/slang-shaders\n"
     "// crt/shaders/crt-lottes-fast.slang (preset: filter_linear0 = true), with the\n"
     "// upstream configuration: CRTS_WARP, 8-tap filter (no CRTS_2_TAP), CRTS_TONE,\n"
     "// CRTS_CONTRAST and CRTS_SATURATION defined (as 0, so their #ifdef blocks are\n"
     "// compiled in with contrast 1 and saturation 0). TRINITRON_CURVE is fixed at\n"
     "// its default, 0.0. Mask types are compared after rounding the parameter.\n"
     "// Upstream parameters:\n"
     "// #pragma parameter MASK \"Mask Type\" 1.0 0.0 3.0 1.0\n"
     "// #pragma parameter MASK_INTENSITY \"Mask Intensity\" 0.5 0.0 1.0 0.05\n"
     "// #pragma parameter SCANLINE_THINNESS \"Scanline Intensity\" 0.5 0.0 1.0 0.1\n"
     "// #pragma parameter SCAN_BLUR \"Sharpness\" 2.5 1.0 3.0 0.1\n"
     "// #pragma parameter CURVATURE \"Curvature\" 0.02 0.0 0.25 0.01\n"
     "// #pragma parameter TRINITRON_CURVE \"Trinitron-style Curve\" 0.0 0.0 1.0 1.0\n"
     "// #pragma parameter CORNER \"Corner Round\" 3.0 0.0 11.0 1.0\n"
     "// #pragma parameter CRT_GAMMA \"CRT Gamma\" 2.4 0.0 51.0 0.1\n"
     "\n"
     "// Since shadertoy doesn't have sRGB textures\n"
     "// And we need linear input into shader\n"
     "// Don't do this in your code\n"
     "float FromSrgb1(float c, float crtGamma) {\n"
     "  return (c <= 0.04045) ? c * (1.0 / 12.92) : pow(abs(c) * (1.0 / 1.055) + (0.055 / 1.055), crtGamma);\n"
     "}\n"
     "\n"
     "float3 FromSrgb(float3 c, float crtGamma) {\n"
     "  return float3(FromSrgb1(c.r, crtGamma), FromSrgb1(c.g, crtGamma), FromSrgb1(c.b, crtGamma));\n"
     "}\n"
     "\n"
     "// Convert from linear to sRGB\n"
     "// Since shader toy output is not linear\n"
     "float ToSrgb1(float c) {\n"
     "  return (c < 0.0031308 ? c * 12.92 : 1.055 * pow(c, 0.41666) - 0.055);\n"
     "}\n"
     "\n"
     "float3 ToSrgb(float3 c) {\n"
     "  return float3(ToSrgb1(c.r), ToSrgb1(c.g), ToSrgb1(c.b));\n"
     "}\n"
     "\n"
     "// Setup the function which returns input image color\n"
     "float3 CrtsFetch(float2 uv, texture2d<float> source, sampler smp, constant NeoUniforms &u, float crtGamma) {\n"
     "  // For shadertoy, scale to get native texels in the image\n"
     "  uv *= float2(u.SourceSize.x, u.SourceSize.y) / u.SourceSize.xy;  // INPUT_X, INPUT_Y\n"
     "  // Non-shadertoy case would not have the color conversion\n"
     "  // (upstream samples with a -16 LOD bias; the source has no mipmaps)\n"
     "  return FromSrgb(NEO_SAMPLE(source, smp, u, uv.xy).rgb, crtGamma);\n"
     "}\n"
     "\n"
     "float CrtsMax3F1(float a, float b, float c) {\n"
     "  return max(a, max(b, c));\n"
     "}\n"
     "\n"
     "// Tonal control constant generation\n"
     "float4 CrtsTone(float contrast, float saturation, float thin, float mask, float maskType) {\n"
     "  if (maskType == 0.0) mask = 1.0;\n"
     "  if (maskType == 1.0) {\n"
     "    // Normal R mask is {1.0,mask,mask}\n"
     "    // LITE   R mask is {mask,1.0,1.0}\n"
     "    mask = 0.5 + mask * 0.5;\n"
     "  }\n"
     "  float4 ret;\n"
     "  float midOut = 0.18 / ((1.5 - thin) * (0.5 * mask + 0.5));\n"
     "  float pMidIn = pow(0.18, contrast);\n"
     "  ret.x = contrast;\n"
     "  ret.y = ((-pMidIn) + midOut) / ((1.0 - pMidIn) * midOut);\n"
     "  ret.z = ((-pMidIn) * midOut + pMidIn) / (midOut * (-pMidIn) + midOut);\n"
     "  ret.w = contrast + saturation;\n"
     "  return ret;\n"
     "}\n"
     "\n"
     "// Mask: 'pos' is fragCoord.xy (pixel {0,0} is {0.5,0.5}); 'dark' is the\n"
     "// exposure of the masked channel (0.0 = fully off, 1.0 = no effect).\n"
     "float3 CrtsMask(float2 pos, float dark, float maskType) {\n"
     "  if (maskType == 2.0) {\n"
     "    float3 m = float3(dark, dark, dark);\n"
     "    float x = fract(pos.x * (1.0 / 3.0));\n"
     "    if (x < (1.0 / 3.0)) m.r = 1.0;\n"
     "    else if (x < (2.0 / 3.0)) m.g = 1.0;\n"
     "    else m.b = 1.0;\n"
     "    return m;\n"
     "  } else if (maskType == 1.0) {\n"
     "    float3 m = float3(1.0, 1.0, 1.0);\n"
     "    float x = fract(pos.x * (1.0 / 3.0));\n"
     "    if (x < (1.0 / 3.0)) m.r = dark;\n"
     "    else if (x < (2.0 / 3.0)) m.g = dark;\n"
     "    else m.b = dark;\n"
     "    return m;\n"
     "  } else if (maskType == 3.0) {\n"
     "    pos.x += pos.y * 2.9999;\n"
     "    float3 m = float3(dark, dark, dark);\n"
     "    float x = fract(pos.x * (1.0 / 6.0));\n"
     "    if (x < (1.0 / 3.0)) m.r = 1.0;\n"
     "    else if (x < (2.0 / 3.0)) m.g = 1.0;\n"
     "    else m.b = 1.0;\n"
     "    return m;\n"
     "  } else {\n"
     "    return float3(1.0, 1.0, 1.0);\n"
     "  }\n"
     "}\n"
     "\n"
     "// Filter entry: input must be linear, output color is linear.\n"
     "float3 CrtsFilter(float2 ipos, float2 inputSizeDivOutputSize, float2 halfInputSize, float2 rcpInputSize,\n"
     "                  float2 rcpOutputSize, float2 twoDivOutputSize, float inputHeight, float2 warp, float thin,\n"
     "                  float blur, float mask, float4 tone, texture2d<float> source, sampler smp,\n"
     "                  constant NeoUniforms &u, float crtGamma, float corner, float maskType) {\n"
     "  // Optional apply warp (CRTS_WARP)\n"
     "  float2 pos;\n"
     "  // Convert to {-1 to 1} range\n"
     "  pos = ipos * twoDivOutputSize - float2(1.0, 1.0);\n"
     "  // Distort pushes image outside {-1 to 1} range\n"
     "  pos *= float2(1.0 + (pos.y * pos.y) * warp.x, 1.0 + (pos.x * pos.x) * warp.y);\n"
     "  float vin = (1.0 - ((1.0 - clamp(pos.x * pos.x, 0.0, 1.0)) * (1.0 - clamp(pos.y * pos.y, 0.0, 1.0)))) *\n"
     "              (0.998 + (0.001 * corner));\n"
     "  vin = clamp((-vin) * inputHeight + inputHeight, 0.0, 1.0);\n"
     "  // Leave in {0 to inputSize}\n"
     "  pos = pos * halfInputSize + halfInputSize;\n"
     "\n"
     "  // Snap to center of first scanline\n"
     "  float y0 = floor(pos.y - 0.5) + 0.5;\n"
     "  // Snap to center of one of four pixels\n"
     "  float x0 = floor(pos.x - 1.5) + 0.5;\n"
     "  // Inital UV position\n"
     "  float2 p = float2(x0 * rcpInputSize.x, y0 * rcpInputSize.y);\n"
     "  // Fetch 4 nearest texels from 2 nearest scanlines\n"
     "  float3 colA0 = CrtsFetch(p, source, smp, u, crtGamma);\n"
     "  p.x += rcpInputSize.x;\n"
     "  float3 colA1 = CrtsFetch(p, source, smp, u, crtGamma);\n"
     "  p.x += rcpInputSize.x;\n"
     "  float3 colA2 = CrtsFetch(p, source, smp, u, crtGamma);\n"
     "  p.x += rcpInputSize.x;\n"
     "  float3 colA3 = CrtsFetch(p, source, smp, u, crtGamma);\n"
     "  p.y += rcpInputSize.y;\n"
     "  float3 colB3 = CrtsFetch(p, source, smp, u, crtGamma);\n"
     "  p.x -= rcpInputSize.x;\n"
     "  float3 colB2 = CrtsFetch(p, source, smp, u, crtGamma);\n"
     "  p.x -= rcpInputSize.x;\n"
     "  float3 colB1 = CrtsFetch(p, source, smp, u, crtGamma);\n"
     "  p.x -= rcpInputSize.x;\n"
     "  float3 colB0 = CrtsFetch(p, source, smp, u, crtGamma);\n"
     "\n"
     "  // Vertical filter\n"
     "  // Scanline intensity is using sine wave\n"
     "  // Easy filter window and integral used later in exposure\n"
     "  float off = pos.y - y0;\n"
     "  float pi2 = 6.28318530717958;\n"
     "  float hlf = 0.5;\n"
     "  float scanA = cos(min(0.5, off * thin) * pi2) * hlf + hlf;\n"
     "  float scanB = cos(min(0.5, (-off) * thin + thin) * pi2) * hlf + hlf;\n"
     "\n"
     "  // Horizontal kernel is simple gaussian filter\n"
     "  float off0 = pos.x - x0;\n"
     "  float off1 = off0 - 1.0;\n"
     "  float off2 = off0 - 2.0;\n"
     "  float off3 = off0 - 3.0;\n"
     "  float pix0 = exp2(blur * off0 * off0);\n"
     "  float pix1 = exp2(blur * off1 * off1);\n"
     "  float pix2 = exp2(blur * off2 * off2);\n"
     "  float pix3 = exp2(blur * off3 * off3);\n"
     "  float pixT = 1.0 / (pix0 + pix1 + pix2 + pix3);\n"
     "  // Get rid of wrong pixels on edge\n"
     "  pixT *= vin;\n"
     "  scanA *= pixT;\n"
     "  scanB *= pixT;\n"
     "  // Apply horizontal and vertical filters\n"
     "  float3 color = (colA0 * pix0 + colA1 * pix1 + colA2 * pix2 + colA3 * pix3) * scanA +\n"
     "                 (colB0 * pix0 + colB1 * pix1 + colB2 * pix2 + colB3 * pix3) * scanB;\n"
     "\n"
     "  // Apply phosphor mask\n"
     "  color *= CrtsMask(ipos, mask, maskType);\n"
     "\n"
     "  // Tonal control, start by protecting from /0\n"
     "  float peak = max(1.0 / (256.0 * 65536.0), CrtsMax3F1(color.r, color.g, color.b));\n"
     "  // Compute the ratios of {R,G,B}\n"
     "  float3 ratio = color * (1.0 / peak);\n"
     "  // Apply tonal curve to peak value (CRTS_CONTRAST)\n"
     "  peak = pow(peak, tone.x);\n"
     "  peak = peak * (1.0 / (peak * tone.y + tone.z));\n"
     "  // Apply saturation (CRTS_SATURATION)\n"
     "  ratio = pow(ratio, float3(tone.w, tone.w, tone.w));\n"
     "  // Reconstruct color\n"
     "  return ratio * peak;\n"
     "}\n"
     "\n"
     "fragment float4 neostation_fragment(NeoVertexOut in [[stage_in]], texture2d<float> source [[texture(0)]],\n"
     "                                    sampler smp [[sampler(0)]], constant NeoUniforms &u [[buffer(0)]]) {\n"
     "  float MASK = round(NEO_PARAM(u, 0));\n"
     "  float MASK_INTENSITY = NEO_PARAM(u, 1);\n"
     "  float SCANLINE_THINNESS = NEO_PARAM(u, 2);\n"
     "  float SCAN_BLUR = NEO_PARAM(u, 3);\n"
     "  float CURVATURE = NEO_PARAM(u, 4);\n"
     "  float CORNER = NEO_PARAM(u, 5);\n"
     "  float CRT_GAMMA = NEO_PARAM(u, 6);\n"
     "  float TRINITRON_CURVE = 0.0;\n"
     "\n"
     "  // Scanline thinness: 0.50 = fused scanlines, 0.70 = recommended default\n"
     "  float INPUT_THIN = 0.5 + (0.5 * SCANLINE_THINNESS);\n"
     "  // Horizonal scan blur: -3.0 = pixely, -2.5 = default, -2.0 = smooth\n"
     "  float INPUT_BLUR = -1.0 * SCAN_BLUR;\n"
     "  // Shadow mask effect: 0.50 = recommended default, 1.00 = no shadow mask\n"
     "  float INPUT_MASK = 1.0 - MASK_INTENSITY;\n"
     "\n"
     "  float2 warp_factor;\n"
     "  warp_factor.x = CURVATURE;\n"
     "  warp_factor.y = (3.0 / 4.0) * warp_factor.x;  // assume 4:3 aspect\n"
     "  warp_factor.x *= (1.0 - TRINITRON_CURVE);\n"
     "  float3 color = CrtsFilter(in.coord.xy * u.OutputSize.xy,\n"
     "                            u.SourceSize.xy * u.OutputSize.zw,\n"
     "                            u.SourceSize.xy * float2(0.5, 0.5),\n"
     "                            u.SourceSize.zw,\n"
     "                            u.OutputSize.zw,\n"
     "                            2.0 * u.OutputSize.zw,\n"
     "                            u.SourceSize.y,\n"
     "                            warp_factor,\n"
     "                            INPUT_THIN,\n"
     "                            INPUT_BLUR,\n"
     "                            INPUT_MASK,\n"
     "                            CrtsTone(1.0, 0.0, INPUT_THIN, INPUT_MASK, MASK),\n"
     "                            source, smp, u, CRT_GAMMA, CORNER, MASK);\n"
     "\n"
     "  // Shadertoy outputs non-linear color\n"
     "  return float4(ToSrgb(color), 1.0);\n"
     "}\n";

static NSString *const kCrtHyllianFastSource =
    @"/*\n"
     "   Hyllian's CRT Shader\n"
     "   with cgwg's magenta/green dotmask\n"
     "   ported to GLSL/SLANG by DariusG & hunterk\n"
     "\n"
     "   Copyright (C) 2011-2015 Hyllian - sergiogdb@gmail.com\n"
     "\n"
     "   Permission is hereby granted, free of charge, to any person obtaining a copy\n"
     "   of this software and associated documentation files (the \"Software\"), to deal\n"
     "   in the Software without restriction, including without limitation the rights\n"
     "   to use, copy, modify, merge, publish, distribute, sublicense, and/or sell\n"
     "   copies of the Software, and to permit persons to whom the Software is\n"
     "   furnished to do so, subject to the following conditions:\n"
     "\n"
     "   The above copyright notice and this permission notice shall be included in\n"
     "   all copies or substantial portions of the Software.\n"
     "\n"
     "   THE SOFTWARE IS PROVIDED \"AS IS\", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR\n"
     "   IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,\n"
     "   FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE\n"
     "   AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER\n"
     "   LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,\n"
     "   OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN\n"
     "   THE SOFTWARE.\n"
     "*/\n"
     "// Ported to Metal for NeoStation from libretro/slang-shaders\n"
     "// crt/shaders/hyllian/crt-hyllian-fast.slang (preset: filter_linear0 = false).\n"
     "// The vertex stage's offset coordinate is computed here (it is linear in the\n"
     "// texture coordinate). SourceSize is TextureSize; OriginalSize is InputSize.\n"
     "// SHARPER is compared after rounding the parameter.\n"
     "// Upstream parameters:\n"
     "// #pragma parameter MASK_INTENSITY \"MASK INTENSITY\" 0.5 0.0 1.0 0.1\n"
     "// #pragma parameter InputGamma \"INPUT GAMMA\" 2.4 0.0 5.0 0.1\n"
     "// #pragma parameter OutputGamma \"OUTPUT GAMMA\" 2.2 0.0 5.0 0.1\n"
     "// #pragma parameter BRIGHTBOOST \"BRIGHT BOOST\" 1.5 0.0 2.0 0.1\n"
     "// #pragma parameter SCANLINES \"SCANLINES STRENGTH\" 0.72 0.0 1.0 0.02\n"
     "// #pragma parameter SHARPER \"SHARPER\" 0.0 0.0 1.0 1.0\n"
     "\n"
     "// GLSL mod(): x - y * floor(x / y), unlike fmod() for negative x.\n"
     "float HyllianMod(float x, float y) {\n"
     "  return x - y * floor(x / y);\n"
     "}\n"
     "\n"
     "fragment float4 neostation_fragment(NeoVertexOut in [[stage_in]], texture2d<float> source [[texture(0)]],\n"
     "                                    sampler smp [[sampler(0)]], constant NeoUniforms &u [[buffer(0)]]) {\n"
     "  float MASK_INTENSITY = NEO_PARAM(u, 0);\n"
     "  float InputGamma = NEO_PARAM(u, 1);\n"
     "  float OutputGamma = NEO_PARAM(u, 2);\n"
     "  float BRIGHTBOOST = NEO_PARAM(u, 3);\n"
     "  float SCANLINES = NEO_PARAM(u, 4);\n"
     "  float SHARPER = round(NEO_PARAM(u, 5));\n"
     "\n"
     "  // Vertex stage\n"
     "  float2 tex_size = float2(u.SourceSize.x, u.SourceSize.y);\n"
     "  float2 ps = float2(1.0) / tex_size;\n"
     "  float2 vTexCoord = in.coord + ps * float2(-0.49999, 0.0);\n"
     "\n"
     "  float2 dx = float2(ps.x, 0.0);\n"
     "\n"
     "  float2 tc = (floor(vTexCoord.xy * u.SourceSize.xy) + float2(0.49999, 0.49999)) / u.SourceSize.xy;\n"
     "\n"
     "  float2 fp = fract(vTexCoord.xy * u.SourceSize.xy);\n"
     "\n"
     "  float3 c10 = NEO_SAMPLE(source, smp, u, tc - dx).xyz;\n"
     "  float3 c11 = NEO_SAMPLE(source, smp, u, tc).xyz;\n"
     "  float3 c12 = NEO_SAMPLE(source, smp, u, tc + dx).xyz;\n"
     "  float3 c13 = NEO_SAMPLE(source, smp, u, tc + 2.0 * dx).xyz;\n"
     "\n"
     "  float4 lobes = float4(fp.x * fp.x * fp.x, fp.x * fp.x, fp.x, 1.0);\n"
     "\n"
     "  float4 InvX = float4(0.0);\n"
     "\n"
     "  if (SHARPER == 0.0) {\n"
     "    // Horizontal cubic filter - \"Catrom\"\n"
     "    InvX.x = dot(float4(-0.5, 1.0, -0.5, 0.0), lobes);\n"
     "    InvX.y = dot(float4(1.5, -2.5, 0.0, 1.0), lobes);\n"
     "    InvX.z = dot(float4(-1.5, 2.0, 0.5, 0.0), lobes);\n"
     "    InvX.w = dot(float4(0.5, -0.5, 0.0, 0.0), lobes);\n"
     "  } else if (SHARPER == 1.0) {\n"
     "    // Swith to \"Hermite\" - Sharper, smoothed bilinear\n"
     "    InvX.x = dot(float4(0.0, 0.0, 0.0, 0.0), lobes);\n"
     "    InvX.y = dot(float4(2.0, -3.0, 0.0, 1.0), lobes);\n"
     "    InvX.z = dot(float4(-2.0, 3.0, 0.0, 0.0), lobes);\n"
     "    InvX.w = dot(float4(0.0, 0.0, 0.0, 0.0), lobes);\n"
     "  }\n"
     "\n"
     "  float3 color = InvX.x * c10.xyz;\n"
     "  color += InvX.y * c11.xyz;\n"
     "  color += InvX.z * c12.xyz;\n"
     "  color += InvX.w * c13.xyz;\n"
     "\n"
     "  // NeoStation: the Catmull-Rom lobes undershoot below 0 next to sharp\n"
     "  // edges, where pow() returns NaN (drawn black). Clamping to 0 draws the\n"
     "  // same black without producing NaN.\n"
     "  color = max(color, float3(0.0));\n"
     "  color = pow(color, float3(InputGamma, InputGamma, InputGamma));  // GAMMA_IN\n"
     "\n"
     "  float pos1 = 1.5 - SCANLINES - abs(fp.y - 0.5);\n"
     "  float d1 = max(0.0, min(1.0, pos1));\n"
     "  float d = d1 * d1 * (3.0 + BRIGHTBOOST - (2.0 * d1));\n"
     "\n"
     "  color = color * d;\n"
     "\n"
     "  // dotmask\n"
     "  float mod_factor = vTexCoord.x * u.OutputSize.x;\n"
     "  float4 dotMaskWeights = mix(float4(1.0, 1.0 - MASK_INTENSITY, 1.0, 1.0),\n"
     "                              float4(1.0 - MASK_INTENSITY, 1.0, 1.0 - MASK_INTENSITY, 1.0),\n"
     "                              float4(floor(HyllianMod(mod_factor, 2.0))));\n"
     "  color *= float3(dotMaskWeights.x, dotMaskWeights.y, dotMaskWeights.z);\n"
     "\n"
     "  color = pow(color, float3(1.0 / OutputGamma, 1.0 / OutputGamma, 1.0 / OutputGamma));  // GAMMA_OUT\n"
     "  return float4(color.r, color.g, color.b, 1.0);\n"
     "}\n";

static NSString *const kZfastCrtSource =
    @"/*\n"
     "    zfast_crt_standard - A simple, fast CRT shader.\n"
     "\n"
     "    Copyright (C) 2017 Greg Hogan (SoltanGris42)\n"
     "\n"
     "    This program is free software; you can redistribute it and/or modify it\n"
     "    under the terms of the GNU General Public License as published by the Free\n"
     "    Software Foundation; either version 2 of the License, or (at your option)\n"
     "    any later version.\n"
     "\n"
     "\n"
     "Notes:  This shader does scaling with a weighted linear filter for adjustable\n"
     "    sharpness on the x and y axes based on the algorithm by Inigo Quilez here:\n"
     "    http://http://www.iquilezles.org/www/articles/texture/texture.htm\n"
     "    but modified to be somewhat sharper.  Then a scanline effect that varies\n"
     "    based on pixel brighness is applied along with a monochrome aperture mask.\n"
     "    This shader runs at 60fps on the Raspberry Pi 3 hardware at 2mpix/s\n"
     "    resolutions (1920x1080 or 1600x1200).\n"
     "*/\n"
     "// zfast_crt_finemask.slang:\n"
     "// This can't be an option without slowing the shader down.\n"
     "// Note that only the fine mask works on SNES Classic Edition\n"
     "// due to Mali 400 gpu precision.\n"
     "// Ported to Metal for NeoStation from libretro/slang-shaders\n"
     "// crt/shaders/zfast_crt/zfast_crt_finemask.slang, which defines FINEMASK and\n"
     "// includes zfast_crt_impl.inc (preset: filter_linear0 = true). BLACK_OUT_BORDER\n"
     "// stays undefined, as upstream. The vertex stage's maskFade and invDims are\n"
     "// computed here.\n"
     "// Upstream parameters:\n"
     "// #pragma parameter BLURSCALEX \"Blur Amount X-Axis\" 0.30 0.0 1.0 0.05\n"
     "// #pragma parameter LOWLUMSCAN \"Scanline Darkness - Low\" 6.0 0.0 10.0 0.5\n"
     "// #pragma parameter HILUMSCAN \"Scanline Darkness - High\" 8.0 0.0 50.0 1.0\n"
     "// #pragma parameter BRIGHTBOOST \"Dark Pixel Brightness Boost\" 1.25 0.5 1.5 0.05\n"
     "// #pragma parameter MASK_DARK \"Mask Effect Amount\" 0.25 0.0 1.0 0.05\n"
     "// #pragma parameter MASK_FADE \"Mask/Scanline Fade\" 0.8 0.0 1.0 0.05\n"
     "\n"
     "fragment float4 neostation_fragment(NeoVertexOut in [[stage_in]], texture2d<float> source [[texture(0)]],\n"
     "                                    sampler smp [[sampler(0)]], constant NeoUniforms &u [[buffer(0)]]) {\n"
     "  float BLURSCALEX = NEO_PARAM(u, 0);\n"
     "  float LOWLUMSCAN = NEO_PARAM(u, 1);\n"
     "  float HILUMSCAN = NEO_PARAM(u, 2);\n"
     "  float BRIGHTBOOST = NEO_PARAM(u, 3);\n"
     "  float MASK_DARK = NEO_PARAM(u, 4);\n"
     "  float MASK_FADE = NEO_PARAM(u, 5);\n"
     "\n"
     "  // Vertex stage\n"
     "  float2 vTexCoord = in.coord;\n"
     "  float maskFade = 0.3333 * MASK_FADE;\n"
     "  float2 invDims = float2(1.0) / u.SourceSize.xy;\n"
     "\n"
     "  // This is just like \"Quilez Scaling\" but sharper\n"
     "  float2 p = vTexCoord * u.SourceSize.xy;\n"
     "  float2 i = floor(p) + 0.50;\n"
     "  float2 f = p - i;\n"
     "  p = (i + 4.0 * f * f * f) * invDims;\n"
     "  p.x = mix(p.x, vTexCoord.x, BLURSCALEX);\n"
     "  float Y = f.y * f.y;\n"
     "  float YY = Y * Y;\n"
     "\n"
     "  // FINEMASK\n"
     "  float whichmask = fract(floor(vTexCoord.x * u.OutputSize.x) * -0.4999);\n"
     "  float mask = 1.0 + float(whichmask < 0.5) * -MASK_DARK;\n"
     "\n"
     "  float3 colour = NEO_SAMPLE(source, smp, u, p).rgb;\n"
     "\n"
     "  float scanLineWeight = (BRIGHTBOOST - LOWLUMSCAN * (Y - 2.05 * YY));\n"
     "  float scanLineWeightB = 1.0 - HILUMSCAN * (YY - 2.8 * YY * Y);\n"
     "\n"
     "  float3 rgb = colour.rgb * mix(scanLineWeight * mask, scanLineWeightB, dot(colour.rgb, float3(maskFade)));\n"
     "  return float4(rgb, 1.0);\n"
     "}\n";

static NSString *const kScanlinesSineAbsSource =
    @"/*\n"
     "    Scanlines Sine Absolute Value\n"
     "    An ultra light scanline shader\n"
     "    by RiskyJumps\n"
     "    license: public domain\n"
     "*/\n"
     "// Ported to Metal for NeoStation from libretro/slang-shaders\n"
     "// scanlines/shaders/scanlines-sine-abs.slang (the preset sets no\n"
     "// filter_linear0: NeoStation follows its smoothing setting, as RetroArch\n"
     "// follows its global one). The vertex stage's angle is computed here.\n"
     "// Upstream parameters:\n"
     "// #pragma parameter amp \"Amplitude\" 1.2500 0.000 2.000 0.05\n"
     "// #pragma parameter phase \"Phase\" 0.5000 0.000 2.000 0.05\n"
     "// #pragma parameter lines_black \"Lines Blacks\" 0.0000 0.000 1.000 0.05\n"
     "// #pragma parameter lines_white \"Lines Whites\" 1.0000 0.000 2.000 0.05\n"
     "\n"
     "fragment float4 neostation_fragment(NeoVertexOut in [[stage_in]], texture2d<float> source [[texture(0)]],\n"
     "                                    sampler smp [[sampler(0)]], constant NeoUniforms &u [[buffer(0)]]) {\n"
     "  float amp = NEO_PARAM(u, 0);\n"
     "  float phase = NEO_PARAM(u, 1);\n"
     "  float lines_black = NEO_PARAM(u, 2);\n"
     "  float lines_white = NEO_PARAM(u, 3);\n"
     "  const float freq = 0.500000;\n"
     "  const float offset = 0.000000;\n"
     "  const float pi = 3.141592654;\n"
     "\n"
     "  // Vertex stage\n"
     "  float2 vTexCoord = in.coord;\n"
     "  float omega = 2.0 * pi * freq;  // Angular frequency\n"
     "  float angle = vTexCoord.y * omega * u.SourceSize.y + phase;\n"
     "\n"
     "  float3 color = NEO_SAMPLE(source, smp, u, vTexCoord).xyz;\n"
     "\n"
     "  float lines;\n"
     "\n"
     "  lines = sin(angle);\n"
     "  lines *= amp;\n"
     "  lines += offset;\n"
     "  lines = abs(lines);\n"
     "  lines *= lines_white - lines_black;\n"
     "  lines += lines_black;\n"
     "  color *= lines;\n"
     "\n"
     "  return float4(color.xyz, 1.0);\n"
     "}\n";

static NSString *const kLcd3xSource =
    @"/*\n"
     "   Author: Gigaherz\n"
     "   License: Public domain\n"
     "*/\n"
     "// Ported to Metal for NeoStation from libretro/slang-shaders\n"
     "// handheld/shaders/lcd3x.slang (preset: filter_linear0 = false).\n"
     "// Upstream parameters:\n"
     "// #pragma parameter brighten_scanlines \"Brighten Scanlines\" 16.0 1.0 32.0 0.5\n"
     "// #pragma parameter brighten_lcd \"Brighten LCD\" 4.0 1.0 12.0 0.1\n"
     "\n"
     "fragment float4 neostation_fragment(NeoVertexOut in [[stage_in]], texture2d<float> source [[texture(0)]],\n"
     "                                    sampler smp [[sampler(0)]], constant NeoUniforms &u [[buffer(0)]]) {\n"
     "  float brighten_scanlines = NEO_PARAM(u, 0);\n"
     "  float brighten_lcd = NEO_PARAM(u, 1);\n"
     "\n"
     "  float2 omega = float2(3.141592654) * float2(2.0) * u.OriginalSize.xy;\n"
     "  const float3 offsets =\n"
     "      float3(3.141592654) * float3(1.0 / 2.0, 1.0 / 2.0 - 2.0 / 3.0, 1.0 / 2.0 - 4.0 / 3.0);\n"
     "\n"
     "  float3 res = NEO_SAMPLE(source, smp, u, in.coord).xyz;\n"
     "\n"
     "  float2 angle = in.coord * omega;\n"
     "\n"
     "  float yfactor = (brighten_scanlines + sin(angle.y)) / (brighten_scanlines + 1.0);\n"
     "  float3 xfactors = (brighten_lcd + sin(angle.x + offsets)) / (brighten_lcd + 1.0);\n"
     "\n"
     "  float3 color = yfactor * xfactors * res;\n"
     "\n"
     "  return float4(color.x, color.y, color.z, 1.0);\n"
     "}\n";

static NSString *const kSameBoyLcdSource =
    @"/*\n"
     "   SameBoy LCD shader\n"
     "   Author: LIJI32\n"
     "   License: MIT\n"
     "\n"
     "   Copyright (c) 2015-2016 Lior Halphon\n"
     "\n"
     "   Permission is hereby granted, free of charge, to any person obtaining a copy\n"
     "   of this software and associated documentation files (the \"Software\"), to deal\n"
     "   in the Software without restriction, including without limitation the rights\n"
     "   to use, copy, modify, merge, publish, distribute, sublicense, and/or sell\n"
     "   copies of the Software, and to permit persons to whom the Software is\n"
     "   furnished to do so, subject to the following conditions:\n"
     "\n"
     "   The above copyright notice and this permission notice shall be included in all\n"
     "   copies or substantial portions of the Software.\n"
     "\n"
     "   THE SOFTWARE IS PROVIDED \"AS IS\", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR\n"
     "   IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,\n"
     "   FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE\n"
     "   AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER\n"
     "   LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,\n"
     "   OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE\n"
     "   SOFTWARE.\n"
     "*/\n"
     "// Ported to Metal for NeoStation from libretro/slang-shaders\n"
     "// handheld/shaders/sameboy-lcd.slang (preset: filter_linear0 = false).\n"
     "// Upstream parameters:\n"
     "// #pragma parameter COLOR_LOW \"Color Low\" 0.8 0.0 1.5 0.05\n"
     "// #pragma parameter COLOR_HIGH \"Color High\" 1.0 0.0 1.5 0.05\n"
     "// #pragma parameter SCANLINE_DEPTH \"Scanline Depth\" 0.1 0.0 2.0 0.05\n"
     "\n"
     "fragment float4 neostation_fragment(NeoVertexOut in [[stage_in]], texture2d<float> source [[texture(0)]],\n"
     "                                    sampler smp [[sampler(0)]], constant NeoUniforms &u [[buffer(0)]]) {\n"
     "  float COLOR_LOW = NEO_PARAM(u, 0);\n"
     "  float COLOR_HIGH = NEO_PARAM(u, 1);\n"
     "  float SCANLINE_DEPTH = NEO_PARAM(u, 2);\n"
     "  float2 vTexCoord = in.coord;\n"
     "\n"
     "  float2 pos = fract(vTexCoord * u.OriginalSize.xy);\n"
     "  float2 sub_pos = fract(vTexCoord * u.OriginalSize.xy * 6.0);\n"
     "\n"
     "  float4 center = NEO_SAMPLE(source, smp, u, vTexCoord);\n"
     "  float4 left = NEO_SAMPLE(source, smp, u, vTexCoord - float2(1.0 / u.OriginalSize.x, 0.0));\n"
     "  float4 right = NEO_SAMPLE(source, smp, u, vTexCoord + float2(1.0 / u.OriginalSize.x, 0.0));\n"
     "\n"
     "  if (pos.y < 1.0 / 6.0) {\n"
     "    center = mix(center,\n"
     "                 NEO_SAMPLE(source, smp, u, vTexCoord + float2(0.0, -1.0 / u.OriginalSize.y)),\n"
     "                 float4(0.5 - sub_pos.y / 2.0));\n"
     "    left = mix(left,\n"
     "               NEO_SAMPLE(source, smp, u, vTexCoord + float2(-1.0 / u.OriginalSize.x, -1.0 / u.OriginalSize.y)),\n"
     "               float4(0.5 - sub_pos.y / 2.0));\n"
     "    right = mix(right,\n"
     "                NEO_SAMPLE(source, smp, u, vTexCoord + float2(1.0 / u.OriginalSize.x, -1.0 / u.OriginalSize.y)),\n"
     "                float4(0.5 - sub_pos.y / 2.0));\n"
     "    center *= sub_pos.y * SCANLINE_DEPTH + (1.0 - SCANLINE_DEPTH);\n"
     "    left *= sub_pos.y * SCANLINE_DEPTH + (1.0 - SCANLINE_DEPTH);\n"
     "    right *= sub_pos.y * SCANLINE_DEPTH + (1.0 - SCANLINE_DEPTH);\n"
     "  } else if (pos.y > 5.0 / 6.0) {\n"
     "    center = mix(center,\n"
     "                 NEO_SAMPLE(source, smp, u, vTexCoord + float2(0.0, 1.0 / u.OriginalSize.y)),\n"
     "                 float4(sub_pos.y / 2.0));\n"
     "    left = mix(left,\n"
     "               NEO_SAMPLE(source, smp, u, vTexCoord + float2(-1.0 / u.OriginalSize.x, 1.0 / u.OriginalSize.y)),\n"
     "               float4(sub_pos.y / 2.0));\n"
     "    right = mix(right,\n"
     "                NEO_SAMPLE(source, smp, u, vTexCoord + float2(1.0 / u.OriginalSize.x, 1.0 / u.OriginalSize.y)),\n"
     "                float4(sub_pos.y / 2.0));\n"
     "    center *= (1.0 - sub_pos.y) * SCANLINE_DEPTH + (1.0 - SCANLINE_DEPTH);\n"
     "    left *= (1.0 - sub_pos.y) * SCANLINE_DEPTH + (1.0 - SCANLINE_DEPTH);\n"
     "    right *= (1.0 - sub_pos.y) * SCANLINE_DEPTH + (1.0 - SCANLINE_DEPTH);\n"
     "  }\n"
     "\n"
     "  float4 midleft = mix(left, center, float4(0.5));\n"
     "  float4 midright = mix(right, center, float4(0.5));\n"
     "\n"
     "  float4 ret;\n"
     "  if (pos.x < 1.0 / 6.0) {\n"
     "    ret = mix(float4(COLOR_HIGH * center.r, COLOR_LOW * center.g, COLOR_HIGH * left.b, 1.0),\n"
     "              float4(COLOR_HIGH * center.r, COLOR_LOW * center.g, COLOR_LOW * left.b, 1.0),\n"
     "              float4(sub_pos.x));\n"
     "  } else if (pos.x < 2.0 / 6.0) {\n"
     "    ret = mix(float4(COLOR_HIGH * center.r, COLOR_LOW * center.g, COLOR_LOW * left.b, 1.0),\n"
     "              float4(COLOR_HIGH * center.r, COLOR_HIGH * center.g, COLOR_LOW * midleft.b, 1.0),\n"
     "              float4(sub_pos.x));\n"
     "  } else if (pos.x < 3.0 / 6.0) {\n"
     "    ret = mix(float4(COLOR_HIGH * center.r, COLOR_HIGH * center.g, COLOR_LOW * midleft.b, 1.0),\n"
     "              float4(COLOR_LOW * midright.r, COLOR_HIGH * center.g, COLOR_LOW * center.b, 1.0),\n"
     "              float4(sub_pos.x));\n"
     "  } else if (pos.x < 4.0 / 6.0) {\n"
     "    ret = mix(float4(COLOR_LOW * midright.r, COLOR_HIGH * center.g, COLOR_LOW * center.b, 1.0),\n"
     "              float4(COLOR_LOW * right.r, COLOR_HIGH * center.g, COLOR_HIGH * center.b, 1.0),\n"
     "              float4(sub_pos.x));\n"
     "  } else if (pos.x < 5.0 / 6.0) {\n"
     "    ret = mix(float4(COLOR_LOW * right.r, COLOR_HIGH * center.g, COLOR_HIGH * center.b, 1.0),\n"
     "              float4(COLOR_LOW * right.r, COLOR_LOW * midright.g, COLOR_HIGH * center.b, 1.0),\n"
     "              float4(sub_pos.x));\n"
     "  } else {\n"
     "    ret = mix(float4(COLOR_LOW * right.r, COLOR_LOW * midright.g, COLOR_HIGH * center.b, 1.0),\n"
     "              float4(COLOR_HIGH * right.r, COLOR_LOW * right.g, COLOR_HIGH * center.b, 1.0),\n"
     "              float4(sub_pos.x));\n"
     "  }\n"
     "\n"
     "  return ret;\n"
     "}\n";

static NSString *const kDotSource =
    @"/*\n"
     "   Author: Themaister\n"
     "   License: Public domain\n"
     "*/\n"
     "// Ported to Metal for NeoStation from libretro/slang-shaders\n"
     "// handheld/shaders/dot.slang (preset: filter_linear0 = false). The vertex\n"
     "// stage's coordinates are computed here (they are linear in the texture\n"
     "// coordinate).\n"
     "// Upstream parameters:\n"
     "// #pragma parameter gamma \"Dot Gamma\" 2.4 0.0 5.0 0.05\n"
     "// #pragma parameter shine \"Dot Shine\" 0.05 0.0 0.5 0.01\n"
     "// #pragma parameter blend \"Dot Blend\" 0.65 0.0 1.0 0.01\n"
     "// #pragma parameter soft \"Dot Soft\" 0.0 0.0 1.0 0.1\n"
     "\n"
     "float dist(float2 coord, float2 source) {\n"
     "  float2 delta = coord - source;\n"
     "  return sqrt(dot(delta, delta));\n"
     "}\n"
     "\n"
     "float color_bloom(float3 color, float shine) {\n"
     "  const float3 gray_coeff = float3(0.30, 0.59, 0.11);\n"
     "  float bright = dot(color, gray_coeff);\n"
     "  return mix(1.0 + shine, 1.0 - shine, bright);\n"
     "}\n"
     "\n"
     "float3 lookup(float2 pixel_no, float offset_x, float offset_y, float3 color, float gamma, float shine) {\n"
     "  float2 offset = float2(offset_x, offset_y);\n"
     "  float delta = dist(fract(pixel_no), offset + float2(0.5, 0.5));\n"
     "  return color * exp(-gamma * delta * color_bloom(color, shine));\n"
     "}\n"
     "\n"
     "fragment float4 neostation_fragment(NeoVertexOut in [[stage_in]], texture2d<float> source [[texture(0)]],\n"
     "                                    sampler smp [[sampler(0)]], constant NeoUniforms &u [[buffer(0)]]) {\n"
     "  float gamma = NEO_PARAM(u, 0);\n"
     "  float shine = NEO_PARAM(u, 1);\n"
     "  float blend = NEO_PARAM(u, 2);\n"
     "  float soft = NEO_PARAM(u, 3);\n"
     "\n"
     "  // Vertex stage\n"
     "  float2 pixel_no = in.coord * u.OriginalSize.xy;\n"
     "  float2 d = u.OriginalSize.zw;\n"
     "\n"
     "  float4 c00_10 = float4((pixel_no + float2(-1.0, -1.0) * soft) * d,\n"
     "                         (pixel_no + float2(0.0, -1.0) * soft) * d);\n"
     "  float4 c20_01 = float4((pixel_no + float2(1.0, -1.0) * soft) * d,\n"
     "                         (pixel_no + float2(-1.0, 0.0) * soft) * d);\n"
     "  float4 c21_02 = float4((pixel_no + float2(1.0, 0.0) * soft) * d,\n"
     "                         (pixel_no + float2(-1.0, 1.0) * soft) * d);\n"
     "  float4 c12_22 = float4((pixel_no + float2(0.0, 1.0) * soft) * d,\n"
     "                         (pixel_no + float2(1.0, 1.0) * soft) * d);\n"
     "  float2 c11 = pixel_no * d;\n"
     "\n"
     "  // Fragment stage\n"
     "  float3 mid_color = lookup(pixel_no, 0.0, 0.0, NEO_SAMPLE(source, smp, u, c11).rgb, gamma, shine);\n"
     "  float3 color = float3(0.0, 0.0, 0.0);\n"
     "  color += lookup(pixel_no, -1.0, -1.0, NEO_SAMPLE(source, smp, u, c00_10.xy).rgb, gamma, shine);\n"
     "  color += lookup(pixel_no, 0.0, -1.0, NEO_SAMPLE(source, smp, u, c00_10.zw).rgb, gamma, shine);\n"
     "  color += lookup(pixel_no, 1.0, -1.0, NEO_SAMPLE(source, smp, u, c20_01.xy).rgb, gamma, shine);\n"
     "  color += lookup(pixel_no, -1.0, 0.0, NEO_SAMPLE(source, smp, u, c20_01.zw).rgb, gamma, shine);\n"
     "  color += mid_color;\n"
     "  color += lookup(pixel_no, 1.0, 0.0, NEO_SAMPLE(source, smp, u, c21_02.xy).rgb, gamma, shine);\n"
     "  color += lookup(pixel_no, -1.0, 1.0, NEO_SAMPLE(source, smp, u, c21_02.zw).rgb, gamma, shine);\n"
     "  color += lookup(pixel_no, 0.0, 1.0, NEO_SAMPLE(source, smp, u, c12_22.xy).rgb, gamma, shine);\n"
     "  color += lookup(pixel_no, 1.0, 1.0, NEO_SAMPLE(source, smp, u, c12_22.zw).rgb, gamma, shine);\n"
     "  float3 out_color = mix(1.2 * mid_color, color, float3(blend));\n"
     "\n"
     "  return float4(out_color, 1.0);\n"
     "}\n";

static NSString *const kZfastLcdSource =
    @"/*\n"
     "    zfast_lcd_standard - A very simple LCD shader meant to be used at 1080p\n"
     "        on the raspberry pi 3.\n"
     "\n"
     "    Copyright (C) 2017 Greg Hogan (SoltanGris42)\n"
     "    This program is free software; you can redistribute it and/or modify it\n"
     "    under the terms of the GNU General Public License as published by the Free\n"
     "    Software Foundation; either version 2 of the License, or (at your option)\n"
     "    any later version.\n"
     "Notes:  This shader just does nearest neighbor scaling of the game and then\n"
     "        darkens the border pixels to imitate an LCD screen. You can change the\n"
     "        amount of darkening and the thickness of the borders.  You can also\n"
     "        do basic gamma adjustment.\n"
     "\n"
     "*/\n"
     "// Ported to Metal for NeoStation from libretro/slang-shaders\n"
     "// handheld/shaders/zfast_lcd.slang (preset: filter_linear0 = true).\n"
     "// BLACK_OUT_BORDER is defined upstream but used by no code of this file.\n"
     "// Upstream parameters:\n"
     "// #pragma parameter BORDERMULT \"Border Multiplier\" 14.0 -40.0 40.0 1.0\n"
     "// #pragma parameter GBAGAMMA \"GBA Gamma Hack\" 1.0 0.0 1.0 1.0\n"
     "\n"
     "fragment float4 neostation_fragment(NeoVertexOut in [[stage_in]], texture2d<float> source [[texture(0)]],\n"
     "                                    sampler smp [[sampler(0)]], constant NeoUniforms &u [[buffer(0)]]) {\n"
     "  float BORDERMULT = NEO_PARAM(u, 0);\n"
     "  float GBAGAMMA = NEO_PARAM(u, 1);\n"
     "  float2 vTexCoord = in.coord;\n"
     "\n"
     "  float2 texcoordInPixels = vTexCoord.xy * u.OriginalSize.xy;\n"
     "  float2 centerCoord = floor(texcoordInPixels.xy) + float2(0.5, 0.5);\n"
     "  float2 sourceCoordInPixels = vTexCoord.xy * u.SourceSize.xy;\n"
     "  float2 sourceCenterCoord = floor(sourceCoordInPixels.xy) + float2(0.5, 0.5);\n"
     "  float2 distFromCenter = abs(centerCoord - texcoordInPixels);\n"
     "\n"
     "  float Y = max(distFromCenter.x, (distFromCenter.y));\n"
     "\n"
     "  Y = Y * Y;\n"
     "  float YY = Y * Y;\n"
     "  float YYY = YY * Y;\n"
     "\n"
     "  float LineWeight = YY - 2.7 * YYY;\n"
     "  LineWeight = 1.0 - BORDERMULT * LineWeight;\n"
     "\n"
     "  float3 colour = NEO_SAMPLE(source, smp, u, u.SourceSize.zw * sourceCenterCoord).rgb * LineWeight;\n"
     "\n"
     "  if (GBAGAMMA > 0.5) {\n"
     "    colour *= 0.6 + 0.4 * (colour);  // fake gamma because the pi is too slow!\n"
     "  }\n"
     "\n"
     "  return float4(colour.rgb, 1.0);\n"
     "}\n";

NSString *LibretroShaderPrelude(void) {
  return kPreludeSource;
}

NSString *LibretroShaderPassthroughSource(void) {
  return kPassthroughSource;
}

@interface LibretroShaderParameter ()
- (instancetype)initWithIdentifier:(NSString *)identifier
                          labelKey:(NSString *)labelKey
                      defaultValue:(float)defaultValue
                           minimum:(float)minimum
                           maximum:(float)maximum
                              step:(float)step
                              slot:(NSUInteger)slot
                  distortsGeometry:(BOOL)distortsGeometry;
@end

@implementation LibretroShaderParameter

- (instancetype)initWithIdentifier:(NSString *)identifier
                          labelKey:(NSString *)labelKey
                      defaultValue:(float)defaultValue
                           minimum:(float)minimum
                           maximum:(float)maximum
                              step:(float)step
                              slot:(NSUInteger)slot
                  distortsGeometry:(BOOL)distortsGeometry {
  self = [super init];
  if (self) {
    _identifier = [identifier copy];
    _labelKey = [labelKey copy];
    _defaultValue = defaultValue;
    _minimum = minimum;
    _maximum = maximum;
    _step = step;
    _slot = slot;
    _distortsGeometry = distortsGeometry;
  }
  return self;
}

@end

@interface LibretroShaderPreset ()
- (instancetype)initWithIdentifier:(NSString *)identifier
                           nameKey:(NSString *)nameKey
                          category:(NSString *)category
                      upstreamPath:(NSString *)upstreamPath
                           license:(NSString *)license
                           authors:(NSString *)authors
                            filter:(LibretroShaderFilter)filter
                        parameters:(NSArray<LibretroShaderParameter *> *)parameters
                    fragmentSource:(NSString *)fragmentSource;
@end

@implementation LibretroShaderPreset

- (instancetype)initWithIdentifier:(NSString *)identifier
                           nameKey:(NSString *)nameKey
                          category:(NSString *)category
                      upstreamPath:(NSString *)upstreamPath
                           license:(NSString *)license
                           authors:(NSString *)authors
                            filter:(LibretroShaderFilter)filter
                        parameters:(NSArray<LibretroShaderParameter *> *)parameters
                    fragmentSource:(NSString *)fragmentSource {
  self = [super init];
  if (self) {
    _identifier = [identifier copy];
    _nameKey = [nameKey copy];
    _category = [category copy];
    _upstreamPath = [upstreamPath copy];
    _license = [license copy];
    _authors = [authors copy];
    _filter = filter;
    _parameters = [parameters copy];
    _fragmentSource = [fragmentSource copy];
  }
  return self;
}

- (NSDictionary<NSString *, NSNumber *> *)resolvedParameters:(nullable NSDictionary<NSString *, NSNumber *> *)stored {
  NSMutableDictionary<NSString *, NSNumber *> *resolved =
      [NSMutableDictionary dictionaryWithCapacity:_parameters.count];
  NSDictionary *values = [stored isKindOfClass:[NSDictionary class]] ? stored : nil;
  for (LibretroShaderParameter *parameter in _parameters) {
    float value = parameter.defaultValue;
    id candidate = values[parameter.identifier];
    if ([candidate isKindOfClass:[NSNumber class]]) {
      float number = [(NSNumber *)candidate floatValue];
      if (isfinite(number)) value = fminf(fmaxf(number, parameter.minimum), parameter.maximum);
    }
    resolved[parameter.identifier] = @(value);
  }
  return [resolved copy];
}

@end

/// Arguments in the order of the upstream "#pragma parameter" line:
/// default, minimum, maximum, step.
static LibretroShaderParameter *MakeParameter(NSString *identifier, NSString *labelKey, float defaultValue,
                                              float minimum, float maximum, float step, NSUInteger slot,
                                              BOOL distortsGeometry) {
  return [[LibretroShaderParameter alloc] initWithIdentifier:identifier
                                                    labelKey:labelKey
                                                defaultValue:defaultValue
                                                     minimum:minimum
                                                     maximum:maximum
                                                        step:step
                                                        slot:slot
                                            distortsGeometry:distortsGeometry];
}

static LibretroShaderPreset *MakePreset(NSString *identifier, NSString *nameKey, NSString *category,
                                        NSString *upstreamPath, NSString *license, NSString *authors,
                                        LibretroShaderFilter filter, NSArray<LibretroShaderParameter *> *parameters,
                                        NSString *fragmentSource) {
  return [[LibretroShaderPreset alloc] initWithIdentifier:identifier
                                                  nameKey:nameKey
                                                 category:category
                                             upstreamPath:upstreamPath
                                                  license:license
                                                  authors:authors
                                                   filter:filter
                                               parameters:parameters
                                           fragmentSource:fragmentSource];
}

@implementation LibretroShaderLibrary

+ (NSArray<LibretroShaderPreset *> *)presets {
  static NSArray<LibretroShaderPreset *> *presets;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    presets = @[
      MakePreset(@"sharp-bilinear", @"shaderSharpBilinear", @"scaling",
                 @"pixel-art-scaling/shaders/sharp-bilinear.slang", @"Public domain", @"Themaister",
                 LibretroShaderFilterLinear, @[
                   MakeParameter(@"SHARP_BILINEAR_PRE_SCALE", @"paramPrescale", 4.0f, 1.0f, 10.0f, 1.0f, 0, NO),
                   MakeParameter(@"AUTO_PRESCALE", @"paramAutoPrescale", 1.0f, 0.0f, 1.0f, 1.0f, 1, NO),
                 ],
                 kSharpBilinearSource),
      MakePreset(@"crt-lottes-fast", @"shaderCrtLottesFast", @"crt", @"crt/shaders/crt-lottes-fast.slang",
                 @"Unlicense", @"Timothy Lottes, hunterk", LibretroShaderFilterLinear, @[
                   MakeParameter(@"MASK", @"paramMaskType", 1.0f, 0.0f, 3.0f, 1.0f, 0, NO),
                   MakeParameter(@"MASK_INTENSITY", @"paramMaskIntensity", 0.5f, 0.0f, 1.0f, 0.05f, 1, NO),
                   MakeParameter(@"SCANLINE_THINNESS", @"paramScanlineThinness", 0.5f, 0.0f, 1.0f, 0.1f, 2, NO),
                   MakeParameter(@"SCAN_BLUR", @"paramHorizontalBlur", 2.5f, 1.0f, 3.0f, 0.1f, 3, NO),
                   MakeParameter(@"CURVATURE", @"paramCurvature", 0.02f, 0.0f, 0.25f, 0.01f, 4, YES),
                   MakeParameter(@"CORNER", @"paramCornerSize", 3.0f, 0.0f, 11.0f, 1.0f, 5, YES),
                   MakeParameter(@"CRT_GAMMA", @"paramGamma", 2.4f, 0.0f, 51.0f, 0.1f, 6, NO),
                 ],
                 kCrtLottesFastSource),
      MakePreset(@"crt-hyllian-fast", @"shaderCrtHyllianFast", @"crt",
                 @"crt/shaders/hyllian/crt-hyllian-fast.slang", @"MIT",
                 @"Hyllian, cgwg, DariusG, hunterk", LibretroShaderFilterNearest, @[
                   MakeParameter(@"MASK_INTENSITY", @"paramMaskIntensity", 0.5f, 0.0f, 1.0f, 0.1f, 0, NO),
                   MakeParameter(@"InputGamma", @"paramInputGamma", 2.4f, 0.0f, 5.0f, 0.1f, 1, NO),
                   MakeParameter(@"OutputGamma", @"paramOutputGamma", 2.2f, 0.0f, 5.0f, 0.1f, 2, NO),
                   MakeParameter(@"BRIGHTBOOST", @"paramBrightness", 1.5f, 0.0f, 2.0f, 0.1f, 3, NO),
                   MakeParameter(@"SCANLINES", @"paramScanlineStrength", 0.72f, 0.0f, 1.0f, 0.02f, 4, NO),
                   MakeParameter(@"SHARPER", @"paramSharper", 0.0f, 0.0f, 1.0f, 1.0f, 5, NO),
                 ],
                 kCrtHyllianFastSource),
      MakePreset(@"zfast-crt", @"shaderZfastCrt", @"crt", @"crt/shaders/zfast_crt/zfast_crt_finemask.slang",
                 @"GPL-2.0-or-later", @"Greg Hogan (SoltanGris42)", LibretroShaderFilterLinear, @[
                   MakeParameter(@"BLURSCALEX", @"paramHorizontalBlur", 0.30f, 0.0f, 1.0f, 0.05f, 0, NO),
                   MakeParameter(@"LOWLUMSCAN", @"paramScanlineDark", 6.0f, 0.0f, 10.0f, 0.5f, 1, NO),
                   MakeParameter(@"HILUMSCAN", @"paramScanlineBright", 8.0f, 0.0f, 50.0f, 1.0f, 2, NO),
                   MakeParameter(@"BRIGHTBOOST", @"paramBrightness", 1.25f, 0.5f, 1.5f, 0.05f, 3, NO),
                   MakeParameter(@"MASK_DARK", @"paramMaskDarkness", 0.25f, 0.0f, 1.0f, 0.05f, 4, NO),
                   MakeParameter(@"MASK_FADE", @"paramMaskFade", 0.8f, 0.0f, 1.0f, 0.05f, 5, NO),
                 ],
                 kZfastCrtSource),
      MakePreset(@"scanlines-sine-abs", @"shaderScanlines", @"scanlines",
                 @"scanlines/shaders/scanlines-sine-abs.slang", @"Public domain", @"RiskyJumps",
                 LibretroShaderFilterFollowSmoothing, @[
                   MakeParameter(@"amp", @"paramAmplitude", 1.25f, 0.0f, 2.0f, 0.05f, 0, NO),
                   MakeParameter(@"phase", @"paramPhase", 0.5f, 0.0f, 2.0f, 0.05f, 1, NO),
                   MakeParameter(@"lines_black", @"paramLinesBlack", 0.0f, 0.0f, 1.0f, 0.05f, 2, NO),
                   MakeParameter(@"lines_white", @"paramLinesWhite", 1.0f, 0.0f, 2.0f, 0.05f, 3, NO),
                 ],
                 kScanlinesSineAbsSource),
      MakePreset(@"lcd3x", @"shaderLcd3x", @"lcd", @"handheld/shaders/lcd3x.slang", @"Public domain", @"Gigaherz",
                 LibretroShaderFilterNearest, @[
                   MakeParameter(@"brighten_scanlines", @"paramScanlineBrightness", 16.0f, 1.0f, 32.0f, 0.5f, 0, NO),
                   MakeParameter(@"brighten_lcd", @"paramLcdBrightness", 4.0f, 1.0f, 12.0f, 0.1f, 1, NO),
                 ],
                 kLcd3xSource),
      MakePreset(@"sameboy-lcd", @"shaderSameBoyLcd", @"lcd", @"handheld/shaders/sameboy-lcd.slang", @"MIT",
                 @"Lior Halphon (LIJI32)", LibretroShaderFilterNearest, @[
                   MakeParameter(@"COLOR_LOW", @"paramColorLow", 0.8f, 0.0f, 1.5f, 0.05f, 0, NO),
                   MakeParameter(@"COLOR_HIGH", @"paramColorHigh", 1.0f, 0.0f, 1.5f, 0.05f, 1, NO),
                   MakeParameter(@"SCANLINE_DEPTH", @"paramScanlineDepth", 0.1f, 0.0f, 2.0f, 0.05f, 2, NO),
                 ],
                 kSameBoyLcdSource),
      MakePreset(@"dot", @"shaderDotMatrix", @"lcd", @"handheld/shaders/dot.slang", @"Public domain", @"Themaister",
                 LibretroShaderFilterNearest, @[
                   MakeParameter(@"gamma", @"paramGamma", 2.4f, 0.0f, 5.0f, 0.05f, 0, NO),
                   MakeParameter(@"shine", @"paramShine", 0.05f, 0.0f, 0.5f, 0.01f, 1, NO),
                   MakeParameter(@"blend", @"paramBlend", 0.65f, 0.0f, 1.0f, 0.01f, 2, NO),
                   MakeParameter(@"soft", @"paramSoftness", 0.0f, 0.0f, 1.0f, 0.1f, 3, NO),
                 ],
                 kDotSource),
      MakePreset(@"zfast-lcd", @"shaderZfastLcd", @"lcd", @"handheld/shaders/zfast_lcd.slang", @"GPL-2.0-or-later",
                 @"Greg Hogan (SoltanGris42)", LibretroShaderFilterLinear, @[
                   MakeParameter(@"BORDERMULT", @"paramBorderSize", 14.0f, -40.0f, 40.0f, 1.0f, 0, NO),
                   MakeParameter(@"GBAGAMMA", @"paramGbaGamma", 1.0f, 0.0f, 1.0f, 1.0f, 1, NO),
                 ],
                 kZfastLcdSource),
    ];
  });
  return presets;
}

+ (nullable LibretroShaderPreset *)presetWithIdentifier:(NSString *)identifier {
  if (![identifier isKindOfClass:[NSString class]]) return nil;
  for (LibretroShaderPreset *preset in [self presets]) {
    if ([preset.identifier isEqualToString:identifier]) return preset;
  }
  return nil;
}

+ (NSString *)sourceForPreset:(nullable LibretroShaderPreset *)preset {
  NSString *fragment = preset != nil ? preset.fragmentSource : kPassthroughSource;
  return [kPreludeSource stringByAppendingString:fragment];
}

@end
