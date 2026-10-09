#import "LibretroChromeLayout.h"

#include <math.h>

const LibretroSize LibretroMenuButtonSize = {44, 40};
const double LibretroMenuButtonClearance = 6;

/// Distance from the left and right sides of the safe area.
static const double kSideMargin = 10;
/// Distance from the top and the bottom of the safe area.
static const double kTopMargin = 6;
/// A vertical move costs this many times a horizontal one.
static const double kVerticalWeight = 3;
/// Overlaps thinner than this are rounding, not overlaps.
static const double kTolerance = 0.01;

static double FiniteOrZero(double value) {
  return isfinite(value) ? value : 0;
}

static void AppendObstacle(NSMutableData *obstacles, LibretroRect rect) {
  if (!isfinite(rect.x) || !isfinite(rect.y) || !isfinite(rect.w) || !isfinite(rect.h)) return;
  if (rect.w <= 0 || rect.h <= 0) return;
  [obstacles appendBytes:&rect length:sizeof(rect)];
}

/// YES when no obstacle comes closer to `frame` than the clearance. A frame
/// starting at x is too close to an obstacle spanning [x1, x2] exactly when
/// x lies in (x1 - width - clearance, x2 + clearance), same vertically.
static BOOL IsFree(LibretroRect frame, const LibretroRect *obstacles, NSUInteger count) {
  for (NSUInteger index = 0; index < count; index++) {
    LibretroRect obstacle = obstacles[index];
    double width = MIN(frame.x + frame.w, obstacle.x + obstacle.w) - MAX(frame.x, obstacle.x) + LibretroMenuButtonClearance;
    double height =
        MIN(frame.y + frame.h, obstacle.y + obstacle.h) - MAX(frame.y, obstacle.y) + LibretroMenuButtonClearance;
    if (width > kTolerance && height > kTolerance) return NO;
  }
  return YES;
}

static BOOL IsBetter(double cost, LibretroRect candidate, double bestCost, LibretroRect best) {
  if (cost < bestCost - 1e-9) return YES;
  if (cost > bestCost + 1e-9) return NO;
  if (candidate.y < best.y - 1e-9) return YES;
  if (candidate.y > best.y + 1e-9) return NO;
  return candidate.x > best.x + 1e-9;
}

/// Free frame of the preferred size closest to `preferred` inside the safe
/// area. Only frames starting on a candidate line are tried: the preferred
/// corner, the limits of the safe area and the lines where a frame starts
/// touching an obstacle's clearance. Free frames form boxes bounded by these
/// lines, and the point of a box closest to the preferred corner is either
/// that corner or on the box's border, so the closest free frame is among
/// the candidates.
static BOOL ClosestFreeFrame(LibretroRect preferred, NSData *obstacles, LibretroSize viewSize, LibretroInsets insets,
                             LibretroRect *result) {
  double width = FiniteOrZero(viewSize.w), height = FiniteOrZero(viewSize.h);
  double minX = FiniteOrZero(insets.left) + kSideMargin;
  double maxX = width - FiniteOrZero(insets.right) - preferred.w - kSideMargin;
  double minY = FiniteOrZero(insets.top) + kTopMargin;
  double maxY = height - FiniteOrZero(insets.bottom) - preferred.h - kTopMargin;
  if (maxX < minX || maxY < minY) return NO;
  NSUInteger count = obstacles.length / sizeof(LibretroRect);
  const LibretroRect *rects = (const LibretroRect *)obstacles.bytes;

  NSMutableData *xData = [NSMutableData dataWithLength:(3 + 2 * count) * sizeof(double)];
  NSMutableData *yData = [NSMutableData dataWithLength:(3 + 2 * count) * sizeof(double)];
  double *xs = (double *)xData.mutableBytes;
  double *ys = (double *)yData.mutableBytes;
  NSUInteger lines = 0;
  xs[lines] = preferred.x;
  ys[lines++] = preferred.y;
  xs[lines] = minX;
  ys[lines++] = minY;
  xs[lines] = maxX;
  ys[lines++] = maxY;
  for (NSUInteger index = 0; index < count; index++) {
    LibretroRect obstacle = rects[index];
    xs[lines] = obstacle.x - LibretroMenuButtonClearance - preferred.w;
    ys[lines++] = obstacle.y - LibretroMenuButtonClearance - preferred.h;
    xs[lines] = obstacle.x + obstacle.w + LibretroMenuButtonClearance;
    ys[lines++] = obstacle.y + obstacle.h + LibretroMenuButtonClearance;
  }

  BOOL found = NO;
  double bestCost = INFINITY;
  LibretroRect best = preferred;
  for (NSUInteger column = 0; column < lines; column++) {
    double x = xs[column];
    if (!isfinite(x) || x < minX - 1e-9 || x > maxX + 1e-9) continue;
    for (NSUInteger row = 0; row < lines; row++) {
      double y = ys[row];
      if (!isfinite(y) || y < minY - 1e-9 || y > maxY + 1e-9) continue;
      LibretroRect candidate = LibretroRectMake(x, y, preferred.w, preferred.h);
      double cost = fabs(x - preferred.x) + kVerticalWeight * fabs(y - preferred.y);
      if (found && !IsBetter(cost, candidate, bestCost, best)) continue;
      if (!IsFree(candidate, rects, count)) continue;
      found = YES;
      bestCost = cost;
      best = candidate;
    }
  }
  if (found && result != NULL) *result = best;
  return found;
}

