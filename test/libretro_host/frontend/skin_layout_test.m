// Behavioural test of LibretroSkinLayout: Delta placement of imported skins
// (portrait pinned to the bottom, aspect fit otherwise, screens scaled from
// the mapping, app placement), generated skins kept as is, user overrides
// on movable items, clamping inside the view and off the DS / 3DS touch
// screen (frame and touch area, last valid override kept when nothing
// fits), the hit-test priorities (thumbstick, exclusive menu, buttons,
// touch screen last; extended edges never on a drawn touch screen), the
// thumbstick knob following its vector and a held stylus after the touch
// screen moved.
#import <Foundation/Foundation.h>

#import "LibretroSkin.h"
#import "LibretroSkinLayout.h"

#include <math.h>
#include <stdio.h>
#include <string.h>

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

static BOOL RectNear(LibretroRect a, LibretroRect b) { return LibretroRectEqualToRect(a, b, 1e-6); }

static BOOL Overlaps(LibretroRect a, LibretroRect b) {
  double width = MIN(a.x + a.w, b.x + b.w) - MAX(a.x, b.x);
  double height = MIN(a.y + a.h, b.y + b.h) - MAX(a.y, b.y);
  return width > 1e-6 && height > 1e-6;
}

static BOOL Inside(LibretroRect inner, LibretroSize view) {
  return inner.x >= -1e-6 && inner.y >= -1e-6 && inner.x + inner.w <= view.w + 1e-6 && inner.y + inner.h <= view.h + 1e-6;
}

static NSString *Describe(LibretroRect rect) {
  return [NSString stringWithFormat:@"{%.3f, %.3f, %.3f, %.3f}", rect.x, rect.y, rect.w, rect.h];
}

static LibretroSkinItem *Item(NSString *identifier, LibretroSkinItemKind kind, LibretroRect frame, NSArray<NSString *> *inputs,
                              double edge, BOOL movable) {
  LibretroSkinItem *item = [LibretroSkinItem new];
  item.identifier = identifier;
  item.kind = kind;
  item.frame = frame;
  LibretroInsets edges = {edge, edge, edge, edge};
  item.hitFrame = kind == LibretroSkinItemKindTouchScreen ? frame : LibretroRectOutset(frame, edges);
  item.assetFrame = frame;
  item.inputs = inputs;
  item.movable = movable;
  return item;
}

static LibretroSkinScreen *Screen(LibretroRect output, BOOL hasOutput, NSString *role, BOOL touch) {
  LibretroSkinScreen *screen = [LibretroSkinScreen new];
  screen.outputFrame = output;
  screen.hasOutputFrame = hasOutput;
  screen.role = role;
  screen.touchScreen = touch;
  return screen;
}

static LibretroSkinRepresentation *Representation(LibretroSkinOrientation orientation, double width, double height,
                                                  NSArray<LibretroSkinItem *> *items,
                                                  NSArray<LibretroSkinScreen *> *screens) {
  LibretroSkinRepresentation *representation = [LibretroSkinRepresentation new];
  representation.orientation = orientation;
  representation.mappingSize = (LibretroSize){width, height};
  representation.items = items;
  representation.screens = screens;
  return representation;
}

static LibretroLaidOutItem *LaidOut(LibretroSkinLayoutResult *layout, NSString *identifier) {
  for (LibretroLaidOutItem *item in layout.items) {
    if ([item.item.identifier isEqualToString:identifier]) return item;
  }
  return nil;
}

static NSString *Identifiers(NSArray<LibretroLaidOutItem *> *items) {
  NSMutableArray<NSString *> *identifiers = [NSMutableArray array];
  for (LibretroLaidOutItem *item in items) [identifiers addObject:item.item.identifier];
  return [identifiers componentsJoinedByString:@","];
}

static const LibretroInsets kNoInsets = {0, 0, 0, 0};

static void TestPortraitPinned(void) {
  // Official Delta GBA portrait: a 320x240 controller, no screen frame.
  LibretroSkinItem *a = Item(@"item0", LibretroSkinItemKindButton, LibretroRectMake(10, 10, 50, 50), @[ @"a" ], 5, YES);
  a.assetFrame = LibretroRectMake(15, 15, 40, 40);
  LibretroSkinRepresentation *rep = Representation(LibretroSkinOrientationPortrait, 320, 240, @[ a ], @[]);
  LibretroInsets insets = {47, 0, 34, 0};
  LibretroSkinLayoutResult *layout = [LibretroSkinLayout layoutRepresentation:rep
                                                                     viewSize:(LibretroSize){390, 844}
                                                                   safeInsets:insets
                                                                    overrides:nil];
  CHECK(RectNear(layout.skinRect, LibretroRectMake(0, 844 - 292.5, 390, 292.5)),
        @"portrait without screen frames: pinned to the bottom at full width %@", Describe(layout.skinRect));
  CHECK(layout.screens.count == 1 && [layout.screens[0].role isEqualToString:@"full"] &&
            RectNear(layout.screens[0].container, LibretroRectMake(0, 47, 390, 551.5 - 47)) &&
            RectNear(layout.screens[0].source, LibretroRectMake(0, 0, 1, 1)),
        @"the game fills the area above it, below the safe area %@", Describe(layout.screens[0].container));
  double scale = 390.0 / 320.0;
  LibretroLaidOutItem *laidOut = LaidOut(layout, @"item0");
  CHECK(RectNear(laidOut.frame, LibretroRectMake(10 * scale, 551.5 + 10 * scale, 50 * scale, 50 * scale)),
        @"item frame scaled from the mapping %@", Describe(laidOut.frame));
  CHECK(RectNear(laidOut.hitFrame, LibretroRectMake(5 * scale, 551.5 + 5 * scale, 60 * scale, 60 * scale)) &&
            RectNear(laidOut.assetFrame, LibretroRectMake(15 * scale, 551.5 + 15 * scale, 40 * scale, 40 * scale)),
        @"hit and image frames scaled the same way");
  CHECK(layout.panelFrame.w == 0 && layout.panelFrame.h == 0, @"imported skins have no panel");

  // A screen without outputFrame keeps the pinned layout.
  rep.screens = @[ Screen(LibretroRectMake(0, 0, 0, 0), NO, @"full", NO) ];
  layout = [LibretroSkinLayout layoutRepresentation:rep viewSize:(LibretroSize){390, 844} safeInsets:insets overrides:nil];
  CHECK(RectNear(layout.screens[0].container, LibretroRectMake(0, 47, 390, 504.5)),
        @"screen without output frame fills the game area");

  // A controller taller than the view is aspect-fitted instead.
  LibretroSkinRepresentation *tall = Representation(LibretroSkinOrientationPortrait, 100, 400, @[], @[]);
  layout = [LibretroSkinLayout layoutRepresentation:tall viewSize:(LibretroSize){390, 844} safeInsets:insets overrides:nil];
  CHECK(RectNear(layout.skinRect, LibretroRectMake((390 - 211) / 2.0, 0, 211, 844)),
        @"a pinned controller never leaves the view %@", Describe(layout.skinRect));
}

