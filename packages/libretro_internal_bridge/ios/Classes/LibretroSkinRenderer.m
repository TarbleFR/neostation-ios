#import "LibretroSkinRenderer.h"

#import <CommonCrypto/CommonDigest.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#import <QuartzCore/QuartzCore.h>

#include <math.h>
#include <sys/stat.h>

/// Memory cache budget of rasterised skin images (bytes).
static const NSUInteger LibretroSkinCacheCostLimit = 96u * 1024u * 1024u;
/// Longest side of a rasterised image, in pixels.
static const double LibretroSkinMaximumPixels = 4096.0;
/// KVC key holding the cache key of the image a layer waits for or shows.
static NSString *const LibretroSkinImageKey = @"neostationSkinImageKey";

typedef NS_ENUM(NSInteger, LibretroSkinImageKind) {
  LibretroSkinImageKindNone = 0,
  LibretroSkinImageKindBitmap,  // PNG or JPEG
  LibretroSkinImageKindPDF,
};

#pragma mark - Shared image pipeline

/// Private serial queue: decoding, rasterising and the disk cache.
static dispatch_queue_t LibretroSkinQueue(void) {
  static dispatch_queue_t queue;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    dispatch_queue_attr_t attributes =
        dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0);
    queue = dispatch_queue_create("neostation.libretro.skin-images", attributes);
  });
  return queue;
}

static NSCache<NSString *, UIImage *> *LibretroSkinMemoryCache(void) {
  static NSCache<NSString *, UIImage *> *cache;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    cache = [[NSCache alloc] init];
    cache.name = @"neostation.libretro.skin-images";
    cache.totalCostLimit = LibretroSkinCacheCostLimit;
  });
  return cache;
}

static NSString *LibretroSkinCacheFolder(NSString *cacheDirectory) {
  if (cacheDirectory.length == 0) return nil;
  return [cacheDirectory stringByAppendingPathComponent:@"SkinCache"];
}

/// Image type from the first bytes (never from the name).
static LibretroSkinImageKind LibretroSkinImageKindAtPath(NSString *path) {
  if (path.length == 0) return LibretroSkinImageKindNone;
  NSData *data = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];
  if (data.length < 4) return LibretroSkinImageKindNone;
  const uint8_t *bytes = data.bytes;
  static const uint8_t png[8] = {0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A};
  if (data.length >= 8 && memcmp(bytes, png, 8) == 0) return LibretroSkinImageKindBitmap;
  if (bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF) return LibretroSkinImageKindBitmap;
  // The PDF header may follow a few bytes of junk (PDF 1.7, 7.5.2).
  NSUInteger limit = MIN(data.length, (NSUInteger)1024);
  for (NSUInteger offset = 0; offset + 5 <= limit; offset++) {
    if (memcmp(bytes + offset, "%PDF-", 5) == 0) return LibretroSkinImageKindPDF;
  }
  return LibretroSkinImageKindNone;
}

/// Pixel size for `points` at `scale`, capped to LibretroSkinMaximumPixels.
static BOOL LibretroSkinPixelSize(CGSize points, CGFloat scale, size_t *width, size_t *height) {
  if (!(points.width > 0) || !(points.height > 0) || !isfinite(points.width) || !isfinite(points.height)) return NO;
  double factor = scale > 0 && isfinite(scale) ? scale : 1;
  double w = ceil(points.width * factor), h = ceil(points.height * factor);
  double longest = MAX(w, h);
  if (longest > LibretroSkinMaximumPixels) {
    double shrink = LibretroSkinMaximumPixels / longest;
    w = floor(w * shrink);
    h = floor(h * shrink);
  }
  *width = (size_t)MAX(w, 1.0);
  *height = (size_t)MAX(h, 1.0);
  return YES;
}

/// Cache key: hash of the image path, its modification date and size, and
/// the pixel size it is rasterised at.
static NSString *LibretroSkinCacheKey(NSString *path, size_t width, size_t height) {
  NSString *standardized = path.stringByStandardizingPath;
  long long modified = 0, length = 0;
  if (standardized.length > 0) {
    struct stat info;
    if (stat(standardized.fileSystemRepresentation, &info) == 0) {
      modified = (long long)info.st_mtimespec.tv_sec * 1000LL + (long long)info.st_mtimespec.tv_nsec / 1000000LL;
      length = (long long)info.st_size;
    }
  }
  NSString *source = [NSString stringWithFormat:@"%@|%lld|%lld|%zux%zu", standardized, modified, length, width, height];
  NSData *data = [source dataUsingEncoding:NSUTF8StringEncoding];
  unsigned char digest[CC_SHA256_DIGEST_LENGTH];
  CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
  NSMutableString *hex = [NSMutableString stringWithCapacity:40];
  for (int index = 0; index < 20; index++) [hex appendFormat:@"%02x", digest[index]];
  return hex;
}

