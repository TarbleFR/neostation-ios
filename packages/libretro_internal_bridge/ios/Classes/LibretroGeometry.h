#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Plain rectangle used by the portable layout code (no CoreGraphics, so the
/// macOS host test can link it with Foundation only). Origin top-left.
typedef struct {
  double x;
  double y;
  double w;
  double h;
} LibretroRect;

typedef struct {
  double w;
  double h;
} LibretroSize;

typedef struct {
  double top;
  double left;
  double bottom;
  double right;
} LibretroInsets;

FOUNDATION_EXPORT LibretroRect LibretroRectMake(double x, double y, double w, double h);
FOUNDATION_EXPORT const LibretroRect LibretroRectUnit;  // {0, 0, 1, 1}
FOUNDATION_EXPORT BOOL LibretroRectIsEmpty(LibretroRect rect);
FOUNDATION_EXPORT BOOL LibretroRectContainsPoint(LibretroRect rect, double x, double y);
FOUNDATION_EXPORT BOOL LibretroRectEqualToRect(LibretroRect a, LibretroRect b, double tolerance);
/// Grows the rectangle by the given edges (negative values shrink it).
FOUNDATION_EXPORT LibretroRect LibretroRectOutset(LibretroRect rect, LibretroInsets edges);
FOUNDATION_EXPORT LibretroRect LibretroRectInset(LibretroRect rect, LibretroInsets insets);
/// Largest rectangle of display aspect `aspect` (width / height) centred in
/// `container`. Returns `container` when `aspect` is not positive.
FOUNDATION_EXPORT LibretroRect LibretroRectAspectFit(LibretroRect container, double aspect);
/// Maps `rect`, expressed in a space of size `from`, into `to`.
FOUNDATION_EXPORT LibretroRect LibretroRectScale(LibretroRect rect, LibretroSize from, LibretroRect to);
/// Rectangle scaled by `factor` around its centre.
FOUNDATION_EXPORT LibretroRect LibretroRectScaleAroundCenter(LibretroRect rect, double factor);
FOUNDATION_EXPORT LibretroRect LibretroRectIntersection(LibretroRect a, LibretroRect b);

/// Screen format chosen in the in-game menu ("Format d'écran").
typedef NS_ENUM(NSInteger, LibretroScreenFormat) {
  /// Rapport fourni par le cœur (retro_game_geometry.aspect_ratio).
  LibretroScreenFormatOriginal = 0,
  LibretroScreenFormat4x3 = 1,
  LibretroScreenFormat16x9 = 2,
  LibretroScreenFormat16x10 = 3,
  /// Fills the game area; proportions are not kept.
  LibretroScreenFormatStretch = 4,
};

/// "original", "4:3", "16:9", "16:10", "stretch".
FOUNDATION_EXPORT NSString *LibretroScreenFormatIdentifier(LibretroScreenFormat format);
/// Unknown or nil identifiers give LibretroScreenFormatOriginal.
FOUNDATION_EXPORT LibretroScreenFormat LibretroScreenFormatFromIdentifier(NSString *_Nullable identifier);
FOUNDATION_EXPORT NSArray<NSString *> *LibretroScreenFormatIdentifiers(void);

/// Display aspect of a normalized sub-rectangle `source` of a core image
/// whose full display aspect is `coreAspect`, after `rotation` quarter turns
/// (odd rotations invert it).
FOUNDATION_EXPORT double LibretroSourceAspect(double coreAspect, LibretroRect source, unsigned rotation);

/// Destination of one screen inside `container`:
/// - Original: aspect fit with `sourceAspect`;
/// - 4:3, 16:9, 16:10: aspect fit with that ratio (the picture is stretched to it);
/// - Stretch: `container` itself.
/// Never larger than `container`, always centred.
FOUNDATION_EXPORT LibretroRect LibretroFitScreen(LibretroRect container, double sourceAspect,
                                                 LibretroScreenFormat format);

/// SourceSize / OriginalSize given to a shader preset for one screen
/// (LibretroShaderUniforms). `texels`: size of the screen's part of the core
/// frame, in texels. `nominal`: the console's pixels for that screen ({0,0}
/// when unknown, e.g. arcade).
/// Returns `nominal` only when the frame is a uniform upscale of it: both
/// axis scales (texels / nominal) within 2 % of each other and neither below
/// 0.98 (PSP 960x544 -> 480x272, N64 or 3DS 640x480 -> 320x240). Otherwise
/// returns `texels` unchanged, the size RetroArch gives slang shaders
/// (Nestopia's 256x224 NES frame against 256x240, mGBA's 256x224 Super Game
/// Boy frame against 160x144, PSX 368x240 or 320x288 against 320x240).
/// Never below 1x1; NaN or infinite sizes count as unknown.
FOUNDATION_EXPORT LibretroSize LibretroShaderSourceSize(LibretroSize texels, LibretroSize nominal);

/// One drawn screen: where it appears (`output`, any coordinate space) and
/// which normalized part of the core image it shows (`source`, top-left
/// origin, before rotation).
typedef struct {
  LibretroRect output;
  LibretroRect source;
  unsigned rotation;
} LibretroScreenMapping;

/// Converts a point in the coordinate space of `mapping.output` into
/// RETRO_DEVICE_POINTER coordinates (-0x7fff..0x7fff) relative to the WHOLE
/// core image, undoing the rotation (image corner (i + rotation) % 4 is shown
/// at output corner i, clockwise from top-left). Returns NO when the point is
/// outside `output`; with `clamp`, the coordinates are clamped to the output
/// edge instead (used while a finger that started inside keeps moving).
FOUNDATION_EXPORT BOOL LibretroPointerFromPoint(LibretroScreenMapping mapping, double x, double y, BOOL clamp,
                                                int16_t *outX, int16_t *outY);

/// D-pad directions for a point relative to `frame`: 8 sectors around the
/// centre with a dead zone of 12 % of the width. Bits: 1 up, 2 down, 4 left,
/// 8 right.
typedef NS_OPTIONS(uint8_t, LibretroDirection) {
  LibretroDirectionUp = 1 << 0,
  LibretroDirectionDown = 1 << 1,
  LibretroDirectionLeft = 1 << 2,
  LibretroDirectionRight = 1 << 3,
};
FOUNDATION_EXPORT LibretroDirection LibretroDPadDirections(LibretroRect frame, double x, double y);

/// Stick deflection in [-1, 1] (y positive downward, libretro convention),
/// clamped to the unit circle, radius = half the frame width.
FOUNDATION_EXPORT void LibretroStickVector(LibretroRect frame, double x, double y, double *outX, double *outY);

NS_ASSUME_NONNULL_END