static void TestAspectFit(void) {
  // DS landscape: mapping 667x375 fitted in an 844x390 view.
  LibretroSkinScreen *top = Screen(LibretroRectMake(50, 18, 275, 206), YES, @"top", NO);
  top.source = LibretroRectMake(0, 0, 1, 0.5);
  LibretroSkinScreen *unframed = Screen(LibretroRectMake(0, 0, 0, 0), NO, @"full", NO);
  LibretroSkinItem *b = Item(@"item0", LibretroSkinItemKindButton, LibretroRectMake(600, 300, 40, 40), @[ @"b" ], 0, NO);
  LibretroSkinRepresentation *rep = Representation(LibretroSkinOrientationLandscape, 667, 375, @[ b ], @[ top, unframed ]);
  LibretroInsets insets = {0, 47, 21, 47};
  LibretroSkinLayoutResult *layout = [LibretroSkinLayout layoutRepresentation:rep
                                                                     viewSize:(LibretroSize){844, 390}
                                                                   safeInsets:insets
                                                                    overrides:nil];
  double scale = 390.0 / 375.0, width = 667 * scale, x = (844 - width) / 2;
  CHECK(RectNear(layout.skinRect, LibretroRectMake(x, 0, width, 390)),
        @"landscape: aspect fit in the full view, safe areas ignored %@", Describe(layout.skinRect));
  CHECK(layout.screens.count == 2 &&
            RectNear(layout.screens[0].container, LibretroRectMake(x + 50 * scale, 18 * scale, 275 * scale, 206 * scale)),
        @"output frame scaled into the skin rectangle %@", Describe(layout.screens[0].container));
  CHECK(layout.screens.count == 2 && RectNear(layout.screens[0].source, LibretroRectMake(0, 0, 1, 0.5)) &&
            [layout.screens[0].role isEqualToString:@"top"],
        @"source and role kept");
  CHECK(layout.screens.count == 2 && RectNear(layout.screens[1].container, LibretroRectMake(0, 0, 844, 390)),
        @"a screen without output frame fills the whole view");
  CHECK(RectNear(LaidOut(layout, @"item0").frame, LibretroRectMake(x + 600 * scale, 300 * scale, 40 * scale, 40 * scale)),
        @"items follow the skin rectangle");

  // Portrait with output frames: aspect fit too (Delta), not pinned.
  LibretroSkinRepresentation *portrait =
      Representation(LibretroSkinOrientationPortrait, 375, 667, @[], @[ Screen(LibretroRectMake(50, 18, 275, 206), YES, @"full", NO) ]);
  layout = [LibretroSkinLayout layoutRepresentation:portrait viewSize:(LibretroSize){390, 844} safeInsets:kNoInsets overrides:nil];
  double portraitScale = 390.0 / 375.0, height = 667 * portraitScale, y = (844 - height) / 2;
  CHECK(RectNear(layout.skinRect, LibretroRectMake(0, y, 390, height)), @"portrait with screen frames is centred %@",
        Describe(layout.skinRect));
  CHECK(RectNear(layout.screens[0].container,
                 LibretroRectMake(50 * portraitScale, y + 18 * portraitScale, 275 * portraitScale, 206 * portraitScale)),
        @"portrait screen scaled");

  // Screens larger than the mapping (blurred backdrop) are not clipped.
  LibretroSkinRepresentation *backdrop = Representation(
      LibretroSkinOrientationPortrait, 430, 932, @[], @[ Screen(LibretroRectMake(-403, 0, 1235, 400), YES, @"full", NO) ]);
  layout = [LibretroSkinLayout layoutRepresentation:backdrop viewSize:(LibretroSize){430, 932} safeInsets:kNoInsets overrides:nil];
  CHECK(RectNear(layout.screens[0].container, LibretroRectMake(-403, 0, 1235, 400)), @"backdrop screen kept as is");

  // placement app: normalized in the game area.
  LibretroSkinScreen *app = Screen(LibretroRectMake(0, 0.5, 1, 0.5), YES, @"bottom", YES);
  app.appPlacement = YES;
  LibretroSkinRepresentation *split = Representation(LibretroSkinOrientationLandscape, 1024, 472, @[], @[ app ]);
  layout = [LibretroSkinLayout layoutRepresentation:split viewSize:(LibretroSize){844, 390} safeInsets:kNoInsets overrides:nil];
  CHECK(RectNear(layout.screens[0].container, LibretroRectMake(0, 195, 844, 195)) && layout.screens[0].touchScreen,
        @"placement app is a fraction of the game area");
  LibretroSkinRepresentation *appPortrait = Representation(LibretroSkinOrientationPortrait, 320, 240, @[], @[ app ]);
  layout = [LibretroSkinLayout layoutRepresentation:appPortrait viewSize:(LibretroSize){390, 844} safeInsets:kNoInsets overrides:nil];
  CHECK(RectNear(layout.skinRect, LibretroRectMake(0, 551.5, 390, 292.5)) &&
            RectNear(layout.screens[0].container, LibretroRectMake(0, 275.75, 390, 275.75)),
        @"app screens keep the pinned portrait layout %@", Describe(layout.screens[0].container));
}