/// PNG / JPEG downsampled by ImageIO, or page 1 of a PDF drawn into a
/// bitmap of exactly `width` x `height` pixels. +1 image, NULL on failure.
static CGImageRef LibretroSkinCreateRaster(NSString *path, size_t width, size_t height) CF_RETURNS_RETAINED;
static CGImageRef LibretroSkinCreateRaster(NSString *path, size_t width, size_t height) {
  LibretroSkinImageKind kind = LibretroSkinImageKindAtPath(path);
  if (kind == LibretroSkinImageKindNone || width == 0 || height == 0) return NULL;
  NSURL *url = [NSURL fileURLWithPath:path];
  if (kind == LibretroSkinImageKindBitmap) {
    NSDictionary *sourceOptions = @{(__bridge NSString *)kCGImageSourceShouldCache : @NO};
    CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)url, (__bridge CFDictionaryRef)sourceOptions);
    if (source == NULL) return NULL;
    NSDictionary *options = @{
      (__bridge NSString *)kCGImageSourceCreateThumbnailFromImageAlways : @YES,
      (__bridge NSString *)kCGImageSourceCreateThumbnailWithTransform : @YES,
      (__bridge NSString *)kCGImageSourceShouldCacheImmediately : @YES,
      (__bridge NSString *)kCGImageSourceThumbnailMaxPixelSize : @(MAX(width, height)),
    };
    CGImageRef image = CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)options);
    CFRelease(source);
    return image;
  }

  // PDF: one CGPDFDocument per render (CoreGraphics documents are not
  // shared between threads).
  CGPDFDocumentRef document = CGPDFDocumentCreateWithURL((__bridge CFURLRef)url);
  if (document == NULL) return NULL;
  CGPDFPageRef page = CGPDFDocumentGetPage(document, 1);
  if (page == NULL) {
    CGPDFDocumentRelease(document);
    return NULL;
  }
  CGRect box = CGPDFPageGetBoxRect(page, kCGPDFCropBox);
  int angle = CGPDFPageGetRotationAngle(page);
  CGSize pageSize = (abs(angle) % 180) == 90 ? CGSizeMake(box.size.height, box.size.width) : box.size;
  if (!(pageSize.width > 0) || !(pageSize.height > 0)) {
    CGPDFDocumentRelease(document);
    return NULL;
  }
  CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  CGContextRef context =
      CGBitmapContextCreate(NULL, width, height, 8, 0, space,
                            (CGBitmapInfo)kCGImageAlphaPremultipliedFirst | (CGBitmapInfo)kCGBitmapByteOrder32Little);
  CGColorSpaceRelease(space);
  if (context == NULL) {
    CGPDFDocumentRelease(document);
    return NULL;
  }
  CGContextClearRect(context, CGRectMake(0, 0, (CGFloat)width, (CGFloat)height));
  CGContextSetInterpolationQuality(context, kCGInterpolationHigh);
  // The drawing transform never scales up: map the page at its own size
  // (rotation and origin), then scale to the requested pixels.
  CGContextScaleCTM(context, (CGFloat)width / pageSize.width, (CGFloat)height / pageSize.height);
  CGAffineTransform transform = CGPDFPageGetDrawingTransform(
      page, kCGPDFCropBox, CGRectMake(0, 0, pageSize.width, pageSize.height), 0, true);
  CGContextConcatCTM(context, transform);
  CGContextDrawPDFPage(context, page);
  CGImageRef image = CGBitmapContextCreateImage(context);
  CGContextRelease(context);
  CGPDFDocumentRelease(document);
  return image;
}

static CGImageRef LibretroSkinCreateFromDisk(NSString *file) CF_RETURNS_RETAINED;
static CGImageRef LibretroSkinCreateFromDisk(NSString *file) {
  if (file == nil || ![[NSFileManager defaultManager] fileExistsAtPath:file]) return NULL;
  CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:file], NULL);
  if (source == NULL) return NULL;
  NSDictionary *options = @{(__bridge NSString *)kCGImageSourceShouldCacheImmediately : @YES};
  CGImageRef image = NULL;
  if (CGImageSourceGetCount(source) > 0) {
    image = CGImageSourceCreateImageAtIndex(source, 0, (__bridge CFDictionaryRef)options);
  }
  CFRelease(source);
  return image;
}

