#import "LibretroGeometry.h"

#include <math.h>

const LibretroRect LibretroRectUnit = {0.0, 0.0, 1.0, 1.0};

static const double kPointerScale = 0x7fff;

LibretroRect LibretroRectMake(double x, double y, double w, double h) {
  LibretroRect rect = {x, y, w, h};
  return rect;
}

BOOL LibretroRectIsEmpty(LibretroRect rect) {
  // Written so NaN sizes count as empty too.
  return !(rect.w > 0.0) || !(rect.h > 0.0);
}

BOOL LibretroRectContainsPoint(LibretroRect rect, double x, double y) {
  // Half-open like CGRectContainsPoint: the right and bottom edges are outside.
  if (LibretroRectIsEmpty(rect)) return NO;
  return x >= rect.x && x < rect.x + rect.w && y >= rect.y && y < rect.y + rect.h;
}

BOOL LibretroRectEqualToRect(LibretroRect a, LibretroRect b, double tolerance) {
  double limit = tolerance > 0.0 ? tolerance : 0.0;
  return fabs(a.x - b.x) <= limit && fabs(a.y - b.y) <= limit && fabs(a.w - b.w) <= limit &&
         fabs(a.h - b.h) <= limit;
}

LibretroRect LibretroRectOutset(LibretroRect rect, LibretroInsets edges) {
  LibretroRect result = LibretroRectMake(rect.x - edges.left, rect.y - edges.top, rect.w + edges.left + edges.right,
                                         rect.h + edges.top + edges.bottom);
  // A rectangle shrunk past zero collapses on its centre instead of turning inside out.
  if (result.w < 0.0) {
    result.x += result.w / 2.0;
    result.w = 0.0;
  }
  if (result.h < 0.0) {
    result.y += result.h / 2.0;
    result.h = 0.0;
  }
  return result;
}

LibretroRect LibretroRectInset(LibretroRect rect, LibretroInsets insets) {
  LibretroInsets outward = {-insets.top, -insets.left, -insets.bottom, -insets.right};
  return LibretroRectOutset(rect, outward);
}

LibretroRect LibretroRectAspectFit(LibretroRect container, double aspect) {
  if (!(aspect > 0.0) || isinf(aspect) || LibretroRectIsEmpty(container)) return container;
  double width = container.w;
  double height = width / aspect;
  if (height > container.h) {
    height = container.h;
    width = height * aspect;
  }
  return LibretroRectMake(container.x + (container.w - width) / 2.0, container.y + (container.h - height) / 2.0,
                          width, height);
}

LibretroRect LibretroRectScale(LibretroRect rect, LibretroSize from, LibretroRect to) {
  if (!(from.w > 0.0) || !(from.h > 0.0)) return LibretroRectMake(to.x, to.y, 0.0, 0.0);
  double sx = to.w / from.w;
  double sy = to.h / from.h;
  return LibretroRectMake(to.x + rect.x * sx, to.y + rect.y * sy, rect.w * sx, rect.h * sy);
}

LibretroRect LibretroRectScaleAroundCenter(LibretroRect rect, double factor) {
  double width = rect.w * factor;
  double height = rect.h * factor;
  return LibretroRectMake(rect.x + (rect.w - width) / 2.0, rect.y + (rect.h - height) / 2.0, width, height);
}

LibretroRect LibretroRectIntersection(LibretroRect a, LibretroRect b) {
  if (LibretroRectIsEmpty(a) || LibretroRectIsEmpty(b)) return LibretroRectMake(0.0, 0.0, 0.0, 0.0);
  double left = fmax(a.x, b.x);
  double top = fmax(a.y, b.y);
  double right = fmin(a.x + a.w, b.x + b.w);
  double bottom = fmin(a.y + a.h, b.y + b.h);
  if (!(right > left) || !(bottom > top)) return LibretroRectMake(0.0, 0.0, 0.0, 0.0);
  return LibretroRectMake(left, top, right - left, bottom - top);
}

#pragma mark - Screen format

NSString *LibretroScreenFormatIdentifier(LibretroScreenFormat format) {
  switch (format) {
    case LibretroScreenFormat4x3:
      return @"4:3";
    case LibretroScreenFormat16x9:
      return @"16:9";
    case LibretroScreenFormat16x10:
      return @"16:10";
    case LibretroScreenFormatStretch:
      return @"stretch";
    case LibretroScreenFormatOriginal:
      break;
  }
  return @"original";
}

LibretroScreenFormat LibretroScreenFormatFromIdentifier(NSString *identifier) {
  if (![identifier isKindOfClass:[NSString class]]) return LibretroScreenFormatOriginal;
  NSString *name = identifier.lowercaseString;
  if ([name isEqualToString:@"4:3"]) return LibretroScreenFormat4x3;
  if ([name isEqualToString:@"16:9"]) return LibretroScreenFormat16x9;
  if ([name isEqualToString:@"16:10"]) return LibretroScreenFormat16x10;
  if ([name isEqualToString:@"stretch"]) return LibretroScreenFormatStretch;
  return LibretroScreenFormatOriginal;
}