static void TestGenerated(void) {
  LibretroSkinItem *a = Item(@"a", LibretroSkinItemKindButton, LibretroRectMake(300, 600, 60, 60), @[ @"a" ], 6, YES);
  LibretroSkinRepresentation *rep = Representation(LibretroSkinOrientationPortrait, 390, 844, @[ a ],
                                                   @[ Screen(LibretroRectMake(0, 47, 390, 292), YES, @"full", NO) ]);
  rep.generated = YES;
  rep.panelColor = 0xFF223344;
  rep.panelFrame = LibretroRectMake(0, 345, 390, 499);
  LibretroInsets insets = {47, 0, 34, 0};
  LibretroSkinLayoutResult *layout = [LibretroSkinLayout layoutRepresentation:rep
                                                                     viewSize:(LibretroSize){390, 844}
                                                                   safeInsets:insets
                                                                    overrides:nil];
  CHECK(RectNear(layout.skinRect, LibretroRectMake(0, 0, 390, 844)), @"generated skin: mapping == view");
  CHECK(RectNear(LaidOut(layout, @"a").frame, a.frame) && RectNear(LaidOut(layout, @"a").hitFrame, a.hitFrame),
        @"generated items kept as is");
  CHECK(RectNear(layout.screens[0].container, LibretroRectMake(0, 47, 390, 292)), @"generated screens kept as is");
  CHECK(RectNear(layout.panelFrame, LibretroRectMake(0, 345, 390, 499)), @"panel kept as is");
  rep.screens = @[ Screen(LibretroRectMake(0, 0, 0, 0), NO, @"full", NO) ];
  layout = [LibretroSkinLayout layoutRepresentation:rep viewSize:(LibretroSize){390, 844} safeInsets:insets overrides:nil];
  CHECK(RectNear(layout.screens[0].container, LibretroRectMake(0, 47, 390, 763)),
        @"generated screen without output frame uses the safe area");
}

/// DS-like generated skin: top screen, touch bottom screen, two buttons.
static LibretroSkinRepresentation *TouchRepresentation(void) {
  LibretroRect bottomScreen = LibretroRectMake(50, 300, 290, 218);
  LibretroSkinItem *a = Item(@"a", LibretroSkinItemKindButton, LibretroRectMake(300, 650, 60, 60), @[ @"a" ], 6, YES);
  LibretroSkinItem *fixed = Item(@"fixed", LibretroSkinItemKindButton, LibretroRectMake(20, 650, 60, 60), @[ @"b" ], 6, NO);
  LibretroSkinItem *touch = Item(@"touchScreen", LibretroSkinItemKindTouchScreen, bottomScreen, @[ @"touchScreen" ], 0, NO);
  LibretroSkinScreen *top = Screen(LibretroRectMake(50, 60, 290, 218), YES, @"top", NO);
  LibretroSkinScreen *bottom = Screen(bottomScreen, YES, @"bottom", YES);
  LibretroSkinRepresentation *rep =
      Representation(LibretroSkinOrientationPortrait, 390, 844, @[ a, fixed, touch ], @[ top, bottom ]);
  rep.generated = YES;
  return rep;
}

static void TestOverrides(void) {
  LibretroSkinRepresentation *rep = TouchRepresentation();
  LibretroSize view = {390, 844};
  NSDictionary *overrides = @{
    @"a" : @{@"dx" : @(-0.1), @"dy" : @(0.05), @"scale" : @1.5},
    @"fixed" : @{@"dx" : @0.2, @"dy" : @0, @"scale" : @1},
  };
  LibretroSkinLayoutResult *layout = [LibretroSkinLayout layoutRepresentation:rep
                                                                     viewSize:view
                                                                   safeInsets:kNoInsets
                                                                    overrides:overrides];
  LibretroRect expected = LibretroRectMake(330 - 45 - 39, 680 - 45 + 42.2, 90, 90);
  CHECK(RectNear(LaidOut(layout, @"a").frame, expected), @"move and scale around the centre %@ (expected %@)",
        Describe(LaidOut(layout, @"a").frame), Describe(expected));
  CHECK(RectNear(LaidOut(layout, @"a").hitFrame, LibretroRectMake(expected.x - 9, expected.y - 9, 108, 108)) &&
            RectNear(LaidOut(layout, @"a").assetFrame, expected),
        @"hit frame and image move with the frame");
  CHECK(RectNear(LaidOut(layout, @"fixed").frame, LibretroRectMake(20, 650, 60, 60)), @"non-movable items ignore overrides");

  layout = [LibretroSkinLayout layoutRepresentation:rep
                                           viewSize:view
                                         safeInsets:kNoInsets
                                          overrides:@{@"a" : @{@"scale" : @5}}];
  CHECK(RectNear(LaidOut(layout, @"a").frame, LibretroRectMake(270, 620, 120, 120)), @"scale clamped to 2.0 %@",
        Describe(LaidOut(layout, @"a").frame));
  layout = [LibretroSkinLayout layoutRepresentation:rep
                                           viewSize:view
                                         safeInsets:kNoInsets
                                          overrides:@{@"a" : @{@"scale" : @0.1, @"dx" : @"bad"}}];
  CHECK(RectNear(LaidOut(layout, @"a").frame, LibretroRectMake(315, 665, 30, 30)), @"scale clamped to 0.5, bad values ignored");

  // Overrides stored on a larger view keep the item inside a smaller one.
  layout = [LibretroSkinLayout layoutRepresentation:rep
                                           viewSize:view
                                         safeInsets:kNoInsets
                                          overrides:@{@"a" : @{@"dx" : @0.5, @"dy" : @0}}];
  CHECK(Inside(LaidOut(layout, @"a").frame, view) && RectNear(LaidOut(layout, @"a").frame, LibretroRectMake(330, 650, 60, 60)),
        @"layout keeps a moved item inside the view %@", Describe(LaidOut(layout, @"a").frame));
  layout = [LibretroSkinLayout layoutRepresentation:rep
                                           viewSize:view
                                         safeInsets:kNoInsets
                                          overrides:@{@"a" : @{@"dx" : @(-0.3), @"dy" : @(-0.3)}}];
  CHECK(!Overlaps(LaidOut(layout, @"a").frame, LibretroRectMake(50, 300, 290, 218)),
        @"layout never puts a moved item on the touch screen %@", Describe(LaidOut(layout, @"a").frame));
}