/// <key>.png plus <key>.source (the standardized image path) so a skin's
/// entries can be found again by purgeCacheForSkinDirectory.
static void LibretroSkinWriteToDisk(CGImageRef image, NSString *file, NSString *sourcePath) {
  NSString *folder = file.stringByDeletingLastPathComponent;
  [[NSFileManager defaultManager] createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:nil];
  CGImageDestinationRef destination =
      CGImageDestinationCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:file], CFSTR("public.png"), 1, NULL);
  if (destination == NULL) return;
  CGImageDestinationAddImage(destination, image, NULL);
  BOOL written = CGImageDestinationFinalize(destination);
  CFRelease(destination);
  if (!written) {
    [[NSFileManager defaultManager] removeItemAtPath:file error:nil];
    return;
  }
  NSString *sidecar = [file.stringByDeletingPathExtension stringByAppendingPathExtension:@"source"];
  [sourcePath.stringByStandardizingPath writeToFile:sidecar atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

/// Removes cache entries whose source image is gone (deleted skin, or an
/// app container moved by an update). Once per cache folder and launch;
/// runs on the skin queue.
static void LibretroSkinPruneOnce(NSString *folder) {
  static NSMutableSet<NSString *> *pruned;
  if (folder == nil) return;
  if (pruned == nil) pruned = [NSMutableSet set];
  if ([pruned containsObject:folder]) return;
  [pruned addObject:folder];
  NSFileManager *manager = [NSFileManager defaultManager];
  for (NSString *name in [manager contentsOfDirectoryAtPath:folder error:nil]) {
    if (![name.pathExtension isEqualToString:@"source"]) continue;
    NSString *sidecar = [folder stringByAppendingPathComponent:name];
    NSString *source = [NSString stringWithContentsOfFile:sidecar encoding:NSUTF8StringEncoding error:nil];
    if (source.length > 0 && [manager fileExistsAtPath:source]) continue;
    [manager removeItemAtPath:sidecar error:nil];
    NSString *png = [sidecar.stringByDeletingPathExtension stringByAppendingPathExtension:@"png"];
    [manager removeItemAtPath:png error:nil];
  }
}

/// Memory cache, then disk cache, then rasterisation. Skin queue only.
static UIImage *LibretroSkinLoadImage(NSString *path, size_t width, size_t height, NSString *key,
                                      NSString *cacheDirectory) {
  NSCache<NSString *, UIImage *> *memory = LibretroSkinMemoryCache();
  UIImage *cached = [memory objectForKey:key];
  if (cached != nil) return cached;
  UIImage *result = nil;
  @autoreleasepool {
    NSString *folder = LibretroSkinCacheFolder(cacheDirectory);
    LibretroSkinPruneOnce(folder);
    NSString *file = folder != nil ? [folder stringByAppendingPathComponent:[key stringByAppendingPathExtension:@"png"]]
                                   : nil;
    CGImageRef image = LibretroSkinCreateFromDisk(file);
    if (image == NULL) {
      image = LibretroSkinCreateRaster(path, width, height);
      if (image != NULL && file != nil) LibretroSkinWriteToDisk(image, file, path);
    }
    if (image != NULL) {
      result = [UIImage imageWithCGImage:image];
      NSUInteger cost = CGImageGetBytesPerRow(image) * CGImageGetHeight(image);
      CGImageRelease(image);
      [memory setObject:result forKey:key cost:cost];
    }
  }
  return result;
}

#pragma mark - Geometry and style

static CGRect LibretroSkinCGRect(LibretroRect rect) {
  if (!isfinite(rect.x) || !isfinite(rect.y) || !isfinite(rect.w) || !isfinite(rect.h) || rect.w < 0 || rect.h < 0) {
    return CGRectZero;
  }
  return CGRectMake(rect.x, rect.y, rect.w, rect.h);
}

static UIColor *LibretroSkinColor(uint32_t argb) {
  return [UIColor colorWithRed:((argb >> 16) & 0xFF) / 255.0
                         green:((argb >> 8) & 0xFF) / 255.0
                          blue:(argb & 0xFF) / 255.0
                         alpha:((argb >> 24) & 0xFF) / 255.0];
}

/// `argb` mixed with white by `amount` (0-1), alpha kept.
static UIColor *LibretroSkinLighterColor(uint32_t argb, CGFloat amount) {
  CGFloat red = ((argb >> 16) & 0xFF) / 255.0, green = ((argb >> 8) & 0xFF) / 255.0, blue = (argb & 0xFF) / 255.0;
  return [UIColor colorWithRed:red + (1 - red) * amount
                         green:green + (1 - green) * amount
                          blue:blue + (1 - blue) * amount
                         alpha:((argb >> 24) & 0xFF) / 255.0];
}

static void LibretroSkinAddRoundedRect(CGMutablePathRef path, CGRect rect, CGFloat radius) {
  if (!(rect.size.width > 0) || !(rect.size.height > 0)) return;
  // CGPathAddRoundedRect asserts when a radius exceeds half a side.
  CGFloat limit = MIN(rect.size.width, rect.size.height) / 2;
  CGFloat corner = MAX(0, MIN(radius, limit));
  if (corner <= 0) {
    CGPathAddRect(path, NULL, rect);
  } else {
    CGPathAddRoundedRect(path, NULL, rect, corner, corner);
  }
}

/// Outline of a default-skin control in its own coordinates. +1 path.
static CGPathRef LibretroSkinCreateShapePath(LibretroSkinItemShape shape, CGSize size) CF_RETURNS_RETAINED;
static CGPathRef LibretroSkinCreateShapePath(LibretroSkinItemShape shape, CGSize size) {
  CGMutablePathRef path = CGPathCreateMutable();
  CGRect rect = CGRectMake(0, 0, size.width, size.height);
  if (!(size.width > 0) || !(size.height > 0)) return path;
  switch (shape) {
    case LibretroSkinItemShapeCircle:
    case LibretroSkinItemShapeStick:
      CGPathAddEllipseInRect(path, NULL, rect);
      break;
    case LibretroSkinItemShapePill:
      LibretroSkinAddRoundedRect(path, rect, size.height / 2);
      break;
    case LibretroSkinItemShapeRounded:
      LibretroSkinAddRoundedRect(path, rect, MIN(size.width, size.height) * 0.3);
      break;
    case LibretroSkinItemShapeDPad: {
      // Cross: two arms of a third of the size (non-zero winding: union).
      CGFloat armWidth = size.width / 3, armHeight = size.height / 3;
      CGFloat radius = MIN(armWidth, armHeight) * 0.2;
      LibretroSkinAddRoundedRect(path, CGRectMake(0, (size.height - armHeight) / 2, size.width, armHeight), radius);
      LibretroSkinAddRoundedRect(path, CGRectMake((size.width - armWidth) / 2, 0, armWidth, size.height), radius);
      break;
    }
    case LibretroSkinItemShapeNone:
      LibretroSkinAddRoundedRect(path, rect, MIN(size.width, size.height) / 2);
      break;
  }
  return path;
}

/// Four direction arrows of the D-pad cross. +1 path.
static CGPathRef LibretroSkinCreateArrowsPath(CGSize size) CF_RETURNS_RETAINED;
static CGPathRef LibretroSkinCreateArrowsPath(CGSize size) {
  CGMutablePathRef path = CGPathCreateMutable();
  if (!(size.width > 0) || !(size.height > 0)) return path;
  CGFloat arm = MIN(size.width, size.height) / 3;
  CGFloat half = arm * 0.2;
  CGFloat cx = size.width / 2, cy = size.height / 2;
  // Each arrow sits in the middle of its arm end, pointing outward.
  CGPoint tips[4] = {
      {cx, arm * 0.5 - half},
      {cx, size.height - arm * 0.5 + half},
      {arm * 0.5 - half, cy},
      {size.width - arm * 0.5 + half, cy},
  };
  CGFloat directions[4][2] = {{0, -1}, {0, 1}, {-1, 0}, {1, 0}};
  for (int index = 0; index < 4; index++) {
    CGFloat dx = directions[index][0], dy = directions[index][1];
    CGPoint tip = tips[index];
    CGPoint base = CGPointMake(tip.x - dx * half * 1.6, tip.y - dy * half * 1.6);
    CGPathMoveToPoint(path, NULL, tip.x, tip.y);
    CGPathAddLineToPoint(path, NULL, base.x + dy * half, base.y + dx * half);
    CGPathAddLineToPoint(path, NULL, base.x - dy * half, base.y - dx * half);
    CGPathCloseSubpath(path);
  }
  return path;
}

/// Font size of a default-skin glyph so it fits its control.
static CGFloat LibretroSkinLabelFontSize(NSString *label, LibretroSkinItemShape shape, CGSize size) {
  if (label.length == 0 || !(size.width > 0) || !(size.height > 0)) return 0;
  CGFloat base = shape == LibretroSkinItemShapeCircle ? MIN(size.width, size.height) * 0.42 : size.height * 0.46;
  if (shape == LibretroSkinItemShapeCircle && label.length > 1) base *= 0.8;
  UIFont *font = [UIFont systemFontOfSize:base weight:UIFontWeightSemibold];
  CGFloat width = [label sizeWithAttributes:@{NSFontAttributeName : font}].width;
  CGFloat maximum = size.width * 0.82;
  if (width > maximum && width > 0) base *= maximum / width;
  return MAX(base, 5);
}

/// Knob of a thumbstick, centred on the (possibly moved and scaled) frame.
static CGRect LibretroSkinKnobRect(LibretroLaidOutItem *laidOut) {
  CGRect frame = LibretroSkinCGRect(laidOut.frame);
  LibretroSkinItem *item = laidOut.item;
  double factor = item.frame.w > 0 && isfinite(item.frame.w) ? laidOut.frame.w / item.frame.w : 1;
  double width = item.thumbstickSize.w * factor, height = item.thumbstickSize.h * factor;
  if (!(width > 0) || !(height > 0) || !isfinite(width) || !isfinite(height)) {
    width = frame.size.width * 0.5;
    height = frame.size.height * 0.5;
  }
  return CGRectMake(CGRectGetMidX(frame) - width / 2, CGRectGetMidY(frame) - height / 2, width, height);
}

static BOOL LibretroSkinIsVector(LibretroSkinItem *item) {
  return item.shape != LibretroSkinItemShapeNone && item.kind != LibretroSkinItemKindTouchScreen;
}

static BOOL LibretroSkinHasLabel(LibretroSkinItem *item) {
  return item.label.length > 0 && item.shape != LibretroSkinItemShapeDPad && item.shape != LibretroSkinItemShapeStick &&
         item.kind == LibretroSkinItemKindButton;
}

/// Identity of an item's drawing, to keep its layers (and images) across
/// layouts of an equivalent representation. nil: nothing is drawn.
static NSString *LibretroSkinItemSignature(LibretroSkinItem *item) {
  if (item.kind == LibretroSkinItemKindTouchScreen) return nil;
  if (LibretroSkinIsVector(item)) {
    return [NSString stringWithFormat:@"vector-%ld-%ld", (long)item.shape, (long)item.kind];
  }
  return [NSString stringWithFormat:@"image-%ld|%@|%@", (long)item.kind, item.assetPath ?: @"",
                                    item.thumbstickAssetPath ?: @""];
}

#pragma mark - Item layers

/// Layers of one item, all positioned in renderer coordinates inside
/// `container` (zero-sized: it only groups opacity and visibility).
@interface LibretroSkinItemLayers : NSObject
@property(nonatomic, copy) NSString *identifier;
@property(nonatomic, copy) NSString *signature;
@property(nonatomic, strong) LibretroLaidOutItem *laidOut;
@property(nonatomic, strong) CALayer *container;
@property(nonatomic, strong, nullable) CAShapeLayer *shape;
@property(nonatomic, strong, nullable) CAShapeLayer *arrows;
@property(nonatomic, strong, nullable) CAShapeLayer *knob;
@property(nonatomic, strong, nullable) CATextLayer *text;
@property(nonatomic, strong, nullable) CALayer *image;
@property(nonatomic, strong, nullable) CALayer *knobImage;
/// Pressed overlay: a shape (vector and painted items) or a white layer
/// masked by the item's image.
@property(nonatomic, strong, nullable) CAShapeLayer *highlightShape;
@property(nonatomic, strong, nullable) CALayer *highlightImage;
@property(nonatomic, strong, nullable) CALayer *highlightMask;
@property(nonatomic, strong) CAShapeLayer *outline;
@end

@implementation LibretroSkinItemLayers
@end

static CALayer *LibretroSkinPlainLayer(CGFloat scale) {
  CALayer *layer = [CALayer layer];
  layer.contentsScale = scale;
  layer.contentsGravity = kCAGravityResize;
  return layer;
}

static CAShapeLayer *LibretroSkinShapeLayer(CGFloat scale) {
  CAShapeLayer *layer = [CAShapeLayer layer];
  layer.contentsScale = scale;
  return layer;
}

#pragma mark - Renderer

@implementation LibretroSkinRenderer {
  NSString *_cacheDirectory;
  CALayer *_panelLayer;
  CALayer *_backgroundLayer;
  NSMutableArray<LibretroSkinItemLayers *> *_items;
  LibretroSkinRepresentation *_representation;
  LibretroSkinLayoutResult *_layout;
  CGFloat _opacity;
  CGFloat _scale;
  BOOL _controlsHidden;
  NSSet<NSString *> *_pressed;
  BOOL _editing;
  NSString *_selectedItem;
}

- (instancetype)initWithCacheDirectory:(NSString *)cacheDirectory {
  self = [super initWithFrame:CGRectZero];
  if (self) {
    _cacheDirectory = [cacheDirectory isKindOfClass:[NSString class]] ? [cacheDirectory copy] : @"";
    _items = [NSMutableArray array];
    _pressed = [NSSet set];
    _opacity = 1;
    _scale = 2;
    self.userInteractionEnabled = NO;
    self.opaque = NO;
    self.backgroundColor = UIColor.clearColor;
    self.isAccessibilityElement = NO;
    self.accessibilityElementsHidden = YES;
    _panelLayer = [CALayer layer];
    _panelLayer.hidden = YES;
    _backgroundLayer = LibretroSkinPlainLayer(_scale);
    _backgroundLayer.hidden = YES;
    [self.layer addSublayer:_panelLayer];
    [self.layer addSublayer:_backgroundLayer];
  }
  return self;
}

- (CGFloat)currentDisplayScale {
  CGFloat scale = self.traitCollection.displayScale;
  if (!(scale > 0)) scale = UIScreen.mainScreen.scale;
  return scale > 0 ? scale : 2;
}

- (void)showRepresentation:(LibretroSkinRepresentation *)representation
                    layout:(LibretroSkinLayoutResult *)layout
                   opacity:(CGFloat)opacity
            controlsHidden:(BOOL)controlsHidden {
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  CGFloat scale = [self currentDisplayScale];
  BOOL sameContent = representation != nil && representation == _representation && layout == _layout &&
                     fabs(scale - _scale) < 0.01;
  _scale = scale;
  _representation = representation;
  _layout = layout;
  _opacity = isfinite(opacity) ? MIN(MAX(opacity, 0), 1) : 1;
  _controlsHidden = controlsHidden;
  if (representation == nil || layout == nil) {
    [self clearAll];
  } else if (sameContent) {
    // Same layout: only opacity and visibility change (controller
    // connected, opacity slider).
    if (!_backgroundLayer.hidden) {
      _backgroundLayer.opacity = representation.translucent ? (float)_opacity : 1.0f;
    }
    for (LibretroSkinItemLayers *layers in _items) [self applyStateToLayers:layers];
  } else {
    [self applyPanelAndBackground];
    [self applyItems];
  }
  [CATransaction commit];
}

- (void)clearAll {
  _panelLayer.hidden = YES;
  _backgroundLayer.hidden = YES;
  _backgroundLayer.contents = nil;
  [_backgroundLayer setValue:nil forKey:LibretroSkinImageKey];
  for (LibretroSkinItemLayers *layers in _items) [layers.container removeFromSuperlayer];
  [_items removeAllObjects];
}

- (void)applyPanelAndBackground {
  LibretroSkinRepresentation *representation = _representation;
  LibretroSkinLayoutResult *layout = _layout;
  // Portrait default skins: opaque controller panel below the items.
  CGRect panel = LibretroSkinCGRect(layout.panelFrame);
  if (representation.panelColor != 0 && !CGRectIsEmpty(panel)) {
    _panelLayer.hidden = NO;
    _panelLayer.frame = panel;
    UIColor *color = LibretroSkinColor(representation.panelColor);
    _panelLayer.backgroundColor = color.CGColor;
  } else {
    _panelLayer.hidden = YES;
  }

  CGRect skinRect = LibretroSkinCGRect(layout.skinRect);
  NSString *background = representation.generated ? nil : representation.backgroundPath;
  if (background.length > 0 && !CGRectIsEmpty(skinRect)) {
    _backgroundLayer.hidden = NO;
    _backgroundLayer.frame = skinRect;
    _backgroundLayer.contentsScale = _scale;
    // Opaque skins keep their image fully opaque; translucent ones follow
    // the user's opacity (Delta).
    _backgroundLayer.opacity = representation.translucent ? (float)_opacity : 1.0f;
    [self loadImageAtPath:background points:skinRect.size layer:_backgroundLayer mask:nil force:YES];
  } else {
    _backgroundLayer.hidden = YES;
    _backgroundLayer.contents = nil;
    [_backgroundLayer setValue:nil forKey:LibretroSkinImageKey];
  }
}

- (float)itemsOpacity {
  LibretroSkinRepresentation *representation = _representation;
  return (representation.translucent || representation.generated) ? (float)_opacity : 1.0f;
}

- (void)applyItems {
  NSMutableDictionary<NSString *, LibretroSkinItemLayers *> *previous = [NSMutableDictionary dictionary];
  for (LibretroSkinItemLayers *layers in _items) previous[layers.identifier] = layers;
  NSMutableArray<LibretroSkinItemLayers *> *items = [NSMutableArray array];
  for (LibretroLaidOutItem *laidOut in _layout.items) {
    LibretroSkinItem *item = laidOut.item;
    NSString *signature = LibretroSkinItemSignature(item);
    if (signature == nil || item.identifier.length == 0) continue;
    LibretroSkinItemLayers *layers = previous[item.identifier];
    if (layers != nil && [layers.signature isEqualToString:signature]) {
      [previous removeObjectForKey:item.identifier];
    } else {
      layers = [self createLayersForItem:item signature:signature];
    }
    layers.laidOut = laidOut;
    [self updateLayers:layers];
    [items addObject:layers];
  }
  for (LibretroSkinItemLayers *layers in previous.allValues) [layers.container removeFromSuperlayer];
  // Drawing order: panel, background, then the items in skin order.
  for (LibretroSkinItemLayers *layers in items) [self.layer addSublayer:layers.container];
  [_items setArray:items];
}

- (LibretroSkinItemLayers *)createLayersForItem:(LibretroSkinItem *)item signature:(NSString *)signature {
  CGFloat scale = _scale;
  LibretroSkinItemLayers *layers = [LibretroSkinItemLayers new];
  layers.identifier = item.identifier;
  layers.signature = signature;
  layers.container = [CALayer layer];
  layers.container.anchorPoint = CGPointZero;
  layers.container.frame = CGRectZero;
  if (LibretroSkinIsVector(item)) {
    layers.shape = LibretroSkinShapeLayer(scale);
    [layers.container addSublayer:layers.shape];
    if (item.shape == LibretroSkinItemShapeDPad) {
      layers.arrows = LibretroSkinShapeLayer(scale);
      [layers.container addSublayer:layers.arrows];
    }
    if (item.kind == LibretroSkinItemKindThumbstick) {
      layers.knob = LibretroSkinShapeLayer(scale);
      [layers.container addSublayer:layers.knob];
    }
    if (LibretroSkinHasLabel(item)) {
      CATextLayer *text = [CATextLayer layer];
      text.contentsScale = scale;
      text.alignmentMode = kCAAlignmentCenter;
      text.wrapped = NO;
      text.truncationMode = kCATruncationNone;
      layers.text = text;
      [layers.container addSublayer:text];
    }
    layers.highlightShape = LibretroSkinShapeLayer(scale);
    [layers.container addSublayer:layers.highlightShape];
  } else {
    if (item.assetPath.length > 0) {
      layers.image = LibretroSkinPlainLayer(scale);
      [layers.container addSublayer:layers.image];
      layers.highlightImage = [CALayer layer];
      layers.highlightMask = LibretroSkinPlainLayer(scale);
      layers.highlightImage.mask = layers.highlightMask;
      [layers.container addSublayer:layers.highlightImage];
    } else {
      // Control painted in the background image: a soft overlay only.
      layers.highlightShape = LibretroSkinShapeLayer(scale);
      [layers.container addSublayer:layers.highlightShape];
    }
    if (item.kind == LibretroSkinItemKindThumbstick && item.thumbstickAssetPath.length > 0) {
      layers.knobImage = LibretroSkinPlainLayer(scale);
      [layers.container addSublayer:layers.knobImage];
    }
  }
  layers.outline = LibretroSkinShapeLayer(scale);
  layers.outline.hidden = YES;
  [layers.container addSublayer:layers.outline];
  return layers;
}

- (void)updateLayers:(LibretroSkinItemLayers *)layers {
  LibretroLaidOutItem *laidOut = layers.laidOut;
  LibretroSkinItem *item = laidOut.item;
  CGRect frame = LibretroSkinCGRect(laidOut.frame);
  CGRect assetFrame = LibretroSkinCGRect(laidOut.assetFrame);
  if (CGRectIsEmpty(assetFrame)) assetFrame = frame;
  CGFloat scale = _scale;

  if (layers.shape != nil) {
    layers.shape.contentsScale = scale;
    layers.shape.frame = frame;
    CGPathRef path = LibretroSkinCreateShapePath(item.shape, frame.size);
    layers.shape.path = path;
    CGPathRelease(path);
    UIColor *fill = LibretroSkinColor(item.fillColor);
    layers.shape.fillColor = fill.CGColor;
  }
  if (layers.arrows != nil) {
    layers.arrows.contentsScale = scale;
    layers.arrows.frame = frame;
    CGPathRef path = LibretroSkinCreateArrowsPath(frame.size);
    layers.arrows.path = path;
    CGPathRelease(path);
    UIColor *color = item.labelColor != 0 ? LibretroSkinColor(item.labelColor) : [UIColor colorWithWhite:1 alpha:0.6];
    layers.arrows.fillColor = color.CGColor;
  }
  if (layers.knob != nil) {
    CGRect knob = LibretroSkinKnobRect(laidOut);
    layers.knob.contentsScale = scale;
    layers.knob.frame = knob;
    CGPathRef path = LibretroSkinCreateShapePath(LibretroSkinItemShapeCircle, knob.size);
    layers.knob.path = path;
    CGPathRelease(path);
    UIColor *fill = LibretroSkinLighterColor(item.fillColor, 0.3);
    layers.knob.fillColor = fill.CGColor;
  }
  if (layers.text != nil) {
    CGFloat size = LibretroSkinLabelFontSize(item.label, item.shape, frame.size);
    UIFont *font = [UIFont systemFontOfSize:MAX(size, 1) weight:UIFontWeightSemibold];
    CGFloat lineHeight = ceil(font.lineHeight);
    layers.text.contentsScale = scale;
    layers.text.string = item.label;
    layers.text.font = (__bridge CFTypeRef)font;
    layers.text.fontSize = font.pointSize;
    UIColor *color = item.labelColor != 0 ? LibretroSkinColor(item.labelColor) : UIColor.whiteColor;
    layers.text.foregroundColor = color.CGColor;
    layers.text.frame = CGRectMake(frame.origin.x, frame.origin.y + (frame.size.height - lineHeight) / 2,
                                   frame.size.width, lineHeight);
    layers.text.hidden = size <= 0;
  }
  if (layers.image != nil) {
    layers.image.frame = assetFrame;
    [self loadImageAtPath:item.assetPath
                   points:assetFrame.size
                    layer:layers.image
                     mask:layers.highlightMask
                    force:!_editing];
  }
  if (layers.knobImage != nil) {
    CGRect knob = LibretroSkinKnobRect(laidOut);
    layers.knobImage.frame = knob;
    [self loadImageAtPath:item.thumbstickAssetPath points:knob.size layer:layers.knobImage mask:nil force:!_editing];
  }
  if (layers.highlightShape != nil) {
    layers.highlightShape.contentsScale = scale;
    layers.highlightShape.frame = frame;
    CGPathRef path = LibretroSkinCreateShapePath(LibretroSkinIsVector(item) ? item.shape : LibretroSkinItemShapeNone,
                                                 frame.size);
    layers.highlightShape.path = path;
    CGPathRelease(path);
    UIColor *overlay = [UIColor colorWithWhite:1 alpha:LibretroSkinIsVector(item) ? 0.35 : 0.25];
    layers.highlightShape.fillColor = overlay.CGColor;
  }
  if (layers.highlightImage != nil) {
    layers.highlightImage.frame = assetFrame;
    UIColor *overlay = [UIColor colorWithWhite:1 alpha:0.4];
    layers.highlightImage.backgroundColor = overlay.CGColor;
    layers.highlightMask.frame = CGRectMake(0, 0, assetFrame.size.width, assetFrame.size.height);
  }
  CGRect outline = CGRectInset(frame, -3, -3);
  layers.outline.contentsScale = scale;
  layers.outline.frame = outline;
  CGMutablePathRef outlinePath = CGPathCreateMutable();
  LibretroSkinAddRoundedRect(outlinePath, CGRectMake(0, 0, outline.size.width, outline.size.height),
                             MIN(MIN(outline.size.width, outline.size.height) / 2, 14));
  layers.outline.path = outlinePath;
  CGPathRelease(outlinePath);
  [self applyStateToLayers:layers];
}

/// Visibility, opacity, pressed highlight and editing outline.
- (void)applyStateToLayers:(LibretroSkinItemLayers *)layers {
  LibretroSkinItem *item = layers.laidOut.item;
  // Editing shows every control, even with a physical controller.
  layers.container.hidden = _controlsHidden && !_editing;
  layers.container.opacity = [self itemsOpacity];
  BOOL pressed = !_editing && [_pressed containsObject:layers.identifier];
  layers.highlightShape.hidden = !pressed;
  layers.highlightImage.hidden = !pressed;
  BOOL movable = _editing && item.movable;
  layers.outline.hidden = !movable;
  if (movable) {
    BOOL selected = _selectedItem != nil && [_selectedItem isEqualToString:layers.identifier];
    UIColor *stroke = selected ? UIColor.systemYellowColor : [UIColor colorWithWhite:1 alpha:0.9];
    UIColor *fill = selected ? [UIColor colorWithWhite:1 alpha:0.14] : UIColor.clearColor;
    layers.outline.strokeColor = stroke.CGColor;
    layers.outline.fillColor = fill.CGColor;
    layers.outline.lineWidth = selected ? 2.5 : 1.5;
    layers.outline.lineDashPattern = selected ? nil : @[ @6, @4 ];
  }
}

- (void)setPressedItems:(NSSet<NSString *> *)itemIdentifiers {
  NSSet<NSString *> *pressed = [itemIdentifiers isKindOfClass:[NSSet class]] ? [itemIdentifiers copy] : [NSSet set];
  if ([pressed isEqualToSet:_pressed]) return;
  _pressed = pressed;
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  for (LibretroSkinItemLayers *layers in _items) {
    BOOL down = !_editing && [pressed containsObject:layers.identifier];
    layers.highlightShape.hidden = !down;
    layers.highlightImage.hidden = !down;
  }
  [CATransaction commit];
}

- (void)setEditing:(BOOL)editing selectedItem:(NSString *)itemIdentifier {
  BOOL finished = _editing && !editing;
  _editing = editing;
  _selectedItem = [itemIdentifier isKindOfClass:[NSString class]] ? [itemIdentifier copy] : nil;
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  for (LibretroSkinItemLayers *layers in _items) {
    if (finished) {
      // Images were only stretched while editing: rasterise them now at
      // their final size.
      [self updateLayers:layers];
    } else {
      [self applyStateToLayers:layers];
    }
  }
  [CATransaction commit];
}

#pragma mark - Images

/// Shows the image of `path` rasterised for `points` in `layer` (and in
/// `mask`). The previous contents stay until the new image is ready. With
/// `force` NO (editing), a layer that already shows an image keeps it,
/// stretched to its new frame.
- (void)loadImageAtPath:(NSString *)path
                 points:(CGSize)points
                  layer:(CALayer *)layer
                   mask:(CALayer *)mask
                  force:(BOOL)force {
  if (path.length == 0) {
    layer.contents = nil;
    mask.contents = nil;
    [layer setValue:nil forKey:LibretroSkinImageKey];
    return;
  }
  if (!force && layer.contents != nil) return;
  size_t width = 0, height = 0;
  if (!LibretroSkinPixelSize(points, _scale, &width, &height)) return;
  NSString *key = LibretroSkinCacheKey(path, width, height);
  NSString *current = [layer valueForKey:LibretroSkinImageKey];
  if ([current isKindOfClass:[NSString class]] && [current isEqualToString:key]) return;
  [layer setValue:key forKey:LibretroSkinImageKey];
  UIImage *cached = [LibretroSkinMemoryCache() objectForKey:key];
  if (cached != nil) {
    layer.contents = (__bridge id)cached.CGImage;
    mask.contents = (__bridge id)cached.CGImage;
    return;
  }
  NSString *cacheDirectory = _cacheDirectory;
  __weak CALayer *weakLayer = layer;
  __weak CALayer *weakMask = mask;
  dispatch_async(LibretroSkinQueue(), ^{
    UIImage *image = LibretroSkinLoadImage(path, width, height, key, cacheDirectory);
    dispatch_async(dispatch_get_main_queue(), ^{
      CALayer *target = weakLayer;
      if (target == nil || image == nil) return;
      NSString *expected = [target valueForKey:LibretroSkinImageKey];
      if (![expected isKindOfClass:[NSString class]] || ![expected isEqualToString:key]) return;
      [CATransaction begin];
      [CATransaction setDisableActions:YES];
      target.contents = (__bridge id)image.CGImage;
      weakMask.contents = (__bridge id)image.CGImage;
      [CATransaction commit];
    });
  });
}

+ (void)purgeCacheForSkinDirectory:(NSString *)directory cacheDirectory:(NSString *)cacheDirectory {
  // Keys are hashes: drop the whole memory cache, it refills on demand.
  [LibretroSkinMemoryCache() removeAllObjects];
  if (![directory isKindOfClass:[NSString class]] || directory.length == 0) return;
  NSString *folder = [cacheDirectory isKindOfClass:[NSString class]] ? LibretroSkinCacheFolder(cacheDirectory) : nil;
  if (folder == nil) return;
  NSString *root = directory.stringByStandardizingPath;
  NSString *prefix = [root hasSuffix:@"/"] ? root : [root stringByAppendingString:@"/"];
  dispatch_async(LibretroSkinQueue(), ^{
    NSFileManager *manager = [NSFileManager defaultManager];
    for (NSString *name in [manager contentsOfDirectoryAtPath:folder error:nil]) {
      if (![name.pathExtension isEqualToString:@"source"]) continue;
      NSString *sidecar = [folder stringByAppendingPathComponent:name];
      NSString *source = [NSString stringWithContentsOfFile:sidecar encoding:NSUTF8StringEncoding error:nil];
      if (source != nil && ![source hasPrefix:prefix] && ![source isEqualToString:root]) continue;
      [manager removeItemAtPath:sidecar error:nil];
      NSString *png = [sidecar.stringByDeletingPathExtension stringByAppendingPathExtension:@"png"];
      [manager removeItemAtPath:png error:nil];
    }
  });
}

#pragma mark - Previews

/// Draws one default-skin control (vector) into `context` (UIKit
/// coordinates). Skin queue.
static void LibretroSkinDrawVectorItem(CGContextRef context, LibretroLaidOutItem *laidOut) {
  LibretroSkinItem *item = laidOut.item;
  CGRect frame = LibretroSkinCGRect(laidOut.frame);
  if (CGRectIsEmpty(frame)) return;
  CGContextSaveGState(context);
  CGContextTranslateCTM(context, frame.origin.x, frame.origin.y);
  CGPathRef shape = LibretroSkinCreateShapePath(item.shape, frame.size);
  UIColor *fill = LibretroSkinColor(item.fillColor);
  CGContextSetFillColorWithColor(context, fill.CGColor);
  CGContextAddPath(context, shape);
  CGContextFillPath(context);
  CGPathRelease(shape);
  if (item.shape == LibretroSkinItemShapeDPad) {
    CGPathRef arrows = LibretroSkinCreateArrowsPath(frame.size);
    UIColor *color = item.labelColor != 0 ? LibretroSkinColor(item.labelColor) : [UIColor colorWithWhite:1 alpha:0.6];
    CGContextSetFillColorWithColor(context, color.CGColor);
    CGContextAddPath(context, arrows);
    CGContextFillPath(context);
    CGPathRelease(arrows);
  }
  CGContextRestoreGState(context);
  if (item.kind == LibretroSkinItemKindThumbstick) {
    CGRect knob = LibretroSkinKnobRect(laidOut);
    UIColor *color = LibretroSkinLighterColor(item.fillColor, 0.3);
    CGContextSetFillColorWithColor(context, color.CGColor);
    CGContextFillEllipseInRect(context, knob);
  }
  if (LibretroSkinHasLabel(item)) {
    CGFloat size = LibretroSkinLabelFontSize(item.label, item.shape, frame.size);
    if (size > 0) {
      UIFont *font = [UIFont systemFontOfSize:size weight:UIFontWeightSemibold];
      NSMutableParagraphStyle *paragraph = [[NSMutableParagraphStyle alloc] init];
      paragraph.alignment = NSTextAlignmentCenter;
      UIColor *color = item.labelColor != 0 ? LibretroSkinColor(item.labelColor) : UIColor.whiteColor;
      NSDictionary *attributes = @{
        NSFontAttributeName : font,
        NSForegroundColorAttributeName : color,
        NSParagraphStyleAttributeName : paragraph,
      };
      CGFloat lineHeight = ceil(font.lineHeight);
      CGRect textRect = CGRectMake(frame.origin.x, frame.origin.y + (frame.size.height - lineHeight) / 2,
                                   frame.size.width, lineHeight);
      [item.label drawInRect:textRect withAttributes:attributes];
    }
  }
}

+ (void)renderPreviewForRepresentation:(LibretroSkinRepresentation *)representation
                                  size:(CGSize)size
                                 scale:(CGFloat)scale
                            safeInsets:(UIEdgeInsets)safeInsets
                        cacheDirectory:(NSString *)cacheDirectory
                            completion:(void (^)(UIImage *_Nullable image))completion {
  void (^finish)(UIImage *) = [completion copy];
  if (finish == nil) return;
  if (representation == nil || !(size.width >= 1) || !(size.height >= 1) || !isfinite(size.width) ||
      !isfinite(size.height)) {
    dispatch_async(dispatch_get_main_queue(), ^{
      finish(nil);
    });
    return;
  }
  CGFloat pixelScale = scale > 0 && isfinite(scale) ? MIN(scale, 4) : 2;
  CGFloat longest = MAX(size.width, size.height);
  if (longest * pixelScale > LibretroSkinMaximumPixels) pixelScale = (CGFloat)LibretroSkinMaximumPixels / longest;
  NSString *cache = [cacheDirectory isKindOfClass:[NSString class]] ? [cacheDirectory copy] : @"";
  LibretroInsets insets = {safeInsets.top, safeInsets.left, safeInsets.bottom, safeInsets.right};
  dispatch_async(LibretroSkinQueue(), ^{
    UIImage *preview = nil;
    @autoreleasepool {
      LibretroSkinLayoutResult *layout = [LibretroSkinLayout layoutRepresentation:representation
                                                                         viewSize:(LibretroSize){size.width, size.height}
                                                                       safeInsets:insets
                                                                        overrides:nil];
      // Images first (cached), then one drawing pass.
      UIImage *background = nil;
      CGRect skinRect = LibretroSkinCGRect(layout.skinRect);
      size_t width = 0, height = 0;
      if (!representation.generated && representation.backgroundPath.length > 0 &&
          LibretroSkinPixelSize(skinRect.size, pixelScale, &width, &height)) {
        NSString *key = LibretroSkinCacheKey(representation.backgroundPath, width, height);
        background = LibretroSkinLoadImage(representation.backgroundPath, width, height, key, cache);
      }
      NSMutableDictionary<NSString *, UIImage *> *images = [NSMutableDictionary dictionary];
      NSMutableDictionary<NSString *, UIImage *> *knobs = [NSMutableDictionary dictionary];
      for (LibretroLaidOutItem *laidOut in layout.items) {
        LibretroSkinItem *item = laidOut.item;
        if (item.kind == LibretroSkinItemKindTouchScreen || LibretroSkinIsVector(item) || item.identifier.length == 0) {
          continue;
        }
        CGRect assetFrame = LibretroSkinCGRect(laidOut.assetFrame);
        if (CGRectIsEmpty(assetFrame)) assetFrame = LibretroSkinCGRect(laidOut.frame);
        if (item.assetPath.length > 0 && LibretroSkinPixelSize(assetFrame.size, pixelScale, &width, &height)) {
          NSString *key = LibretroSkinCacheKey(item.assetPath, width, height);
          UIImage *image = LibretroSkinLoadImage(item.assetPath, width, height, key, cache);
          if (image != nil) images[item.identifier] = image;
        }
        CGRect knob = LibretroSkinKnobRect(laidOut);
        if (item.kind == LibretroSkinItemKindThumbstick && item.thumbstickAssetPath.length > 0 &&
            LibretroSkinPixelSize(knob.size, pixelScale, &width, &height)) {
          NSString *key = LibretroSkinCacheKey(item.thumbstickAssetPath, width, height);
          UIImage *image = LibretroSkinLoadImage(item.thumbstickAssetPath, width, height, key, cache);
          if (image != nil) knobs[item.identifier] = image;
        }
      }

      // A plain bitmap context made the current UIKit context (thread-safe,
      // unlike renderer formats that consult the main screen), flipped to
      // UIKit coordinates in points.
      size_t pixelWidth = (size_t)ceil(size.width * pixelScale);
      size_t pixelHeight = (size_t)ceil(size.height * pixelScale);
      CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
      CGContextRef context =
          CGBitmapContextCreate(NULL, pixelWidth, pixelHeight, 8, 0, space,
                                (CGBitmapInfo)kCGImageAlphaNoneSkipFirst | (CGBitmapInfo)kCGBitmapByteOrder32Little);
      CGColorSpaceRelease(space);
      if (context != NULL) {
        CGContextTranslateCTM(context, 0, (CGFloat)pixelHeight);
        CGContextScaleCTM(context, pixelScale, -pixelScale);
        UIGraphicsPushContext(context);
        CGContextSetRGBFillColor(context, 0, 0, 0, 1);
        CGContextFillRect(context, CGRectMake(0, 0, size.width, size.height));
        // Grey placeholders where the game picture goes (below the skin,
        // whose screen areas are transparent).
        CGContextSetRGBFillColor(context, 0.30, 0.30, 0.32, 1);
        for (LibretroLaidOutScreen *screen in layout.screens) {
          CGRect container = LibretroSkinCGRect(screen.container);
          if (!CGRectIsEmpty(container)) CGContextFillRect(context, container);
        }
        CGRect panel = LibretroSkinCGRect(layout.panelFrame);
        if (representation.panelColor != 0 && !CGRectIsEmpty(panel)) {
          UIColor *color = LibretroSkinColor(representation.panelColor);
          CGContextSetFillColorWithColor(context, color.CGColor);
          CGContextFillRect(context, panel);
        }
        if (background != nil && !CGRectIsEmpty(skinRect)) [background drawInRect:skinRect];
        for (LibretroLaidOutItem *laidOut in layout.items) {
          LibretroSkinItem *item = laidOut.item;
          if (item.kind == LibretroSkinItemKindTouchScreen) continue;
          if (LibretroSkinIsVector(item)) {
            LibretroSkinDrawVectorItem(context, laidOut);
            continue;
          }
          UIImage *image = item.identifier.length > 0 ? images[item.identifier] : nil;
          if (image != nil) {
            CGRect assetFrame = LibretroSkinCGRect(laidOut.assetFrame);
            if (CGRectIsEmpty(assetFrame)) assetFrame = LibretroSkinCGRect(laidOut.frame);
            [image drawInRect:assetFrame];
          }
          UIImage *knob = item.identifier.length > 0 ? knobs[item.identifier] : nil;
          if (knob != nil) [knob drawInRect:LibretroSkinKnobRect(laidOut)];
        }
        UIGraphicsPopContext();
        CGImageRef rendered = CGBitmapContextCreateImage(context);
        CGContextRelease(context);
        if (rendered != NULL) {
          preview = [UIImage imageWithCGImage:rendered scale:pixelScale orientation:UIImageOrientationUp];
          CGImageRelease(rendered);
        }
      }
    }
    dispatch_async(dispatch_get_main_queue(), ^{
      finish(preview);
    });
  });
}

@end
