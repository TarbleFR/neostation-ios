// Behavioural test of LibretroGeometry (portable layout math): rectangles,
// screen formats, touch pointer mapping through every rotation and source
// region (DS / 3DS screens), D-pad sectors and stick vectors.
#import <Foundation/Foundation.h>

#import "LibretroGeometry.h"

#include <math.h>
#include <stdio.h>

static int failures = 0;

static void Report(BOOL passed, NSString *message, int line) {
  if (passed) {
    printf("PASS %s\n", message.UTF8String);
  } else {
    printf("FAIL %s (%s:%d)\n", message.UTF8String, __FILE__, line);
    failures++;
  }
}

#define CHECK(condition, ...) Report((condition) ? YES : NO, [NSString stringWithFormat:__VA_ARGS__], __LINE__)

static BOOL Near(double a, double b) { return fabs(a - b) < 1e-9; }

static BOOL RectNear(LibretroRect a, LibretroRect b) { return LibretroRectEqualToRect(a, b, 1e-9); }

static void TestRectangles(void) {
  LibretroRect rect = LibretroRectMake(10, 20, 30, 40);
  CHECK(rect.x == 10 && rect.y == 20 && rect.w == 30 && rect.h == 40, @"LibretroRectMake keeps its fields");
  CHECK(RectNear(LibretroRectUnit, LibretroRectMake(0, 0, 1, 1)), @"unit rectangle is {0, 0, 1, 1}");
  CHECK(LibretroRectIsEmpty(LibretroRectMake(0, 0, 0, 5)) && LibretroRectIsEmpty(LibretroRectMake(0, 0, 5, -1)) &&
            LibretroRectIsEmpty(LibretroRectMake(0, 0, NAN, 5)) && !LibretroRectIsEmpty(rect),
        @"zero, negative and NaN sizes are empty");
  CHECK(LibretroRectContainsPoint(rect, 10, 20) && LibretroRectContainsPoint(rect, 39.9, 59.9) &&
            !LibretroRectContainsPoint(rect, 40, 30) && !LibretroRectContainsPoint(rect, 20, 60) &&
            !LibretroRectContainsPoint(rect, 9.9, 30),
        @"contains its origin, not its right and bottom edges");
  CHECK(!LibretroRectContainsPoint(LibretroRectMake(0, 0, 0, 0), 0, 0), @"an empty rectangle contains nothing");
  CHECK(LibretroRectEqualToRect(rect, LibretroRectMake(10.4, 20, 30, 40), 0.5) &&
            !LibretroRectEqualToRect(rect, LibretroRectMake(10.6, 20, 30, 40), 0.5),
        @"equality honours the tolerance");

  LibretroInsets edges = {1, 2, 3, 4};  // top, left, bottom, right
  CHECK(RectNear(LibretroRectOutset(rect, edges), LibretroRectMake(8, 19, 36, 44)), @"outset grows every edge");
  CHECK(RectNear(LibretroRectInset(rect, edges), LibretroRectMake(12, 21, 24, 36)), @"inset shrinks every edge");
  LibretroInsets huge = {30, 30, 30, 30};
  LibretroRect collapsed = LibretroRectInset(rect, huge);
  CHECK(collapsed.w == 0 && collapsed.h == 0 && Near(collapsed.x, 25) && Near(collapsed.y, 40),
        @"an inset past zero collapses on the centre");

  LibretroRect wide = LibretroRectMake(0, 0, 1000, 500);
  CHECK(RectNear(LibretroRectAspectFit(wide, 4.0 / 3.0), LibretroRectMake(500 - 1000.0 / 3.0, 0, 2000.0 / 3.0, 500)),
        @"aspect fit pillarboxes in a wide container");
  LibretroRect tall = LibretroRectMake(10, 10, 400, 800);
  CHECK(RectNear(LibretroRectAspectFit(tall, 4.0 / 3.0), LibretroRectMake(10, 260, 400, 300)),
        @"aspect fit letterboxes in a tall container");
  CHECK(RectNear(LibretroRectAspectFit(wide, 0), wide) && RectNear(LibretroRectAspectFit(wide, -2), wide) &&
            RectNear(LibretroRectAspectFit(wide, NAN), wide),
        @"aspect fit keeps the container for a non-positive aspect");

  LibretroSize mapping = {100, 50};
  CHECK(RectNear(LibretroRectScale(LibretroRectMake(10, 5, 20, 10), mapping, LibretroRectMake(10, 20, 200, 100)),
                 LibretroRectMake(30, 30, 40, 20)),
        @"scale maps mapping units into the destination");
  LibretroSize nothing = {0, 50};
  LibretroRect degenerate = LibretroRectScale(rect, nothing, wide);
  CHECK(LibretroRectIsEmpty(degenerate) && isfinite(degenerate.x), @"scale from an empty space gives an empty rect");
  CHECK(RectNear(LibretroRectScaleAroundCenter(rect, 2), LibretroRectMake(-5, 0, 60, 80)) &&
            RectNear(LibretroRectScaleAroundCenter(rect, 0.5), LibretroRectMake(17.5, 30, 15, 20)),
        @"scale around the centre keeps the centre");
  CHECK(RectNear(LibretroRectIntersection(rect, LibretroRectMake(30, 50, 100, 100)), LibretroRectMake(30, 50, 10, 10)),
        @"intersection of overlapping rectangles");
  CHECK(LibretroRectIsEmpty(LibretroRectIntersection(rect, LibretroRectMake(40, 20, 10, 10))) &&
            LibretroRectIsEmpty(LibretroRectIntersection(rect, LibretroRectMake(100, 100, 10, 10))),
        @"touching or disjoint rectangles have an empty intersection");
}