static void TestClamp(void) {
  LibretroSkinRepresentation *rep = TouchRepresentation();
  LibretroSize view = {390, 844};
  LibretroSkinItem *a = rep.items[0];
  LibretroRect bottomScreen = LibretroRectMake(50, 300, 290, 218);

  NSDictionary<NSString *, NSNumber *> *clamped = [LibretroSkinLayout clampOverride:@{@"dx" : @0, @"dy" : @0, @"scale" : @1}
                                                                            forItem:a
                                                                     representation:rep
                                                                           viewSize:view
                                                                         safeInsets:kNoInsets];
  CHECK(fabs(clamped[@"dx"].doubleValue) < 1e-9 && fabs(clamped[@"dy"].doubleValue) < 1e-9 &&
            fabs(clamped[@"scale"].doubleValue - 1) < 1e-9,
        @"a valid override is unchanged");

  clamped = [LibretroSkinLayout clampOverride:@{@"dx" : @0.5, @"dy" : @0.5, @"scale" : @1}
                                      forItem:a
                               representation:rep
                                     viewSize:view
                                   safeInsets:kNoInsets];
  LibretroRect moved = LibretroRectMake(300 + clamped[@"dx"].doubleValue * 390, 650 + clamped[@"dy"].doubleValue * 844, 60, 60);
  CHECK(Inside(moved, view) && fabs(moved.x - 330) < 1e-6 && fabs(moved.y - 784) < 1e-6,
        @"moved past the corner: kept inside the view %@", Describe(moved));

  // Dragged onto the touch screen: pushed out by the shortest way, with its
  // touch area (6-point edges) as well, so the frame stops 6 points below
  // the screen instead of touching it.
  NSDictionary<NSString *, NSNumber *> *dragged = [LibretroSkinLayout clampOverride:@{@"dx" : @(-100.0 / 390), @"dy" : @(-250.0 / 844), @"scale" : @1}
                                                                            forItem:a
                                                                     representation:rep
                                                                           viewSize:view
                                                                         safeInsets:kNoInsets];
  moved = LibretroRectMake(300 + dragged[@"dx"].doubleValue * 390, 650 + dragged[@"dy"].doubleValue * 844, 60, 60);
  CHECK(!Overlaps(moved, bottomScreen) && Inside(moved, view), @"dragged onto the touch screen: pushed off it %@",
        Describe(moved));
  CHECK(fabs(moved.y - 524) < 1e-6 && fabs(moved.x - 200) < 1e-6, @"pushed below it, the shortest way %@", Describe(moved));
  LibretroSkinLayoutResult *draggedLayout = [LibretroSkinLayout layoutRepresentation:rep
                                                                            viewSize:view
                                                                          safeInsets:kNoInsets
                                                                           overrides:@{@"a" : dragged}];
  LibretroRect hit = LaidOut(draggedLayout, @"a").hitFrame;
  CHECK(!Overlaps(hit, bottomScreen) && fabs(hit.y - 518) < 1e-6, @"its hit frame stops at the screen edge %@", Describe(hit));
  CHECK([Identifiers([LibretroSkinLayout itemsAtX:230 y:515 inLayout:draggedLayout]) isEqualToString:@"touchScreen"],
        @"3 points inside the touch screen next to the moved button: the touch screen");

  // Grown over the touch screen: moved away, size kept.
  clamped = [LibretroSkinLayout clampOverride:@{@"dx" : @0, @"dy" : @(-0.15), @"scale" : @2}
                                      forItem:a
                               representation:rep
                                     viewSize:view
                                   safeInsets:kNoInsets];
  double scale = clamped[@"scale"].doubleValue;
  moved = LibretroRectMake(330 - 30 * scale + clamped[@"dx"].doubleValue * 390, 680 - 30 * scale + clamped[@"dy"].doubleValue * 844,
                           60 * scale, 60 * scale);
  CHECK(fabs(scale - 2) < 1e-9 && !Overlaps(moved, bottomScreen) && Inside(moved, view),
        @"scaled item kept off the touch screen %@", Describe(moved));
  LibretroSkinLayoutResult *grownLayout = [LibretroSkinLayout layoutRepresentation:rep
                                                                          viewSize:view
                                                                        safeInsets:kNoInsets
                                                                         overrides:@{@"a" : clamped}];
  CHECK(!Overlaps(LaidOut(grownLayout, @"a").hitFrame, bottomScreen),
        @"its touch area, scaled with it (12-point edges), stays off the touch screen %@",
        Describe(LaidOut(grownLayout, @"a").hitFrame));

  LibretroSkinItem *fixed = rep.items[1];
  clamped = [LibretroSkinLayout clampOverride:@{@"dx" : @0.3, @"dy" : @0, @"scale" : @1.5}
                                      forItem:fixed
                               representation:rep
                                     viewSize:view
                                   safeInsets:kNoInsets];
  CHECK(clamped[@"dx"].doubleValue == 0 && clamped[@"dy"].doubleValue == 0 && clamped[@"scale"].doubleValue == 1,
        @"non-movable items get the neutral override");
}