@implementation LibretroChromeLayout

+ (LibretroRect)preferredMenuButtonFrameForViewSize:(LibretroSize)viewSize safeInsets:(LibretroInsets)safeInsets {
  double width = FiniteOrZero(viewSize.w), height = FiniteOrZero(viewSize.h);
  LibretroSize button = LibretroMenuButtonSize;
  BOOL portrait = height > width;
  double x = portrait ? width - FiniteOrZero(safeInsets.right) - button.w - kSideMargin : width / 2 - button.w / 2;
  return LibretroRectMake(x, FiniteOrZero(safeInsets.top) + kTopMargin, button.w, button.h);
}

+ (LibretroRect)menuButtonFrameForLayout:(LibretroSkinLayoutResult *)layout
                                viewSize:(LibretroSize)viewSize
                              safeInsets:(LibretroInsets)safeInsets
                         controlsVisible:(BOOL)controlsVisible {
  LibretroRect preferred = [self preferredMenuButtonFrameForViewSize:viewSize safeInsets:safeInsets];
  if (layout == nil) return preferred;
  NSMutableData *touch = [NSMutableData data];
  NSMutableData *controls = [NSMutableData data];
  for (LibretroLaidOutScreen *screen in layout.screens) {
    if (screen.touchScreen) AppendObstacle(touch, screen.container);
  }
  for (LibretroLaidOutItem *laidOut in layout.items) {
    if (laidOut.item.kind == LibretroSkinItemKindTouchScreen) {
      AppendObstacle(touch, laidOut.frame);
      AppendObstacle(touch, laidOut.hitFrame);
    } else if (controlsVisible) {
      AppendObstacle(controls, laidOut.hitFrame);
    }
  }
  NSMutableData *everything = [touch mutableCopy];
  [everything appendData:controls];
  if (IsFree(preferred, (const LibretroRect *)everything.bytes, everything.length / sizeof(LibretroRect))) {
    return preferred;
  }
  LibretroRect frame = preferred;
  if (ClosestFreeFrame(preferred, everything, viewSize, safeInsets, &frame)) return frame;
  // Nowhere clear of the controls: at least the touch screens stay free.
  if (controls.length > 0 && ClosestFreeFrame(preferred, touch, viewSize, safeInsets, &frame)) return frame;
  return preferred;
}

+ (NSDictionary<NSString *, NSDictionary *> *)controlsEditorOverridesForKey:(NSString *)layoutKey
                                                                      store:(LibretroFrontendStore *)store
                                                                    console:(NSString *)console
                                                                  scopeGame:(NSString *)scopeGame {
  if (layoutKey.length == 0 || store == nil) return @{};
  id value = scopeGame.length > 0 ? [store valueForKey:layoutKey console:console game:scopeGame scope:NULL]
                                   : [store storedValueForKey:layoutKey console:console game:nil];
  if (![value isKindOfClass:[NSDictionary class]]) return @{};
  NSMutableDictionary<NSString *, NSDictionary *> *overrides = [NSMutableDictionary dictionary];
  NSDictionary *stored = value;
  for (id item in stored) {
    id override = stored[item];
    if ([item isKindOfClass:[NSString class]] && [override isKindOfClass:[NSDictionary class]]) {
      overrides[item] = override;
    }
  }
  return [overrides copy];
}

+ (BOOL)game:(NSString *)game
    hasOwnLayoutForKey:(NSString *)layoutKey
                 store:(LibretroFrontendStore *)store
               console:(NSString *)console {
  if (game.length == 0 || layoutKey.length == 0 || store == nil) return NO;
  return [store storedValueForKey:layoutKey console:console game:game] != nil;
}

@end