static void TestScreenFormats(void) {
  NSArray<NSString *> *expected = @[ @"original", @"4:3", @"16:9", @"16:10", @"stretch" ];
  CHECK([LibretroScreenFormatIdentifiers() isEqualToArray:expected], @"screen format identifiers in menu order");
  for (NSString *identifier in expected) {
    LibretroScreenFormat format = LibretroScreenFormatFromIdentifier(identifier);
    CHECK([LibretroScreenFormatIdentifier(format) isEqualToString:identifier], @"format %@ round-trips", identifier);
  }
  CHECK(LibretroScreenFormatFromIdentifier(@"4:3") == LibretroScreenFormat4x3 &&
            LibretroScreenFormatFromIdentifier(@"16:9") == LibretroScreenFormat16x9 &&
            LibretroScreenFormatFromIdentifier(@"16:10") == LibretroScreenFormat16x10 &&
            LibretroScreenFormatFromIdentifier(@"stretch") == LibretroScreenFormatStretch,
        @"identifiers give their format");
  CHECK(LibretroScreenFormatFromIdentifier(nil) == LibretroScreenFormatOriginal &&
            LibretroScreenFormatFromIdentifier(@"21:9") == LibretroScreenFormatOriginal &&
            LibretroScreenFormatFromIdentifier(@"") == LibretroScreenFormatOriginal,
        @"nil and unknown identifiers give Original");

  CHECK(Near(LibretroSourceAspect(4.0 / 3.0, LibretroRectUnit, 0), 4.0 / 3.0), @"whole picture keeps the core aspect");
  CHECK(Near(LibretroSourceAspect(4.0 / 3.0, LibretroRectUnit, 1), 3.0 / 4.0) &&
            Near(LibretroSourceAspect(4.0 / 3.0, LibretroRectUnit, 3), 3.0 / 4.0) &&
            Near(LibretroSourceAspect(4.0 / 3.0, LibretroRectUnit, 2), 4.0 / 3.0),
        @"odd rotations invert the aspect");
  // DS: 256x384 stacked, each screen 256x192. 3DS: 400x480, bottom 320x240 centred.
  CHECK(Near(LibretroSourceAspect(256.0 / 384.0, LibretroRectMake(0, 0.5, 1, 0.5), 0), 4.0 / 3.0),
        @"DS bottom screen region is 4:3");
  CHECK(Near(LibretroSourceAspect(400.0 / 480.0, LibretroRectMake(0, 0, 1, 0.5), 0), 400.0 / 240.0) &&
            Near(LibretroSourceAspect(400.0 / 480.0, LibretroRectMake(0.1, 0.5, 0.8, 0.5), 0), 4.0 / 3.0),
        @"3DS top screen is 5:3 and bottom screen 4:3");
  CHECK(LibretroSourceAspect(0, LibretroRectUnit, 0) == 0 &&
            LibretroSourceAspect(1, LibretroRectMake(0, 0, 0, 1), 0) == 0,
        @"invalid aspect or empty source gives 0");

  LibretroRect container = LibretroRectMake(0, 0, 1000, 500);
  CHECK(RectNear(LibretroFitScreen(container, 4.0 / 3.0, LibretroScreenFormatOriginal),
                 LibretroRectAspectFit(container, 4.0 / 3.0)),
        @"Original fits the source aspect");
  CHECK(RectNear(LibretroFitScreen(container, 4.0 / 3.0, LibretroScreenFormat16x9),
                 LibretroRectMake(500 - 4000.0 / 9.0, 0, 8000.0 / 9.0, 500)),
        @"16:9 fits that ratio whatever the source");
  CHECK(RectNear(LibretroFitScreen(container, 16.0 / 9.0, LibretroScreenFormat16x10),
                 LibretroRectMake(100, 0, 800, 500)),
        @"16:10 fits that ratio");
  CHECK(RectNear(LibretroFitScreen(container, 16.0 / 9.0, LibretroScreenFormat4x3),
                 LibretroRectMake(500 - 1000.0 / 3.0, 0, 2000.0 / 3.0, 500)),
        @"4:3 fits that ratio");
  CHECK(RectNear(LibretroFitScreen(container, 4.0 / 3.0, LibretroScreenFormatStretch), container),
        @"Stretch fills the container");
  CHECK(RectNear(LibretroFitScreen(container, 0, LibretroScreenFormatOriginal), container),
        @"Original with an unknown aspect fills the container");
  LibretroRect portrait = LibretroRectMake(20, 40, 390, 600);
  for (NSString *identifier in expected) {
    LibretroRect fitted = LibretroFitScreen(portrait, 8.0 / 7.0, LibretroScreenFormatFromIdentifier(identifier));
    BOOL inside = fitted.x >= portrait.x - 1e-9 && fitted.y >= portrait.y - 1e-9 &&
                  fitted.x + fitted.w <= portrait.x + portrait.w + 1e-9 &&
                  fitted.y + fitted.h <= portrait.y + portrait.h + 1e-9;
    BOOL centred = Near(fitted.x + fitted.w / 2, portrait.x + portrait.w / 2) &&
                   Near(fitted.y + fitted.h / 2, portrait.y + portrait.h / 2);
    CHECK(inside && centred, @"format %@ stays inside the container and centred", identifier);
  }
}