static void TestHitTesting(void) {
  LibretroSkinItem *stick = Item(@"stick", LibretroSkinItemKindThumbstick, LibretroRectMake(0, 0, 100, 100),
                                 @[ @"leftStickUp", @"leftStickDown", @"leftStickLeft", @"leftStickRight" ], 0, YES);
  LibretroSkinItem *underStick = Item(@"under", LibretroSkinItemKindButton, LibretroRectMake(50, 50, 40, 40), @[ @"a" ], 0, YES);
  LibretroSkinItem *menu = Item(@"menu", LibretroSkinItemKindButton, LibretroRectMake(200, 0, 40, 40), @[ @"menu" ], 0, YES);
  LibretroSkinItem *underMenu = Item(@"underMenu", LibretroSkinItemKindButton, LibretroRectMake(220, 20, 40, 40), @[ @"b" ], 0, YES);
  LibretroSkinItem *x = Item(@"x", LibretroSkinItemKindButton, LibretroRectMake(300, 0, 40, 40), @[ @"x" ], 10, YES);
  LibretroSkinItem *y = Item(@"y", LibretroSkinItemKindButton, LibretroRectMake(350, 0, 40, 40), @[ @"y" ], 10, YES);
  LibretroSkinItem *dpad = Item(@"dpad", LibretroSkinItemKindDPad, LibretroRectMake(0, 200, 100, 100),
                                @[ @"up", @"down", @"left", @"right" ], 0, YES);
  LibretroSkinItem *touch = Item(@"touch", LibretroSkinItemKindTouchScreen, LibretroRectMake(0, 400, 300, 200),
                                 @[ @"touchScreen" ], 0, NO);
  LibretroSkinItem *overTouch = Item(@"fast", LibretroSkinItemKindButton, LibretroRectMake(0, 400, 50, 50),
                                     @[ @"toggleFastForward" ], 0, YES);
  LibretroSkinRepresentation *rep =
      Representation(LibretroSkinOrientationLandscape, 400, 600, @[ touch, overTouch, stick, underStick, menu, underMenu, x, y, dpad ], @[]);
  rep.generated = YES;
  LibretroSkinLayoutResult *layout = [LibretroSkinLayout layoutRepresentation:rep
                                                                     viewSize:(LibretroSize){400, 600}
                                                                   safeInsets:kNoInsets
                                                                    overrides:nil];
  CHECK([Identifiers([LibretroSkinLayout itemsAtX:60 y:60 inLayout:layout]) isEqualToString:@"stick"],
        @"a thumbstick wins alone over a button under it");
  CHECK([Identifiers([LibretroSkinLayout itemsAtX:230 y:30 inLayout:layout]) isEqualToString:@"menu"],
        @"menu is exclusive");
  CHECK([Identifiers([LibretroSkinLayout itemsAtX:250 y:50 inLayout:layout]) isEqualToString:@"underMenu"],
        @"outside the menu the other button fires");
  CHECK([Identifiers([LibretroSkinLayout itemsAtX:345 y:20 inLayout:layout]) isEqualToString:@"x,y"],
        @"extended edges overlapping between two buttons press both");
  CHECK([Identifiers([LibretroSkinLayout itemsAtX:50 y:250 inLayout:layout]) isEqualToString:@"dpad"], @"D-pad hit");
  CHECK([Identifiers([LibretroSkinLayout itemsAtX:20 y:420 inLayout:layout]) isEqualToString:@"fast"],
        @"a button over the touch screen wins");
  CHECK([Identifiers([LibretroSkinLayout itemsAtX:150 y:500 inLayout:layout]) isEqualToString:@"touch"],
        @"the touch screen only when nothing else is hit");
  CHECK([LibretroSkinLayout itemsAtX:390 y:300 inLayout:layout].count == 0, @"empty area hits nothing");
}

/// DS-like generated skin with a D-pad (12-point touch edges) below the
/// touch bottom screen.
static LibretroSkinRepresentation *DPadRepresentation(void) {
  LibretroRect bottomScreen = LibretroRectMake(50, 300, 290, 218);
  LibretroSkinItem *dpad = Item(@"dpad", LibretroSkinItemKindDPad, LibretroRectMake(20, 600, 120, 120),
                                @[ @"up", @"down", @"left", @"right" ], 12, YES);
  LibretroSkinItem *touch = Item(@"touchScreen", LibretroSkinItemKindTouchScreen, bottomScreen, @[ @"touchScreen" ], 0, NO);
  LibretroSkinRepresentation *rep =
      Representation(LibretroSkinOrientationPortrait, 390, 844, @[ dpad, touch ],
                     @[ Screen(LibretroRectMake(50, 60, 290, 218), YES, @"top", NO), Screen(bottomScreen, YES, @"bottom", YES) ]);
  rep.generated = YES;
  return rep;
}

