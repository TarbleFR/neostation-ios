#import "LibretroSkinLayout.h"

#include <math.h>
#include <string.h>

/// A user layout change in view points.
typedef struct {
  double dx;
  double dy;
  double scale;
} LayoutOverride;

static const double LayoutMinimumScale = 0.5;
static const double LayoutMaximumScale = 2.0;
static const double LayoutEpsilon = 0.001;

@implementation LibretroLaidOutItem

- (instancetype)init {
  self = [super init];
  if (self) {
    _item = [LibretroSkinItem new];
  }
  return self;
}

@end

@implementation LibretroLaidOutScreen

- (instancetype)init {
  self = [super init];
  if (self) {
    _source = LibretroRectMake(0, 0, 1, 1);
    _role = @"full";
  }
  return self;
}

@end

@implementation LibretroSkinLayoutResult

- (instancetype)init {
  self = [super init];
  if (self) {
    _items = @[];
    _screens = @[];
  }
  return self;
}

@end

static double LayoutPositive(double value) {
  return isfinite(value) && value > 1 ? value : 1;
}

static double LayoutInset(double value) {
  return isfinite(value) && value > 0 ? value : 0;
}

static BOOL LayoutOverlaps(LibretroRect a, LibretroRect b) {
  double width = MIN(a.x + a.w, b.x + b.w) - MAX(a.x, b.x);
  double height = MIN(a.y + a.h, b.y + b.h) - MAX(a.y, b.y);
  return width > LayoutEpsilon && height > LayoutEpsilon;
}

static BOOL LayoutContains(LibretroRect rect, double x, double y) {
  return x >= rect.x && y >= rect.y && x <= rect.x + rect.w && y <= rect.y + rect.h;
}

/// `normalized` (0-1) inside `area`.
static LibretroRect LayoutDenormalized(LibretroRect normalized, LibretroRect area) {
  return LibretroRectMake(area.x + normalized.x * area.w, area.y + normalized.y * area.h, normalized.w * area.w,
                          normalized.h * area.h);
}

