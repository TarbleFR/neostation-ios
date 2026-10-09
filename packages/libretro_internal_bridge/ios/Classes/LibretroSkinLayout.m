#import "LibretroSkinLayout.h"

#include <math.h>

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

/// Keeps the moved item inside the view and off every touch screen; falls
/// back to the original place when no position works.
static LayoutOverride LayoutClamped(LibretroSkinLayoutResult *layout, LibretroLaidOutItem *laidOut,
                                    LayoutOverride override, LibretroSize view) {
  LayoutOverride original = {0, 0, 1};
  LibretroRect base = laidOut.frame;
  if (!(base.w > 0) || !(base.h > 0)) return original;
  double fit = MIN(view.w / base.w, view.h / base.h);
  if (override.scale > fit) override.scale = fit;
  double centerX = base.x + base.w / 2, centerY = base.y + base.h / 2;
  LibretroRect moved = LayoutTransformed(base, centerX, centerY, override);
  if (moved.x < 0) {
    override.dx -= moved.x;
  } else if (moved.x + moved.w > view.w) {
    override.dx -= moved.x + moved.w - view.w;
  }
  if (moved.y < 0) {
    override.dy -= moved.y;
  } else if (moved.y + moved.h > view.h) {
    override.dy -= moved.y + moved.h - view.h;
  }
  for (int attempt = 0; attempt < 8; attempt++) {
    moved = LayoutTransformed(base, centerX, centerY, override);
    LibretroRect obstacle = {0, 0, 0, 0};
    if (!LayoutTouchObstacle(layout, moved, &obstacle)) return override;
    // Smallest move that clears the obstacle and stays in the view.
    double shifts[4][2] = {
        {obstacle.x - (moved.x + moved.w), 0},
        {obstacle.x + obstacle.w - moved.x, 0},
        {0, obstacle.y - (moved.y + moved.h)},
        {0, obstacle.y + obstacle.h - moved.y},
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
    override.dx += shifts[best][0];
    override.dy += shifts[best][1];
  }
  moved = LayoutTransformed(base, centerX, centerY, override);
  LibretroRect obstacle = {0, 0, 0, 0};
  if (!LayoutTouchObstacle(layout, moved, &obstacle) && LayoutInsideView(moved, view)) return override;
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
    LayoutOverride override = LayoutClamped(result, laidOut, LayoutOverrideFromDictionary(dictionary, view), view);
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
  LayoutOverride clamped = LayoutClamped(layout, target, LayoutOverrideFromDictionary(override, view), view);
  return @{@"dx" : @(clamped.dx / view.w), @"dy" : @(clamped.dy / view.h), @"scale" : @(clamped.scale)};
}

+ (NSArray<LibretroLaidOutItem *> *)itemsAtX:(double)x y:(double)y inLayout:(LibretroSkinLayoutResult *)layout {
  // A thumbstick under the finger wins alone (the nearest one).
  LibretroLaidOutItem *stick = nil;
  double stickDistance = INFINITY;
  for (LibretroLaidOutItem *laidOut in layout.items) {
    if (laidOut.item.kind != LibretroSkinItemKindThumbstick || !LayoutContains(laidOut.hitFrame, x, y)) continue;
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
    if (laidOut.item.kind == LibretroSkinItemKindTouchScreen || !LayoutContains(laidOut.hitFrame, x, y)) continue;
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

@end