static void TestDPadAgainstTouchScreen(void) {
  LibretroSkinRepresentation *rep = DPadRepresentation();
  LibretroSize view = {390, 844};
  LibretroRect bottomScreen = LibretroRectMake(50, 300, 290, 218);
  LibretroSkinItem *dpad = rep.items[0];
  // Dragged up onto the bottom screen: pushed back below it with its whole
  // touch area, the shortest way.
  BOOL fitted = NO;
  NSDictionary<NSString *, NSNumber *> *clamped = [LibretroSkinLayout clampOverride:@{@"dx" : @0.1, @"dy" : @(-0.2), @"scale" : @1}
                                                                           previous:nil
                                                                            forItem:dpad
                                                                     representation:rep
                                                                           viewSize:view
                                                                         safeInsets:kNoInsets
                                                                             fitted:&fitted];
  LibretroSkinLayoutResult *layout = [LibretroSkinLayout layoutRepresentation:rep
                                                                     viewSize:view
                                                                   safeInsets:kNoInsets
                                                                    overrides:@{@"dpad" : clamped}];
  LibretroLaidOutItem *moved = LaidOut(layout, @"dpad");
  CHECK(fitted && RectNear(moved.frame, LibretroRectMake(59, 530, 120, 120)),
        @"D-pad dragged onto the touch screen stops 12 points below it %@", Describe(moved.frame));
  CHECK(!Overlaps(moved.hitFrame, bottomScreen) && fabs(moved.hitFrame.y - 518) < 1e-6,
        @"its hit frame never covers the touch screen %@", Describe(moved.hitFrame));
  BOOL onlyTouch = YES;
  for (int x = 53; x <= 337; x += 4) {
    NSString *hits = Identifiers([LibretroSkinLayout itemsAtX:(double)x y:513 inLayout:layout]);
    if (![hits isEqualToString:@"touchScreen"]) onlyTouch = NO;
  }
  CHECK(onlyTouch, @"5 points inside the touch screen, along the moved D-pad: always the touch screen");

  // Pinched to 2x near the screen: the grown touch area stays off it too.
  clamped = [LibretroSkinLayout clampOverride:@{@"dx" : @0.1, @"dy" : @(-0.1), @"scale" : @2}
                                     previous:nil
                                      forItem:dpad
                               representation:rep
                                     viewSize:view
                                   safeInsets:kNoInsets
                                       fitted:&fitted];
  layout = [LibretroSkinLayout layoutRepresentation:rep viewSize:view safeInsets:kNoInsets overrides:@{@"dpad" : clamped}];
  moved = LaidOut(layout, @"dpad");
  CHECK(fitted && fabs(clamped[@"scale"].doubleValue - 2) < 1e-9 && !Overlaps(moved.hitFrame, bottomScreen) &&
            Inside(moved.frame, view),
        @"a D-pad pinched to 2x keeps its touch area off the touch screen %@", Describe(moved.hitFrame));

  // An imported skin whose own extended edges already reach the touch
  // screen: only the frame is kept off it, a small move does not jump.
  LibretroSkinItem *wide = Item(@"wide", LibretroSkinItemKindButton, LibretroRectMake(100, 530, 60, 60), @[ @"a" ], 20, YES);
  LibretroSkinItem *touch = rep.items[1];
  LibretroSkinRepresentation *imported =
      Representation(LibretroSkinOrientationPortrait, 390, 844, @[ wide, touch ], @[ Screen(bottomScreen, YES, @"bottom", YES) ]);
  imported.generated = YES;
  clamped = [LibretroSkinLayout clampOverride:@{@"dx" : @(10.0 / 390), @"dy" : @0, @"scale" : @1}
                                     previous:nil
                                      forItem:wide
                               representation:imported
                                     viewSize:view
                                   safeInsets:kNoInsets
                                       fitted:&fitted];
  CHECK(fitted && fabs(clamped[@"dx"].doubleValue * 390 - 10) < 1e-6 && fabs(clamped[@"dy"].doubleValue) < 1e-9,
        @"designed extended edges over the touch screen: a small move is kept as is");
  layout = [LibretroSkinLayout layoutRepresentation:imported viewSize:view safeInsets:kNoInsets overrides:nil];
  CHECK([Identifiers([LibretroSkinLayout itemsAtX:130 y:515 inLayout:layout]) isEqualToString:@"touchScreen"] &&
            [Identifiers([LibretroSkinLayout itemsAtX:130 y:525 inLayout:layout]) isEqualToString:@"wide"] &&
            [Identifiers([LibretroSkinLayout itemsAtX:130 y:535 inLayout:layout]) isEqualToString:@"wide"],
        @"on the touch screen the extended edges give way; outside it they still work");
}