NSArray<NSString *> *LibretroScreenFormatIdentifiers(void) {
  return @[ @"original", @"4:3", @"16:9", @"16:10", @"stretch" ];
}

double LibretroSourceAspect(double coreAspect, LibretroRect source, unsigned rotation) {
  if (!(coreAspect > 0.0) || isinf(coreAspect) || LibretroRectIsEmpty(source)) return 0.0;
  double aspect = coreAspect * source.w / source.h;
  return rotation % 2 == 1 ? 1.0 / aspect : aspect;
}

LibretroRect LibretroFitScreen(LibretroRect container, double sourceAspect, LibretroScreenFormat format) {
  switch (format) {
    case LibretroScreenFormat4x3:
      return LibretroRectAspectFit(container, 4.0 / 3.0);
    case LibretroScreenFormat16x9:
      return LibretroRectAspectFit(container, 16.0 / 9.0);
    case LibretroScreenFormat16x10:
      return LibretroRectAspectFit(container, 16.0 / 10.0);
    case LibretroScreenFormatStretch:
      return container;
    case LibretroScreenFormatOriginal:
      break;
  }
  return LibretroRectAspectFit(container, sourceAspect);
}

#pragma mark - Touch

static double Clamp01(double value) {
  if (!(value > 0.0)) return 0.0;
  return value > 1.0 ? 1.0 : value;
}

static int16_t PointerCoordinate(double normalized) {
  double value = round((normalized * 2.0 - 1.0) * kPointerScale);
  if (value > kPointerScale) value = kPointerScale;
  if (value < -kPointerScale) value = -kPointerScale;
  return (int16_t)value;
}

BOOL LibretroPointerFromPoint(LibretroScreenMapping mapping, double x, double y, BOOL clamp, int16_t *outX,
                              int16_t *outY) {
  LibretroRect output = mapping.output;
  if (LibretroRectIsEmpty(output) || LibretroRectIsEmpty(mapping.source)) return NO;
  double u = (x - output.x) / output.w;
  double v = (y - output.y) / output.h;
  // The edges belong to the screen: a finger on the border still touches it.
  BOOL inside = u >= 0.0 && u <= 1.0 && v >= 0.0 && v <= 1.0;
  if (!inside && !clamp) return NO;
  u = Clamp01(u);
  v = Clamp01(v);
  // Image corner (i + rotation) % 4 is drawn at output corner i, clockwise
  // from top-left: undo that to find the point in the source picture.
  double s;
  double t;
  switch (mapping.rotation % 4) {
    case 1:
      s = 1.0 - v;
      t = u;
      break;
    case 2:
      s = 1.0 - u;
      t = 1.0 - v;
      break;
    case 3:
      s = v;
      t = 1.0 - u;
      break;
    default:
      s = u;
      t = v;
      break;
  }
  LibretroRect source = mapping.source;
  *outX = PointerCoordinate(source.x + s * source.w);
  *outY = PointerCoordinate(source.y + t * source.h);
  return YES;
}

LibretroDirection LibretroDPadDirections(LibretroRect frame, double x, double y) {
  if (LibretroRectIsEmpty(frame)) return 0;
  double dx = x - (frame.x + frame.w / 2.0);
  double dy = y - (frame.y + frame.h / 2.0);
  double dead = frame.w * 0.12;
  if (dx * dx + dy * dy < dead * dead) return 0;
  // Eight sectors: cardinal directions span 135 degrees, so diagonals are
  // the 45 degree overlaps (same as the historical overlay).
  double angle = atan2(-dy, dx) * 180.0 / M_PI;
  if (angle < 0.0) angle += 360.0;
  LibretroDirection directions = 0;
  if (angle < 67.5 || angle >= 292.5) directions |= LibretroDirectionRight;
  if (angle >= 22.5 && angle < 157.5) directions |= LibretroDirectionUp;
  if (angle >= 112.5 && angle < 247.5) directions |= LibretroDirectionLeft;
  if (angle >= 202.5 && angle < 337.5) directions |= LibretroDirectionDown;
  return directions;
}

void LibretroStickVector(LibretroRect frame, double x, double y, double *outX, double *outY) {
  double radius = frame.w * 0.5;
  if (!(radius > 0.0)) {
    *outX = 0.0;
    *outY = 0.0;
    return;
  }
  double dx = (x - (frame.x + frame.w / 2.0)) / radius;
  double dy = (y - (frame.y + frame.h / 2.0)) / radius;
  double magnitude = hypot(dx, dy);
  if (magnitude > 1.0) {
    dx /= magnitude;
    dy /= magnitude;
  }
  *outX = dx;
  *outY = dy;
}
