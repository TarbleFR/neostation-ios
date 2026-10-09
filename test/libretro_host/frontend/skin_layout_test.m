// Behavioural test of LibretroSkinLayout: Delta placement of imported skins
// (portrait pinned to the bottom, aspect fit otherwise, screens scaled from
// the mapping, app placement), generated skins kept as is, user overrides
// on movable items, clamping inside the view and off the DS / 3DS touch
// screen, and the hit-test priorities (thumbstick, exclusive menu, buttons,
// touch screen last).
#import <Foundation/Foundation.h>

#import "LibretroSkin.h"
#import "LibretroSkinLayout.h"

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

  // Dragged onto the touch screen: pushed out by the shortest way.
  clamped = [LibretroSkinLayout clampOverride:@{@"dx" : @(-100.0 / 390), @"dy" : @(-250.0 / 844), @"scale" : @1}
                                      forItem:a
                               representation:rep
                                     viewSize:view
                                   safeInsets:kNoInsets];
  moved = LibretroRectMake(300 + clamped[@"dx"].doubleValue * 390, 650 + clamped[@"dy"].doubleValue * 844, 60, 60);
  CHECK(!Overlaps(moved, bottomScreen) && Inside(moved, view), @"dragged onto the touch screen: pushed off it %@",
        Describe(moved));
  CHECK(fabs(moved.y - 518) < 1e-6 && fabs(moved.x - 200) < 1e-6, @"pushed below it, the shortest way %@", Describe(moved));

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

int main(int argc, const char *argv[]) {
  @autoreleasepool {
    TestPortraitPinned();
    TestAspectFit();
    TestGenerated();
    TestOverrides();
    TestClamp();
    TestHitTesting();
  }
  printf("%s: %d failure(s)\n", failures == 0 ? "skin_layout_test passed" : "skin_layout_test FAILED", failures);
  return failures == 0 ? 0 : 1;
}