static void TestTouchScreenPriority(void) {
  // A container larger than the drawn picture (letterboxed touch screen),
  // a button whose extended edges reach into it, a stick next to it.
  LibretroSkinItem *button = Item(@"b", LibretroSkinItemKindButton, LibretroRectMake(10, 100, 60, 60), @[ @"b" ], 20, YES);
  LibretroSkinItem *stick = Item(@"stick", LibretroSkinItemKindThumbstick, LibretroRectMake(330, 100, 60, 60),
                                 @[ @"leftStickUp", @"leftStickDown", @"leftStickLeft", @"leftStickRight" ], 20, YES);
  LibretroSkinScreen *screen = Screen(LibretroRectMake(80, 0, 240, 300), YES, @"full", YES);
  LibretroSkinRepresentation *rep = Representation(LibretroSkinOrientationLandscape, 400, 300, @[ button, stick ], @[ screen ]);
  rep.generated = YES;
  LibretroSkinLayoutResult *layout = [LibretroSkinLayout layoutRepresentation:rep
                                                                     viewSize:(LibretroSize){400, 300}
                                                                   safeInsets:kNoInsets
                                                                    overrides:nil];
  CHECK([LibretroSkinLayout itemsAtX:85 y:130 inLayout:layout].count == 0,
        @"on the touch-screen container, outside the button frame: no control");
  CHECK([LibretroSkinLayout itemsAtX:315 y:130 inLayout:layout].count == 0,
        @"on the touch-screen container, outside the stick frame: no stick");
  CHECK([Identifiers([LibretroSkinLayout itemsAtX:75 y:130 inLayout:layout]) isEqualToString:@"b"] &&
            [Identifiers([LibretroSkinLayout itemsAtX:325 y:130 inLayout:layout]) isEqualToString:@"stick"],
        @"outside the touch screen the extended edges work");
  // The picture is really drawn in the middle only (presenter mapping).
  LibretroRect drawn = LibretroRectMake(120, 0, 160, 300);
  NSArray<NSValue *> *areas = @[ [NSValue valueWithBytes:&drawn objCType:@encode(LibretroRect)] ];
  CHECK([Identifiers([LibretroSkinLayout itemsAtX:85 y:130 inLayout:layout touchAreas:areas]) isEqualToString:@"b"] &&
            [Identifiers([LibretroSkinLayout itemsAtX:315 y:130 inLayout:layout touchAreas:areas]) isEqualToString:@"stick"],
        @"beside the drawn picture (letterbox) the extended edges work");
  CHECK([LibretroSkinLayout itemsAtX:150 y:130 inLayout:layout touchAreas:areas].count == 0,
        @"on the drawn picture no control answers");
  CHECK([Identifiers([LibretroSkinLayout itemsAtX:85 y:130 inLayout:layout touchAreas:@[]]) isEqualToString:@"b"],
        @"no drawn touch screen at all: extended edges everywhere");
  CHECK([Identifiers([LibretroSkinLayout itemsAtX:85 y:130 inLayout:layout]) isEqualToString:@""] &&
            [Identifiers([LibretroSkinLayout itemsAtX:85 y:130 inLayout:layout touchAreas:nil]) isEqualToString:@""],
        @"nil areas: the layout's containers");
}

static void TestClampKeepsPrevious(void) {
  // A narrow column (100 points) beside a full-height touch screen.
  LibretroSkinItem *a = Item(@"a", LibretroSkinItemKindButton, LibretroRectMake(20, 120, 60, 60), @[ @"a" ], 6, YES);
  LibretroSkinRepresentation *rep =
      Representation(LibretroSkinOrientationLandscape, 400, 300, @[ a ],
                     @[ Screen(LibretroRectMake(100, 0, 200, 300), YES, @"bottom", YES) ]);
  rep.generated = YES;
  LibretroSize view = {400, 300};
  NSDictionary<NSString *, NSNumber *> *previous = @{@"dx" : @0, @"dy" : @0.1, @"scale" : @1.2};
  BOOL fitted = NO;
  NSDictionary<NSString *, NSNumber *> *result = [LibretroSkinLayout clampOverride:@{@"dx" : @0, @"dy" : @0.1, @"scale" : @1.3}
                                                                          previous:previous
                                                                           forItem:a
                                                                    representation:rep
                                                                          viewSize:view
                                                                        safeInsets:kNoInsets
                                                                            fitted:&fitted];
  CHECK(fitted && fabs(result[@"scale"].doubleValue - 1.3) < 1e-9 && fabs(result[@"dy"].doubleValue - 0.1) < 1e-9 &&
            fabs(result[@"dx"].doubleValue) < 1e-9,
        @"a pinch that fits is kept");
  // Pinched to 2x: 120 points never fit in the 100-point column.
  fitted = YES;
  result = [LibretroSkinLayout clampOverride:@{@"dx" : @0, @"dy" : @0.1, @"scale" : @2}
                                    previous:previous
                                     forItem:a
                              representation:rep
                                    viewSize:view
                                  safeInsets:kNoInsets
                                      fitted:&fitted];
  CHECK(!fitted, @"a pinch that cannot fit is reported");
  CHECK(fabs(result[@"scale"].doubleValue - 1.2) < 1e-9 && fabs(result[@"dy"].doubleValue - 0.1) < 1e-9 &&
            fabs(result[@"dx"].doubleValue) < 1e-9,
        @"the last valid move and size are kept, not the original place");
  result = [LibretroSkinLayout clampOverride:@{@"dx" : @0, @"dy" : @0.1, @"scale" : @2}
                                    previous:@{@"dx" : @0, @"dy" : @0, @"scale" : @2}
                                     forItem:a
                              representation:rep
                                    viewSize:view
                                  safeInsets:kNoInsets
                                      fitted:NULL];
  CHECK(fabs(result[@"scale"].doubleValue - 1) < 1e-9 && fabs(result[@"dx"].doubleValue) < 1e-9 &&
            fabs(result[@"dy"].doubleValue) < 1e-9,
        @"a previous value that no longer fits gives the original place");
  result = [LibretroSkinLayout clampOverride:@{@"dx" : @0, @"dy" : @0.1, @"scale" : @2}
                                     forItem:a
                              representation:rep
                                    viewSize:view
                                  safeInsets:kNoInsets];
  CHECK(fabs(result[@"scale"].doubleValue - 1) < 1e-9 && fabs(result[@"dy"].doubleValue) < 1e-9,
        @"without a previous value (stored layouts): the original place");
}