static BOOL PointerAt(LibretroScreenMapping mapping, double x, double y, BOOL clamp, int16_t expectedX,
                      int16_t expectedY) {
  int16_t px = 0;
  int16_t py = 0;
  return LibretroPointerFromPoint(mapping, x, y, clamp, &px, &py) && px == expectedX && py == expectedY;
}

static void TestPointer(void) {
  LibretroScreenMapping mapping = {LibretroRectMake(100, 100, 200, 100), LibretroRectUnit, 0};
  CHECK(PointerAt(mapping, 200, 150, NO, 0, 0), @"centre of the screen is pointer 0, 0");
  CHECK(PointerAt(mapping, 100, 100, NO, -0x7fff, -0x7fff), @"top-left corner is -0x7fff, -0x7fff");
  CHECK(PointerAt(mapping, 300, 200, NO, 0x7fff, 0x7fff), @"bottom-right corner is 0x7fff, 0x7fff");
  CHECK(PointerAt(mapping, 150, 125, NO, -16384, -16384), @"quarter points round to the nearest value");
  int16_t px = 123;
  int16_t py = 456;
  CHECK(!LibretroPointerFromPoint(mapping, 350, 150, NO, &px, &py) &&
            !LibretroPointerFromPoint(mapping, 200, 99, NO, &px, &py),
        @"a point outside the screen is refused");
  CHECK(PointerAt(mapping, 350, 150, YES, 0x7fff, 0) && PointerAt(mapping, -50, -50, YES, -0x7fff, -0x7fff),
        @"with clamp a point outside is pinned to the edge");
  LibretroScreenMapping empty = {LibretroRectMake(0, 0, 0, 100), LibretroRectUnit, 0};
  CHECK(!LibretroPointerFromPoint(empty, 0, 0, YES, &px, &py), @"an empty screen never maps a point");

  // DS bottom screen: the pointer covers the whole stacked image.
  LibretroScreenMapping bottom = {LibretroRectMake(0, 300, 256, 192), LibretroRectMake(0, 0.5, 1, 0.5), 0};
  CHECK(PointerAt(bottom, 128, 396, NO, 0, 16384), @"DS bottom centre maps into the lower half of the core image");
  CHECK(PointerAt(bottom, 0, 300, NO, -0x7fff, 0), @"DS bottom top-left is the middle-left of the core image");
  // 3DS bottom screen, centred under the 400-wide top screen.
  LibretroScreenMapping threeDS = {LibretroRectMake(0, 0, 320, 240), LibretroRectMake(0.1, 0.5, 0.8, 0.5), 0};
  CHECK(PointerAt(threeDS, 0, 0, NO, -26214, 0) && PointerAt(threeDS, 320, 240, NO, 26214, 0x7fff),
        @"3DS bottom screen corners map inside its region");

  // Rotation: image corner (i + rotation) % 4 is drawn at output corner i,
  // clockwise from top-left.
  const double corners[4][2] = {{0, 0}, {1, 0}, {1, 1}, {0, 1}};
  const int16_t pointerCorners[4][2] = {{-0x7fff, -0x7fff}, {0x7fff, -0x7fff}, {0x7fff, 0x7fff}, {-0x7fff, 0x7fff}};
  for (unsigned rotation = 0; rotation < 8; rotation++) {
    LibretroScreenMapping rotated = {LibretroRectMake(50, 60, 300, 200), LibretroRectUnit, rotation};
    BOOL all = YES;
    for (unsigned corner = 0; corner < 4; corner++) {
      unsigned image = (corner + rotation) % 4;
      double x = 50 + corners[corner][0] * 300;
      double y = 60 + corners[corner][1] * 200;
      all = all && PointerAt(rotated, x, y, NO, pointerCorners[image][0], pointerCorners[image][1]);
    }
    CHECK(all, @"rotation %u shows image corner (i + rotation) %% 4 at output corner i", rotation);
  }
  LibretroScreenMapping quarter = {LibretroRectMake(0, 0, 100, 200), LibretroRectUnit, 1};
  // Output point at 25 percent of the width, 50 percent of the height:
  // s = 1 - v = 0.5, t = u = 0.25.
  CHECK(PointerAt(quarter, 25, 100, NO, 0, -16384), @"rotation 1 maps an inner point (s = 1 - v, t = u)");
  LibretroScreenMapping three = {LibretroRectMake(0, 0, 100, 200), LibretroRectUnit, 3};
  CHECK(PointerAt(three, 25, 100, NO, 0, 16384), @"rotation 3 maps an inner point (s = v, t = 1 - u)");
  LibretroScreenMapping rotatedRegion = {LibretroRectMake(0, 0, 192, 256), LibretroRectMake(0, 0.5, 1, 0.5), 1};
  CHECK(PointerAt(rotatedRegion, 0, 0, NO, 0x7fff, 0), @"rotation applies inside the source region");
}