/// Layout without the user's overrides.
static LibretroSkinLayoutResult *LayoutBase(LibretroSkinRepresentation *representation, LibretroSize viewSize,
                                            LibretroInsets safeInsets) {
  double width = LayoutPositive(viewSize.w), height = LayoutPositive(viewSize.h);
  LibretroRect view = LibretroRectMake(0, 0, width, height);
  LibretroSize mapping = representation.mappingSize;
  if (!(mapping.w > 0) || !(mapping.h > 0) || !isfinite(mapping.w) || !isfinite(mapping.h)) {
    mapping.w = width;
    mapping.h = height;
  }
  double top = LayoutInset(safeInsets.top), left = LayoutInset(safeInsets.left);
  double bottom = LayoutInset(safeInsets.bottom), right = LayoutInset(safeInsets.right);
  LibretroRect safeArea = LibretroRectMake(left, top, MAX(width - left - right, 1), MAX(height - top - bottom, 1));

  LibretroRect skinRect;
  LibretroRect gameArea;
  if (representation.generated) {
    // Default skins are generated for this view: mapping == view.
    skinRect = view;
    gameArea = safeArea;
  } else {
    BOOL controllerScreen = NO;
    for (LibretroSkinScreen *screen in representation.screens) {
      if (screen.hasOutputFrame && !screen.appPlacement) controllerScreen = YES;
    }
    double pinnedHeight = width * mapping.h / mapping.w;
    if (representation.orientation == LibretroSkinOrientationPortrait && !controllerScreen && pinnedHeight <= height) {
      // Delta portrait: controller pinned to the bottom at full width, the
      // game above it (below the safe area top).
      skinRect = LibretroRectMake(0, height - pinnedHeight, width, pinnedHeight);
      double gameTop = MIN(top, skinRect.y);
      gameArea = LibretroRectMake(0, gameTop, width, skinRect.y - gameTop);
      if (gameArea.h < 1) gameArea = LibretroRectMake(0, 0, width, MAX(skinRect.y, 1));
    } else {
      // Delta: aspect fit in the full bounds, safe areas ignored.
      skinRect = LibretroRectAspectFit(view, mapping.w / mapping.h);
      gameArea = view;
    }
  }

  NSMutableArray<LibretroLaidOutItem *> *items = [NSMutableArray array];
  for (LibretroSkinItem *item in representation.items) {
    LibretroLaidOutItem *laidOut = [LibretroLaidOutItem new];
    laidOut.item = item;
    laidOut.frame = LibretroRectScale(item.frame, mapping, skinRect);
    laidOut.hitFrame = LibretroRectScale(item.hitFrame, mapping, skinRect);
    laidOut.assetFrame = LibretroRectScale(item.assetFrame, mapping, skinRect);
    [items addObject:laidOut];
  }

  NSMutableArray<LibretroLaidOutScreen *> *screens = [NSMutableArray array];
  for (LibretroSkinScreen *screen in representation.screens) {
    LibretroLaidOutScreen *laidOut = [LibretroLaidOutScreen new];
    if (!screen.hasOutputFrame) {
      laidOut.container = gameArea;
    } else if (screen.appPlacement) {
      laidOut.container = LayoutDenormalized(screen.outputFrame, gameArea);
    } else {
      laidOut.container = LibretroRectScale(screen.outputFrame, mapping, skinRect);
    }
    laidOut.source = screen.source;
    laidOut.role = screen.role;
    laidOut.touchScreen = screen.touchScreen;
    [screens addObject:laidOut];
  }
  if (screens.count == 0) {
    LibretroLaidOutScreen *laidOut = [LibretroLaidOutScreen new];
    laidOut.container = gameArea;
    [screens addObject:laidOut];
  }

  LibretroSkinLayoutResult *result = [LibretroSkinLayoutResult new];
  result.skinRect = skinRect;
  result.items = items;
  result.screens = screens;
  LibretroRect panel = representation.panelFrame;
  if (representation.panelColor != 0 && panel.w > 0 && panel.h > 0) {
    result.panelFrame = LibretroRectScale(panel, mapping, skinRect);
  }
  return result;
}

static LayoutOverride LayoutOverrideFromDictionary(NSDictionary *dictionary, LibretroSize view) {
  LayoutOverride override = {0, 0, 1};
  if (![dictionary isKindOfClass:[NSDictionary class]]) return override;
  id dx = dictionary[@"dx"], dy = dictionary[@"dy"], scale = dictionary[@"scale"];
  if ([dx isKindOfClass:[NSNumber class]] && isfinite([(NSNumber *)dx doubleValue])) {
    override.dx = [(NSNumber *)dx doubleValue] * view.w;
  }
  if ([dy isKindOfClass:[NSNumber class]] && isfinite([(NSNumber *)dy doubleValue])) {
    override.dy = [(NSNumber *)dy doubleValue] * view.h;
  }
  if ([scale isKindOfClass:[NSNumber class]] && isfinite([(NSNumber *)scale doubleValue])) {
    override.scale = MIN(MAX([(NSNumber *)scale doubleValue], LayoutMinimumScale), LayoutMaximumScale);
  }
  return override;
}

/// `rect` scaled around (`centerX`, `centerY`) and moved by the override.
static LibretroRect LayoutTransformed(LibretroRect rect, double centerX, double centerY, LayoutOverride override) {
  return LibretroRectMake(centerX + (rect.x - centerX) * override.scale + override.dx,
                          centerY + (rect.y - centerY) * override.scale + override.dy, rect.w * override.scale,
                          rect.h * override.scale);
}