static void TestKnob(void) {
  LibretroSkinItem *stick = Item(@"stick", LibretroSkinItemKindThumbstick, LibretroRectMake(100, 100, 80, 80),
                                 @[ @"leftStickUp", @"leftStickDown", @"leftStickLeft", @"leftStickRight" ], 0, YES);
  stick.thumbstickSize = (LibretroSize){40, 40};
  LibretroSkinRepresentation *rep = Representation(LibretroSkinOrientationLandscape, 400, 300, @[ stick ], @[]);
  rep.generated = YES;
  LibretroSkinLayoutResult *layout = [LibretroSkinLayout layoutRepresentation:rep
                                                                     viewSize:(LibretroSize){400, 300}
                                                                   safeInsets:kNoInsets
                                                                    overrides:nil];
  LibretroLaidOutItem *laidOut = LaidOut(layout, @"stick");
  CHECK(RectNear([LibretroSkinLayout knobFrameForItem:laidOut stickX:0 stickY:0], LibretroRectMake(120, 120, 40, 40)),
        @"released stick: knob centred");
  CHECK(RectNear([LibretroSkinLayout knobFrameForItem:laidOut stickX:1 stickY:0], LibretroRectMake(140, 120, 40, 40)) &&
            RectNear([LibretroSkinLayout knobFrameForItem:laidOut stickX:-1 stickY:-1], LibretroRectMake(100, 100, 40, 40)),
        @"full deflection: the knob reaches the edge of the stick");
  CHECK(RectNear([LibretroSkinLayout knobFrameForItem:laidOut stickX:0.5 stickY:0.25], LibretroRectMake(130, 125, 40, 40)),
        @"partial deflection: proportional");
  CHECK(RectNear([LibretroSkinLayout knobFrameForItem:laidOut stickX:3 stickY:NAN], LibretroRectMake(140, 120, 40, 40)),
        @"vectors clamped, invalid values centred");
  layout = [LibretroSkinLayout layoutRepresentation:rep
                                           viewSize:(LibretroSize){400, 300}
                                         safeInsets:kNoInsets
                                          overrides:@{@"stick" : @{@"scale" : @1.5}}];
  laidOut = LaidOut(layout, @"stick");
  CHECK(RectNear([LibretroSkinLayout knobFrameForItem:laidOut stickX:0 stickY:1], LibretroRectMake(110, 140, 60, 60)),
        @"a resized stick scales its knob and its travel %@",
        Describe([LibretroSkinLayout knobFrameForItem:laidOut stickX:0 stickY:1]));
  stick.thumbstickSize = (LibretroSize){0, 0};
  layout = [LibretroSkinLayout layoutRepresentation:rep viewSize:(LibretroSize){400, 300} safeInsets:kNoInsets overrides:nil];
  CHECK(RectNear([LibretroSkinLayout knobFrameForItem:LaidOut(layout, @"stick") stickX:1 stickY:0],
                 LibretroRectMake(140, 120, 40, 40)),
        @"no knob size: half the stick");
  stick.thumbstickSize = (LibretroSize){80, 80};
  layout = [LibretroSkinLayout layoutRepresentation:rep viewSize:(LibretroSize){400, 300} safeInsets:kNoInsets overrides:nil];
  CHECK(RectNear([LibretroSkinLayout knobFrameForItem:LaidOut(layout, @"stick") stickX:1 stickY:0],
                 LibretroRectMake(120, 100, 80, 80)),
        @"a knob as large as the stick still moves (a quarter of it)");
}

static NSValue *MappingValue(LibretroRect output, LibretroRect source) {
  LibretroScreenMapping mapping;
  memset(&mapping, 0, sizeof(mapping));
  mapping.output = output;
  mapping.source = source;
  mapping.rotation = 0;
  return [NSValue valueWithBytes:&mapping objCType:@encode(LibretroScreenMapping)];
}

static void TestPointerMapping(void) {
  LibretroRect bottomSource = LibretroRectMake(0, 0.5, 1, 0.5);
  LibretroScreenMapping held;
  memset(&held, 0, sizeof(held));
  held.output = LibretroRectMake(50, 300, 290, 218);
  held.source = bottomSource;
  LibretroScreenMapping result;
  memset(&result, 0, sizeof(result));
  NSArray<NSValue *> *same = @[ MappingValue(LibretroRectMake(50, 300, 290, 218), bottomSource) ];
  CHECK([LibretroSkinLayout resolvePointerMapping:held atX:345 y:400 mappings:same result:&result] &&
            RectNear(result.output, held.output),
        @"screen still drawn at the same place: the held stylus keeps it (even past its edge)");
  // Screens swapped: the touch screen is now drawn in the upper place.
  NSArray<NSValue *> *swapped = @[ MappingValue(LibretroRectMake(50, 60, 290, 218), bottomSource) ];
  CHECK(![LibretroSkinLayout resolvePointerMapping:held atX:200 y:400 mappings:swapped result:&result],
        @"swapped under the finger, which is now on the top screen: released");
  CHECK([LibretroSkinLayout resolvePointerMapping:held atX:200 y:100 mappings:swapped result:&result] &&
            RectNear(result.output, LibretroRectMake(50, 60, 290, 218)),
        @"a finger that is on the touch screen's new place follows it");
  int16_t x = 0, y = 0;
  CHECK(LibretroPointerFromPoint(result, 195, 169, NO, &x, &y) && x == 0 && y > 0,
        @"and is converted with the new rectangle (%d, %d)", x, y);
  LibretroRect odd = LibretroRectMake(0, 0, 1000, 1000);
  NSArray *junk = @[ [NSValue valueWithBytes:&odd objCType:@encode(LibretroRect)], @"x" ];
  CHECK(![LibretroSkinLayout resolvePointerMapping:held atX:200 y:400 mappings:junk result:&result] &&
            ![LibretroSkinLayout resolvePointerMapping:held atX:200 y:400 mappings:@[] result:&result],
        @"no touch screen any more (or values that are not mappings): released");
}

int main(int argc, const char *argv[]) {
  @autoreleasepool {
    TestPortraitPinned();
    TestAspectFit();
    TestGenerated();
    TestOverrides();
    TestClamp();
    TestHitTesting();
    TestDPadAgainstTouchScreen();
    TestTouchScreenPriority();
    TestClampKeepsPrevious();
    TestKnob();
    TestPointerMapping();
  }
  printf("%s: %d failure(s)\n", failures == 0 ? "skin_layout_test passed" : "skin_layout_test FAILED", failures);
  return failures == 0 ? 0 : 1;
}