static void TestDPadAndStick(void) {
  LibretroRect pad = LibretroRectMake(0, 0, 100, 100);
  CHECK(LibretroDPadDirections(pad, 50, 50) == 0, @"centre of the D-pad presses nothing");
  CHECK(LibretroDPadDirections(pad, 55, 53) == 0, @"dead zone of 12 percent of the width");
  CHECK(LibretroDPadDirections(pad, 62, 50) == LibretroDirectionRight, @"edge of the dead zone already presses");
  CHECK(LibretroDPadDirections(pad, 100, 50) == LibretroDirectionRight, @"right");
  CHECK(LibretroDPadDirections(pad, 50, 0) == LibretroDirectionUp, @"up (y grows downward)");
  CHECK(LibretroDPadDirections(pad, 0, 50) == LibretroDirectionLeft, @"left");
  CHECK(LibretroDPadDirections(pad, 50, 100) == LibretroDirectionDown, @"down");
  CHECK(LibretroDPadDirections(pad, 95, 5) == (LibretroDirectionUp | LibretroDirectionRight), @"up-right diagonal");
  CHECK(LibretroDPadDirections(pad, 5, 95) == (LibretroDirectionDown | LibretroDirectionLeft), @"down-left diagonal");
  CHECK(LibretroDPadDirections(pad, 5, 5) == (LibretroDirectionUp | LibretroDirectionLeft), @"up-left diagonal");
  CHECK(LibretroDPadDirections(pad, 95, 95) == (LibretroDirectionDown | LibretroDirectionRight),
        @"down-right diagonal");
  double radians = 10.0 * M_PI / 180.0;
  CHECK(LibretroDPadDirections(pad, 50 + 40 * cos(radians), 50 - 40 * sin(radians)) == LibretroDirectionRight,
        @"10 degrees is right only");
  radians = 30.0 * M_PI / 180.0;
  CHECK(LibretroDPadDirections(pad, 50 + 40 * cos(radians), 50 - 40 * sin(radians)) ==
            (LibretroDirectionUp | LibretroDirectionRight),
        @"30 degrees is in the up-right overlap");
  CHECK(LibretroDPadDirections(pad, 300, 50) == LibretroDirectionRight,
        @"a finger that slid outside keeps a direction");
  CHECK(LibretroDPadDirections(LibretroRectMake(0, 0, 0, 0), 10, 10) == 0, @"an empty D-pad presses nothing");

  LibretroRect stick = LibretroRectMake(100, 100, 100, 100);
  double x = 9;
  double y = 9;
  LibretroStickVector(stick, 150, 150, &x, &y);
  CHECK(x == 0 && y == 0, @"stick centre is neutral");
  LibretroStickVector(stick, 175, 150, &x, &y);
  CHECK(Near(x, 0.5) && Near(y, 0), @"half way right is 0.5");
  LibretroStickVector(stick, 150, 100, &x, &y);
  CHECK(Near(x, 0) && Near(y, -1), @"up is negative y (libretro convention)");
  LibretroStickVector(stick, 400, 150, &x, &y);
  CHECK(Near(x, 1) && Near(y, 0), @"deflection is clamped to the unit circle");
  LibretroStickVector(stick, 250, 250, &x, &y);
  CHECK(Near(x, sqrt(0.5)) && Near(y, sqrt(0.5)), @"diagonal deflection is clamped to the unit circle");
  LibretroStickVector(LibretroRectMake(0, 0, 0, 0), 5, 5, &x, &y);
  CHECK(x == 0 && y == 0, @"an empty stick is neutral");
}

int main(int argc, const char *argv[]) {
  @autoreleasepool {
    TestRectangles();
    TestScreenFormats();
    TestPointer();
    TestDPadAndStick();
  }
  if (failures > 0) {
    printf("%d geometry check(s) failed\n", failures);
    return 1;
  }
  printf("All geometry checks passed\n");
  return 0;
}