/// First touch-screen container or touch-screen item `rect` intersects.
static BOOL LayoutTouchObstacle(LibretroSkinLayoutResult *layout, LibretroRect rect, LibretroRect *obstacle) {
  for (LibretroLaidOutScreen *screen in layout.screens) {
    if (screen.touchScreen && LayoutOverlaps(rect, screen.container)) {
      *obstacle = screen.container;
      return YES;
    }
  }
  for (LibretroLaidOutItem *laidOut in layout.items) {
    if (laidOut.item.kind == LibretroSkinItemKindTouchScreen && LayoutOverlaps(rect, laidOut.frame)) {
      *obstacle = laidOut.frame;
      return YES;
    }
  }
  return NO;
}

static BOOL LayoutInsideView(LibretroRect rect, LibretroSize view) {
  return rect.x >= -LayoutEpsilon && rect.y >= -LayoutEpsilon && rect.x + rect.w <= view.w + LayoutEpsilon &&
         rect.y + rect.h <= view.h + LayoutEpsilon;
}

/// Room a control takes: its frame and its touch area (hit frame); the
/// frame alone when the hit frame is empty.
static LibretroRect LayoutFootprint(LibretroRect frame, LibretroRect hitFrame) {
  if (!(hitFrame.w > 0) || !(hitFrame.h > 0)) return frame;
  double left = MIN(frame.x, hitFrame.x), top = MIN(frame.y, hitFrame.y);
  double right = MAX(frame.x + frame.w, hitFrame.x + hitFrame.w);
  double bottom = MAX(frame.y + frame.h, hitFrame.y + hitFrame.h);
  return LibretroRectMake(left, top, right - left, bottom - top);
}

/// Places the moved item: the frame inside the view, and its footprint
/// (frame and hit frame, moved together around the frame centre) off every
/// touch screen. When the skin itself already lets the item's touch area
/// reach a touch screen (imported skins with large extended edges), only
/// the frame is kept off it, as before any move; +itemsAtX: then gives the
/// touch screen priority outside the frame. Returns NO when no position
/// works (`override` is then left unchanged).
static BOOL LayoutFit(LibretroSkinLayoutResult *layout, LibretroLaidOutItem *laidOut, LayoutOverride *override,
                      LibretroSize view) {
  LibretroRect base = laidOut.frame;
  if (!(base.w > 0) || !(base.h > 0)) return NO;
  LibretroRect obstacle = {0, 0, 0, 0};
  BOOL withHit = !LayoutTouchObstacle(layout, LayoutFootprint(base, laidOut.hitFrame), &obstacle);
  LayoutOverride value = *override;
  double fit = MIN(view.w / base.w, view.h / base.h);
  if (value.scale > fit) value.scale = fit;
  double centerX = base.x + base.w / 2, centerY = base.y + base.h / 2;
  LibretroRect moved = LayoutTransformed(base, centerX, centerY, value);
  if (moved.x < 0) {
    value.dx -= moved.x;
  } else if (moved.x + moved.w > view.w) {
    value.dx -= moved.x + moved.w - view.w;
  }
  if (moved.y < 0) {
    value.dy -= moved.y;
  } else if (moved.y + moved.h > view.h) {
    value.dy -= moved.y + moved.h - view.h;
  }
  for (int attempt = 0; attempt <= 8; attempt++) {
    moved = LayoutTransformed(base, centerX, centerY, value);
    LibretroRect area =
        withHit ? LayoutFootprint(moved, LayoutTransformed(laidOut.hitFrame, centerX, centerY, value)) : moved;
    if (!LayoutTouchObstacle(layout, area, &obstacle)) {
      if (!LayoutInsideView(moved, view)) return NO;
      *override = value;
      return YES;
    }
    if (attempt == 8) break;
    // Smallest move that clears the obstacle and keeps the frame in the view.
    double shifts[4][2] = {
        {obstacle.x - (area.x + area.w), 0},
        {obstacle.x + obstacle.w - area.x, 0},
        {0, obstacle.y - (area.y + area.h)},
        {0, obstacle.y + obstacle.h - area.y},
    };
    int best = -1;
    double bestDistance = INFINITY;
    for (int index = 0; index < 4; index++) {
      LibretroRect candidate = moved;
      candidate.x += shifts[index][0];
      candidate.y += shifts[index][1];
      double distance = fabs(shifts[index][0]) + fabs(shifts[index][1]);
      if (LayoutInsideView(candidate, view) && distance < bestDistance) {
        best = index;
        bestDistance = distance;
      }
    }
    if (best < 0) break;
    value.dx += shifts[best][0];
    value.dy += shifts[best][1];
  }
  return NO;
}

/// `override` placed by LayoutFit; else `fallback` (when given and it still
/// fits); else the original place. `fitted`: whether `override` was placed.
static LayoutOverride LayoutClamped(LibretroSkinLayoutResult *layout, LibretroLaidOutItem *laidOut,
                                    LayoutOverride override, const LayoutOverride *fallback, LibretroSize view,
                                    BOOL *fitted) {
  LayoutOverride value = override;
  BOOL placed = LayoutFit(layout, laidOut, &value, view);
  if (fitted != NULL) *fitted = placed;
  if (placed) return value;
  if (fallback != NULL) {
    value = *fallback;
    if (LayoutFit(layout, laidOut, &value, view)) return value;
  }
  LayoutOverride original = {0, 0, 1};
  return original;
}

static LibretroSize LayoutViewSize(LibretroSize viewSize) {
  LibretroSize size = {LayoutPositive(viewSize.w), LayoutPositive(viewSize.h)};
  return size;
}

@implementation LibretroSkinLayout

+ (LibretroSkinLayoutResult *)layoutRepresentation:(LibretroSkinRepresentation *)representation
                                          viewSize:(LibretroSize)viewSize
                                        safeInsets:(LibretroInsets)safeInsets
                                         overrides:(NSDictionary<NSString *, NSDictionary *> *)overrides {
  LibretroSize view = LayoutViewSize(viewSize);
  LibretroSkinLayoutResult *result = LayoutBase(representation, view, safeInsets);
  if (overrides.count == 0) return result;
  for (LibretroLaidOutItem *laidOut in result.items) {
    if (!laidOut.item.movable) continue;
    NSDictionary *dictionary = overrides[laidOut.item.identifier];
    if (![dictionary isKindOfClass:[NSDictionary class]]) continue;
    LayoutOverride override =
        LayoutClamped(result, laidOut, LayoutOverrideFromDictionary(dictionary, view), NULL, view, NULL);
    // Frame, hit frame and image move together around the frame centre.
    LibretroRect frame = laidOut.frame;
    double centerX = frame.x + frame.w / 2, centerY = frame.y + frame.h / 2;
    laidOut.frame = LayoutTransformed(frame, centerX, centerY, override);
    laidOut.hitFrame = LayoutTransformed(laidOut.hitFrame, centerX, centerY, override);
    laidOut.assetFrame = LayoutTransformed(laidOut.assetFrame, centerX, centerY, override);
  }
  return result;
}

+ (NSDictionary<NSString *, NSNumber *> *)clampOverride:(NSDictionary<NSString *, NSNumber *> *)override
                                                forItem:(LibretroSkinItem *)item
                                         representation:(LibretroSkinRepresentation *)representation
                                               viewSize:(LibretroSize)viewSize
                                             safeInsets:(LibretroInsets)safeInsets {
  return [self clampOverride:override
                    previous:nil
                     forItem:item
              representation:representation
                    viewSize:viewSize
                  safeInsets:safeInsets
                      fitted:NULL];
}

+ (NSDictionary<NSString *, NSNumber *> *)clampOverride:(NSDictionary<NSString *, NSNumber *> *)override
                                               previous:(NSDictionary<NSString *, NSNumber *> *)previous
                                                forItem:(LibretroSkinItem *)item
                                         representation:(LibretroSkinRepresentation *)representation
                                               viewSize:(LibretroSize)viewSize
                                             safeInsets:(LibretroInsets)safeInsets
                                                 fitted:(BOOL *)fitted {
  if (fitted != NULL) *fitted = NO;
  LibretroSize view = LayoutViewSize(viewSize);
  LibretroSkinLayoutResult *layout = LayoutBase(representation, view, safeInsets);
  LibretroLaidOutItem *target = nil;
  for (LibretroLaidOutItem *laidOut in layout.items) {
    if ([laidOut.item.identifier isEqualToString:item.identifier]) {
      target = laidOut;
      break;
    }
  }
  if (target == nil || !target.item.movable) return @{@"dx" : @0, @"dy" : @0, @"scale" : @1};
  LayoutOverride fallback = LayoutOverrideFromDictionary(previous, view);
  BOOL hasFallback = [previous isKindOfClass:[NSDictionary class]];
  LayoutOverride clamped = LayoutClamped(layout, target, LayoutOverrideFromDictionary(override, view),
                                         hasFallback ? &fallback : NULL, view, fitted);
  return @{@"dx" : @(clamped.dx / view.w), @"dy" : @(clamped.dy / view.h), @"scale" : @(clamped.scale)};
}

/// The layout's touch-screen containers (NSValue of LibretroRect).
static NSArray<NSValue *> *LayoutTouchAreas(LibretroSkinLayoutResult *layout) {
  NSMutableArray<NSValue *> *areas = [NSMutableArray array];
  for (LibretroLaidOutScreen *screen in layout.screens) {
    if (!screen.touchScreen) continue;
    LibretroRect container = screen.container;
    [areas addObject:[NSValue valueWithBytes:&container objCType:@encode(LibretroRect)]];
  }
  return areas;
}

/// Whether (x, y) is on a drawn touch screen: one of `areas`, or the frame
/// of a touch-screen item.
static BOOL LayoutOnTouchScreen(LibretroSkinLayoutResult *layout, NSArray<NSValue *> *areas, double x, double y) {
  for (id value in areas) {
    if (![value isKindOfClass:[NSValue class]]) continue;
    NSUInteger size = 0;
    NSGetSizeAndAlignment([(NSValue *)value objCType], &size, NULL);
    if (size != sizeof(LibretroRect)) continue;
    LibretroRect area = {0, 0, 0, 0};
    [(NSValue *)value getValue:&area size:sizeof(area)];
    if (area.w > 0 && area.h > 0 && LayoutContains(area, x, y)) return YES;
  }
  for (LibretroLaidOutItem *laidOut in layout.items) {
    LibretroRect frame = laidOut.frame;
    if (laidOut.item.kind == LibretroSkinItemKindTouchScreen && frame.w > 0 && frame.h > 0 &&
        LayoutContains(frame, x, y)) {
      return YES;
    }
  }
  return NO;
}

+ (NSArray<LibretroLaidOutItem *> *)itemsAtX:(double)x y:(double)y inLayout:(LibretroSkinLayoutResult *)layout {
  return [self itemsAtX:x y:y inLayout:layout touchAreas:nil];
}

+ (NSArray<LibretroLaidOutItem *> *)itemsAtX:(double)x
                                           y:(double)y
                                    inLayout:(LibretroSkinLayoutResult *)layout
                                  touchAreas:(NSArray<NSValue *> *)touchAreas {
  // On a drawn touch screen a control answers only inside its visible
  // frame: its extended edges never take a touch from the touch screen.
  BOOL onTouchScreen = LayoutOnTouchScreen(layout, touchAreas ?: LayoutTouchAreas(layout), x, y);
  // A thumbstick under the finger wins alone (the nearest one).
  LibretroLaidOutItem *stick = nil;
  double stickDistance = INFINITY;
  for (LibretroLaidOutItem *laidOut in layout.items) {
    if (laidOut.item.kind != LibretroSkinItemKindThumbstick ||
        !LayoutContains(onTouchScreen ? laidOut.frame : laidOut.hitFrame, x, y)) {
      continue;
    }
    double dx = x - (laidOut.frame.x + laidOut.frame.w / 2), dy = y - (laidOut.frame.y + laidOut.frame.h / 2);
    double distance = dx * dx + dy * dy;
    if (distance < stickDistance) {
      stick = laidOut;
      stickDistance = distance;
    }
  }
  if (stick != nil) return @[ stick ];

  NSMutableArray<LibretroLaidOutItem *> *hits = [NSMutableArray array];
  LibretroLaidOutItem *menu = nil;
  for (LibretroLaidOutItem *laidOut in layout.items) {
    if (laidOut.item.kind == LibretroSkinItemKindTouchScreen ||
        !LayoutContains(onTouchScreen ? laidOut.frame : laidOut.hitFrame, x, y)) {
      continue;
    }
    [hits addObject:laidOut];
    if (menu == nil && [laidOut.item.inputs containsObject:@"menu"]) menu = laidOut;
  }
  // "menu" is exclusive (Delta).
  if (menu != nil) return @[ menu ];
  if (hits.count > 0) return hits;

  NSMutableArray<LibretroLaidOutItem *> *touches = [NSMutableArray array];
  for (LibretroLaidOutItem *laidOut in layout.items) {
    if (laidOut.item.kind == LibretroSkinItemKindTouchScreen && LayoutContains(laidOut.hitFrame, x, y)) {
      [touches addObject:laidOut];
    }
  }
  return touches;
}

+ (LibretroRect)knobFrameForItem:(LibretroLaidOutItem *)laidOut stickX:(double)x stickY:(double)y {
  LibretroRect frame = laidOut.frame;
  LibretroSkinItem *item = laidOut.item;
  double factor = item.frame.w > 0 && isfinite(item.frame.w) ? frame.w / item.frame.w : 1;
  double width = item.thumbstickSize.w * factor, height = item.thumbstickSize.h * factor;
  if (!(width > 0) || !(height > 0) || !isfinite(width) || !isfinite(height)) {
    width = frame.w * 0.5;
    height = frame.h * 0.5;
  }
  double vectorX = isfinite(x) ? MIN(MAX(x, -1.0), 1.0) : 0;
  double vectorY = isfinite(y) ? MIN(MAX(y, -1.0), 1.0) : 0;
  double travelX = frame.w - width > LayoutEpsilon ? (frame.w - width) / 2 : frame.w / 4;
  double travelY = frame.h - height > LayoutEpsilon ? (frame.h - height) / 2 : frame.h / 4;
  double centerX = frame.x + frame.w / 2 + vectorX * travelX;
  double centerY = frame.y + frame.h / 2 + vectorY * travelY;
  return LibretroRectMake(centerX - width / 2, centerY - height / 2, width, height);
}

+ (BOOL)resolvePointerMapping:(LibretroScreenMapping)current
                         atX:(double)x
                           y:(double)y
                    mappings:(NSArray<NSValue *> *)mappings
                      result:(LibretroScreenMapping *)result {
  BOOL found = NO;
  LibretroScreenMapping containing;
  memset(&containing, 0, sizeof(containing));
  for (id value in mappings) {
    if (![value isKindOfClass:[NSValue class]]) continue;
    NSUInteger size = 0;
    NSGetSizeAndAlignment([(NSValue *)value objCType], &size, NULL);
    if (size != sizeof(LibretroScreenMapping)) continue;
    LibretroScreenMapping mapping;
    memset(&mapping, 0, sizeof(mapping));
    [(NSValue *)value getValue:&mapping size:sizeof(mapping)];
    if (mapping.rotation == current.rotation && LibretroRectEqualToRect(mapping.output, current.output, 1e-6) &&
        LibretroRectEqualToRect(mapping.source, current.source, 1e-9)) {
      // Still drawn at the same place: the finger keeps its mapping.
      if (result != NULL) *result = current;
      return YES;
    }
    if (!found && mapping.output.w > 0 && mapping.output.h > 0 && LayoutContains(mapping.output, x, y)) {
      containing = mapping;
      found = YES;
    }
  }
  if (found && result != NULL) *result = containing;
  return found;
}

@end
