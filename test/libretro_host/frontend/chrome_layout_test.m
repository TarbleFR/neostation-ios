// Behavioural test of LibretroChromeLayout.
//
// Menu button: for the 17 consoles' default skins, both orientations,
// iPhone SE to iPad Pro 13 and resizable iPad windows, with and without
// safe areas, every DS / 3DS screen arrangement, swapped or not, controls
// shown or hidden (controller connected): the button stays inside the safe
// area, never comes near a touch screen (laid-out touch-screen container or
// touch-screen item), never covers a shown control's touch area, and keeps
// its usual place whenever that place is free (always for single-screen
// consoles). Synthetic layouts check the rules behind it.
//
// Controls editor: at console scope the editor starts from the console's
// own layout (never the game's), so saving there keeps the console's other
// entries; at game scope it starts from the layout in effect; "Reset"
// comes back to the same source.
#import <Foundation/Foundation.h>

#import "LibretroChromeLayout.h"
#import "LibretroDefaultSkins.h"
#import "LibretroFrontendStore.h"
#import "LibretroSkinLayout.h"

#include <math.h>
#include <stdio.h>

static int failures = 0;
static int printedFailures = 0;

static void Report(BOOL passed, NSString *message, int line) {
  if (passed) {
    printf("PASS %s\n", message.UTF8String);
  } else {
    printf("FAIL %s (%s:%d)\n", message.UTF8String, __FILE__, line);
    failures++;
  }
}

#define CHECK(condition, ...) Report((condition) ? YES : NO, [NSString stringWithFormat:__VA_ARGS__], __LINE__)

/// One failed invariant of one layout (printed up to a limit).
static void Fail(NSString *tag, NSString *message) {
  failures++;
  if (printedFailures++ < 300) printf("FAIL %s: %s\n", tag.UTF8String, message.UTF8String);
}

static const double kTolerance = 0.01;

/// YES when `a`, grown by `margin` on every side, overlaps `b`.
static BOOL Near(LibretroRect a, LibretroRect b, double margin) {
  double width = MIN(a.x + a.w, b.x + b.w) - MAX(a.x, b.x) + margin;
  double height = MIN(a.y + a.h, b.y + b.h) - MAX(a.y, b.y) + margin;
  return width > kTolerance && height > kTolerance;
}

static BOOL Inside(LibretroRect inner, LibretroRect outer) {
  return inner.x >= outer.x - kTolerance && inner.y >= outer.y - kTolerance &&
         inner.x + inner.w <= outer.x + outer.w + kTolerance && inner.y + inner.h <= outer.y + outer.h + kTolerance;
}

static BOOL Same(LibretroRect a, LibretroRect b) {
  return LibretroRectEqualToRect(a, b, 1e-9);
}

static NSString *Describe(LibretroRect rect) {
  return [NSString stringWithFormat:@"{%.1f, %.1f, %.1f, %.1f}", rect.x, rect.y, rect.w, rect.h];
}

static LibretroInsets Insets(double top, double left, double bottom, double right) {
  LibretroInsets insets = {top, left, bottom, right};
  return insets;
}

/// A device in portrait with its portrait and landscape safe areas.
typedef struct {
  double width;
  double height;
  LibretroInsets portrait;
  LibretroInsets landscape;
  BOOL iPad;
} Device;

static Device MakeDevice(double width, double height, LibretroInsets portrait, LibretroInsets landscape, BOOL iPad) {
  Device device = {width, height, portrait, landscape, iPad};
  return device;
}

static NSArray<NSValue *> *Devices(void) {
  LibretroInsets tablet = Insets(24, 0, 20, 0);
  Device devices[] = {
      MakeDevice(320, 568, Insets(20, 0, 0, 0), Insets(0, 0, 0, 0), NO),     // iPhone SE (1st)
      MakeDevice(375, 667, Insets(20, 0, 0, 0), Insets(0, 0, 0, 0), NO),     // iPhone SE (3rd)
      MakeDevice(390, 844, Insets(47, 0, 34, 0), Insets(0, 47, 21, 47), NO),  // iPhone 13 / 14
      MakeDevice(393, 852, Insets(59, 0, 34, 0), Insets(0, 59, 21, 59), NO),  // iPhone 15 / 16
      MakeDevice(430, 932, Insets(59, 0, 34, 0), Insets(0, 59, 21, 59), NO),  // iPhone 15 Plus
      MakeDevice(440, 956, Insets(62, 0, 34, 0), Insets(0, 62, 21, 62), NO),  // iPhone 16 Pro Max
      MakeDevice(744, 1133, tablet, tablet, YES),                             // iPad mini
      MakeDevice(820, 1180, tablet, tablet, YES),                             // iPad Air 11
      MakeDevice(1032, 1376, tablet, tablet, YES),                            // iPad Pro 13
      MakeDevice(700, 900, tablet, tablet, YES),                              // resizable window
      MakeDevice(507, 700, tablet, tablet, YES),                              // narrow window
  };
  NSMutableArray<NSValue *> *values = [NSMutableArray array];
  for (size_t index = 0; index < sizeof(devices) / sizeof(devices[0]); index++) {
    [values addObject:[NSValue valueWithBytes:&devices[index] objCType:@encode(Device)]];
  }
  return values;
}

/// Checks the menu button over one laid-out default skin. Returns the frame.
static LibretroRect CheckMenuButton(NSString *console, LibretroSkinLayoutResult *layout, LibretroSize view,
                                    LibretroInsets insets, BOOL controlsVisible, NSString *tag) {
  LibretroRect frame = [LibretroChromeLayout menuButtonFrameForLayout:layout
                                                             viewSize:view
                                                           safeInsets:insets
                                                      controlsVisible:controlsVisible];
  LibretroRect preferred = [LibretroChromeLayout preferredMenuButtonFrameForViewSize:view safeInsets:insets];
  LibretroRect safeArea =
      LibretroRectMake(insets.left, insets.top, view.w - insets.left - insets.right, view.h - insets.top - insets.bottom);
  // Same clearance and rounding tolerance as the rule itself.
  double clearance = LibretroMenuButtonClearance;
  if (fabs(frame.w - LibretroMenuButtonSize.w) > 1e-9 || fabs(frame.h - LibretroMenuButtonSize.h) > 1e-9) {
    Fail(tag, [@"menu button resized " stringByAppendingString:Describe(frame)]);
  }
  if (!Inside(frame, safeArea)) Fail(tag, [@"menu button outside the safe area " stringByAppendingString:Describe(frame)]);

  BOOL preferredFree = YES;
  for (LibretroLaidOutScreen *screen in layout.screens) {
    if (!screen.touchScreen) continue;
    if (Near(frame, screen.container, clearance)) {
      Fail(tag, [NSString stringWithFormat:@"menu button %@ on the touch screen %@", Describe(frame),
                                           Describe(screen.container)]);
    }
    if (Near(preferred, screen.container, clearance)) preferredFree = NO;
  }
  for (LibretroLaidOutItem *laidOut in layout.items) {
    BOOL touch = laidOut.item.kind == LibretroSkinItemKindTouchScreen;
    if (!touch && !controlsVisible) continue;
    LibretroRect area = touch ? laidOut.frame : laidOut.hitFrame;
    if (Near(frame, area, clearance)) {
      Fail(tag, [NSString stringWithFormat:@"menu button %@ over %@ %@", Describe(frame), laidOut.item.identifier,
                                           Describe(area)]);
    }
    if (Near(preferred, area, clearance)) preferredFree = NO;
  }
  if (preferredFree && !Same(frame, preferred)) {
    Fail(tag, [NSString stringWithFormat:@"menu button moved to %@ although %@ is free", Describe(frame),
                                         Describe(preferred)]);
  }
  if (![LibretroDefaultSkins isDualScreenConsole:console] && !Same(frame, preferred)) {
    Fail(tag, [NSString stringWithFormat:@"single-screen console: menu button moved to %@", Describe(frame)]);
  }
  return frame;
}

static void TestDefaultSkins(void) {
  NSArray<NSValue *> *devices = Devices();
  for (NSString *console in [LibretroDefaultSkins consoles]) {
    int before = failures;
    int layouts = 0;
    int moved = 0;
    BOOL dual = [LibretroDefaultSkins isDualScreenConsole:console];
    for (NSValue *value in devices) {
      Device device;
      [value getValue:&device size:sizeof(device)];
      for (int rotated = 0; rotated < 2; rotated++) {
        double width = rotated ? device.height : device.width;
        double height = rotated ? device.width : device.height;
        LibretroSkinOrientation orientation =
            width > height ? LibretroSkinOrientationLandscape : LibretroSkinOrientationPortrait;
        LibretroSize view = {width, height};
        for (int real = 0; real < 2; real++) {
          LibretroInsets insets = real == 0 ? Insets(0, 0, 0, 0) : (rotated ? device.landscape : device.portrait);
          NSMutableArray *arrangements =
              [[LibretroDefaultSkins arrangementsForConsole:console orientation:orientation] mutableCopy];
          [arrangements addObject:[NSNull null]];  // the default one
          for (id arrangement in arrangements) {
            NSString *name = [arrangement isKindOfClass:[NSString class]] ? arrangement : nil;
            for (int swapped = 0; swapped < (dual ? 2 : 1); swapped++) {
              LibretroSkinRepresentation *rep = [LibretroDefaultSkins representationForConsole:console
                                                                                   orientation:orientation
                                                                                      viewSize:view
                                                                                    safeInsets:insets
                                                                                          iPad:device.iPad
                                                                                   arrangement:name
                                                                                       swapped:swapped == 1
                                                                                       regions:nil];
              LibretroSkinLayoutResult *layout = [LibretroSkinLayout layoutRepresentation:rep
                                                                                 viewSize:view
                                                                               safeInsets:insets
                                                                                overrides:nil];
              for (int visible = 0; visible < 2; visible++) {
                NSString *tag = [NSString stringWithFormat:@"%@ %@ %gx%g insets=%d %@%@ controls=%@", console,
                                                           LibretroSkinOrientationName(orientation), width, height,
                                                           real, name ?: @"default", swapped ? @" swapped" : @"",
                                                           visible ? @"shown" : @"hidden"];
                LibretroRect frame = CheckMenuButton(console, layout, view, insets, visible == 1, tag);
                LibretroRect preferred = [LibretroChromeLayout preferredMenuButtonFrameForViewSize:view
                                                                                         safeInsets:insets];
                if (!Same(frame, preferred)) moved++;
                layouts++;
              }
            }
          }
        }
      }
    }
    CHECK(failures == before, @"%@: menu button clear of the touch screen and the controls in %d layouts (%d moved)",
          console, layouts, moved);
    if (dual) CHECK(moved > 0, @"%@: some arrangements need another place for the menu button", console);
  }
}

static LibretroSkinLayoutResult *DefaultLayout(NSString *console, LibretroSkinOrientation orientation, LibretroSize view,
                                               LibretroInsets insets, NSString *arrangement, BOOL swapped) {
  LibretroSkinRepresentation *rep = [LibretroDefaultSkins representationForConsole:console
                                                                       orientation:orientation
                                                                          viewSize:view
                                                                        safeInsets:insets
                                                                              iPad:NO
                                                                       arrangement:arrangement
                                                                           swapped:swapped
                                                                           regions:nil];
  return [LibretroSkinLayout layoutRepresentation:rep viewSize:view safeInsets:insets overrides:nil];
}

static LibretroRect TouchContainer(LibretroSkinLayoutResult *layout) {
  for (LibretroLaidOutScreen *screen in layout.screens) {
    if (screen.touchScreen) return screen.container;
  }
  return LibretroRectMake(0, 0, 0, 0);
}

/// The cases found by the review, on an iPhone 15 and an iPhone 13.
static void TestReportedCases(void) {
  LibretroSize portrait = {393, 852};
  LibretroInsets portraitInsets = Insets(59, 0, 34, 0);
  LibretroRect preferred = [LibretroChromeLayout preferredMenuButtonFrameForViewSize:portrait
                                                                          safeInsets:portraitInsets];
  CHECK(Same(preferred, LibretroRectMake(339, 65, 44, 40)), @"portrait: usual place at the top right %@",
        Describe(preferred));

  LibretroSkinLayoutResult *bottomOnly = DefaultLayout(@"nds", LibretroSkinOrientationPortrait, portrait, portraitInsets,
                                                       LibretroArrangementBottomOnly, NO);
  LibretroRect touch = TouchContainer(bottomOnly);
  LibretroRect frame = [LibretroChromeLayout menuButtonFrameForLayout:bottomOnly
                                                             viewSize:portrait
                                                           safeInsets:portraitInsets
                                                      controlsVisible:YES];
  CHECK(Near(preferred, touch, 0) && !Near(frame, touch, 5.999) && frame.y >= touch.y + touch.h + 5.999,
        @"DS bottom screen only: the button leaves the touch screen %@ for %@", Describe(touch), Describe(frame));

  LibretroSkinLayoutResult *stacked = DefaultLayout(@"nds", LibretroSkinOrientationPortrait, portrait, portraitInsets,
                                                    LibretroArrangementStacked, NO);
  frame = [LibretroChromeLayout menuButtonFrameForLayout:stacked
                                                viewSize:portrait
                                              safeInsets:portraitInsets
                                         controlsVisible:YES];
  CHECK(Same(frame, preferred), @"DS stacked: the top screen is not a touch screen, the button stays %@",
        Describe(frame));

  LibretroSkinLayoutResult *swapped = DefaultLayout(@"nds", LibretroSkinOrientationPortrait, portrait, portraitInsets,
                                                    LibretroArrangementStacked, YES);
  frame = [LibretroChromeLayout menuButtonFrameForLayout:swapped
                                                viewSize:portrait
                                              safeInsets:portraitInsets
                                         controlsVisible:YES];
  CHECK(!Near(frame, TouchContainer(swapped), 5.999), @"DS stacked and swapped: %@ clear of %@", Describe(frame),
        Describe(TouchContainer(swapped)));

  LibretroSize landscape = {844, 390};
  LibretroInsets landscapeInsets = Insets(0, 47, 21, 47);
  LibretroRect top = [LibretroChromeLayout preferredMenuButtonFrameForViewSize:landscape safeInsets:landscapeInsets];
  CHECK(Same(top, LibretroRectMake(400, 6, 44, 40)), @"landscape: usual place at the top centre %@", Describe(top));
  NSArray *cases = @[
    @[ @"nds", LibretroArrangementStacked ], @[ @"3ds", LibretroArrangementLargeTop ],
    @[ @"3ds", LibretroArrangementStacked ]
  ];
  for (NSArray *entry in cases) {
    LibretroSkinLayoutResult *layout =
        DefaultLayout(entry[0], LibretroSkinOrientationLandscape, landscape, landscapeInsets, entry[1], YES);
    LibretroRect screen = TouchContainer(layout);
    frame = [LibretroChromeLayout menuButtonFrameForLayout:layout
                                                  viewSize:landscape
                                                safeInsets:landscapeInsets
                                           controlsVisible:YES];
    CHECK(Near(top, screen, 0) && !Near(frame, screen, 5.999),
          @"%@ %@ swapped in landscape: the touch screen %@ starts at the top, the button goes to %@", entry[0],
          entry[1], Describe(screen), Describe(frame));
  }
}

static LibretroLaidOutItem *Item(NSString *identifier, LibretroSkinItemKind kind, LibretroRect frame, LibretroRect hit) {
  LibretroSkinItem *item = [LibretroSkinItem new];
  item.identifier = identifier;
  item.kind = kind;
  item.inputs = kind == LibretroSkinItemKindTouchScreen ? @[ @"touchScreen" ] : @[ @"a" ];
  item.frame = frame;
  item.hitFrame = hit;
  LibretroLaidOutItem *laidOut = [LibretroLaidOutItem new];
  laidOut.item = item;
  laidOut.frame = frame;
  laidOut.hitFrame = hit;
  laidOut.assetFrame = frame;
  return laidOut;
}

static LibretroLaidOutScreen *Screen(LibretroRect container, BOOL touch) {
  LibretroLaidOutScreen *screen = [LibretroLaidOutScreen new];
  screen.container = container;
  screen.source = LibretroRectMake(0, 0, 1, 1);
  screen.role = touch ? @"bottom" : @"full";
  screen.touchScreen = touch;
  return screen;
}

static LibretroSkinLayoutResult *Layout(NSArray<LibretroLaidOutScreen *> *screens, NSArray<LibretroLaidOutItem *> *items) {
  LibretroSkinLayoutResult *layout = [LibretroSkinLayoutResult new];
  layout.skinRect = LibretroRectMake(0, 0, 400, 800);
  layout.screens = screens;
  layout.items = items;
  layout.panelFrame = LibretroRectMake(0, 0, 0, 0);
  return layout;
}

static void TestRules(void) {
  LibretroSize view = {400, 800};
  LibretroInsets none = Insets(0, 0, 0, 0);
  LibretroRect preferred = [LibretroChromeLayout preferredMenuButtonFrameForViewSize:view safeInsets:none];
  CHECK(Same(preferred, LibretroRectMake(346, 6, 44, 40)), @"preferred: 10 points from the right, 6 from the top");
  CHECK(Same([LibretroChromeLayout menuButtonFrameForLayout:nil viewSize:view safeInsets:none controlsVisible:YES],
             preferred),
        @"no layout: the preferred place");

  // A non-touch screen under the button changes nothing.
  LibretroSkinLayoutResult *game = Layout(@[ Screen(LibretroRectMake(0, 0, 400, 300), NO) ], @[]);
  CHECK(Same([LibretroChromeLayout menuButtonFrameForLayout:game viewSize:view safeInsets:none controlsVisible:YES],
             preferred),
        @"the button may sit on a picture that is not a touch screen");

  // A touch screen at the top right: the closest free place, a vertical
  // move counting three times, so the button slides left first.
  LibretroSkinLayoutResult *corner = Layout(@[ Screen(LibretroRectMake(250, 0, 150, 100), YES) ], @[]);
  LibretroRect frame = [LibretroChromeLayout menuButtonFrameForLayout:corner
                                                             viewSize:view
                                                           safeInsets:none
                                                      controlsVisible:YES];
  CHECK(Same(frame, LibretroRectMake(250 - 6 - 44, 6, 44, 40)), @"slides left beside the touch screen: %@",
        Describe(frame));

  // A full-width touch screen: below it, on the right.
  LibretroSkinLayoutResult *band = Layout(@[ Screen(LibretroRectMake(0, 0, 400, 300), YES) ], @[]);
  frame = [LibretroChromeLayout menuButtonFrameForLayout:band viewSize:view safeInsets:none controlsVisible:YES];
  CHECK(Same(frame, LibretroRectMake(346, 306, 44, 40)), @"goes below a full-width touch screen: %@", Describe(frame));

  // A touch-screen item counts like a touch-screen container.
  LibretroRect itemRect = LibretroRectMake(0, 0, 400, 300);
  LibretroSkinLayoutResult *item = Layout(@[], @[ Item(@"touchScreen", LibretroSkinItemKindTouchScreen, itemRect, itemRect) ]);
  frame = [LibretroChromeLayout menuButtonFrameForLayout:item viewSize:view safeInsets:none controlsVisible:NO];
  CHECK(Same(frame, LibretroRectMake(346, 306, 44, 40)), @"a touch-screen item is avoided too: %@", Describe(frame));

  // Controls: avoided while shown (hit frame, not only the drawn frame),
  // ignored while hidden (controller connected).
  LibretroLaidOutItem *button =
      Item(@"a", LibretroSkinItemKindButton, LibretroRectMake(340, 10, 40, 40), LibretroRectMake(300, 0, 100, 60));
  LibretroSkinLayoutResult *controls = Layout(@[], @[ button ]);
  frame = [LibretroChromeLayout menuButtonFrameForLayout:controls viewSize:view safeInsets:none controlsVisible:YES];
  CHECK(Same(frame, LibretroRectMake(300 - 6 - 44, 6, 44, 40)), @"a shown control's touch area is avoided: %@",
        Describe(frame));
  frame = [LibretroChromeLayout menuButtonFrameForLayout:controls viewSize:view safeInsets:none controlsVisible:NO];
  CHECK(Same(frame, preferred), @"hidden controls are ignored: %@", Describe(frame));

  // Nowhere clear of the controls: the touch screen still wins.
  LibretroLaidOutItem *wall =
      Item(@"b", LibretroSkinItemKindButton, LibretroRectMake(0, 300, 400, 500), LibretroRectMake(0, 300, 400, 500));
  LibretroSkinLayoutResult *crowded = Layout(@[ Screen(LibretroRectMake(0, 0, 400, 300), YES) ], @[ wall ]);
  frame = [LibretroChromeLayout menuButtonFrameForLayout:crowded viewSize:view safeInsets:none controlsVisible:YES];
  CHECK(!Near(frame, LibretroRectMake(0, 0, 400, 300), 5.999) && frame.y >= 306 - 1e-9,
        @"when controls fill the rest, the button stays off the touch screen: %@", Describe(frame));

  // Nothing free at all: the preferred place.
  LibretroSkinLayoutResult *full = Layout(@[ Screen(LibretroRectMake(0, 0, 400, 800), YES) ], @[]);
  frame = [LibretroChromeLayout menuButtonFrameForLayout:full viewSize:view safeInsets:none controlsVisible:YES];
  CHECK(Same(frame, preferred), @"a touch screen over the whole view leaves the preferred place");

  // Clearance: a touch screen ending 6 points above the preferred place is
  // fine, 5 points is not.
  LibretroSkinLayoutResult *edge = Layout(@[ Screen(LibretroRectMake(0, -100, 400, 100), YES) ], @[]);
  CHECK(Same([LibretroChromeLayout menuButtonFrameForLayout:edge viewSize:view safeInsets:none controlsVisible:YES],
             preferred),
        @"6 points of clearance are enough");
  LibretroSkinLayoutResult *closer = Layout(@[ Screen(LibretroRectMake(0, 0, 400, 1), YES) ], @[]);
  frame = [LibretroChromeLayout menuButtonFrameForLayout:closer viewSize:view safeInsets:none controlsVisible:YES];
  CHECK(Same(frame, LibretroRectMake(346, 7, 44, 40)), @"less than 6 points: moved down to %@", Describe(frame));

  // Landscape: top centre of the view; when it moves, the button stays 10
  // points inside the safe area's sides and goes to the closer side.
  LibretroSize wide = {800, 400};
  LibretroInsets notch = Insets(0, 50, 20, 50);
  LibretroRect centre = [LibretroChromeLayout preferredMenuButtonFrameForViewSize:wide safeInsets:notch];
  CHECK(Same(centre, LibretroRectMake(378, 6, 44, 40)), @"landscape: top centre %@", Describe(centre));
  LibretroSkinLayoutResult *offCentre = Layout(@[ Screen(LibretroRectMake(110, 0, 560, 380), YES) ], @[]);
  frame = [LibretroChromeLayout menuButtonFrameForLayout:offCentre viewSize:wide safeInsets:notch controlsVisible:YES];
  CHECK(Same(frame, LibretroRectMake(676, 6, 44, 40)), @"landscape: on the closer side of the touch screen %@",
        Describe(frame));
  LibretroSkinLayoutResult *centred = Layout(@[ Screen(LibretroRectMake(120, 0, 560, 380), YES) ], @[]);
  frame = [LibretroChromeLayout menuButtonFrameForLayout:centred viewSize:wide safeInsets:notch controlsVisible:YES];
  CHECK(Same(frame, LibretroRectMake(686, 6, 44, 40)), @"landscape: equal distances go to the right %@",
        Describe(frame));
  LibretroSkinLayoutResult *wider = Layout(@[ Screen(LibretroRectMake(100, 0, 600, 400), YES) ], @[]);
  frame = [LibretroChromeLayout menuButtonFrameForLayout:wider viewSize:wide safeInsets:notch controlsVisible:YES];
  CHECK(Same(frame, centre), @"no room beside it inside the safe area: the preferred place %@", Describe(frame));
}

static void TestControlsEditor(NSString *work) {
  LibretroFrontendStore *store =
      [LibretroFrontendStore storeWithDirectory:[work stringByAppendingPathComponent:@"Frontend"]];
  NSString *console = @"nds";
  NSString *gameA = @"game-a";
  NSString *gameB = @"game-b";
  NSString *key = LibretroSettingLayoutKey(LibretroDefaultSkinIdentifier, @"landscape");
  NSDictionary *dpad = @{@"dx" : @0.1, @"dy" : @0, @"scale" : @1};
  NSDictionary *a = @{@"dx" : @0, @"dy" : @(-0.05), @"scale" : @1.2};
  NSDictionary *b = @{@"dx" : @(-0.02), @"dy" : @0.03, @"scale" : @1};
  CHECK([store setValue:@{@"dpad" : dpad} forKey:key console:console game:nil] &&
            [store setValue:@{@"a" : a} forKey:key console:console game:gameA],
        @"console layout {dpad} and game A layout {a} stored");

  NSDictionary *start = [LibretroChromeLayout controlsEditorOverridesForKey:key store:store console:console scopeGame:nil];
  CHECK([start isEqualToDictionary:@{@"dpad" : dpad}],
        @"console scope from game A: the editor starts from the console's layout, not the game's (%lu entries)",
        (unsigned long)start.count);
  CHECK([LibretroChromeLayout game:gameA hasOwnLayoutForKey:key store:store console:console] &&
            ![LibretroChromeLayout game:gameB hasOwnLayoutForKey:key store:store console:console] &&
            ![LibretroChromeLayout game:nil hasOwnLayoutForKey:key store:store console:console],
        @"game A keeps its own layout over the console's, game B does not");

  // Moving b and tapping Done at console scope.
  NSMutableDictionary *edited = [start mutableCopy];
  edited[@"b"] = b;
  [store setValue:edited forKey:key console:console game:nil];
  NSDictionary *consoleValue = [store storedValueForKey:key console:console game:nil];
  CHECK([consoleValue isEqualToDictionary:(@{@"dpad" : dpad, @"b" : b})],
        @"saved at console scope: the console keeps dpad, gains b, and nothing comes from game A");
  CHECK([[store storedValueForKey:key console:console game:gameA] isEqualToDictionary:@{@"a" : a}],
        @"game A's own layout is untouched");

  NSDictionary *gameStart = [LibretroChromeLayout controlsEditorOverridesForKey:key
                                                                         store:store
                                                                       console:console
                                                                     scopeGame:gameA];
  CHECK([gameStart isEqualToDictionary:@{@"a" : a}], @"game scope: the editor starts from the game's own layout");
  NSDictionary *otherStart = [LibretroChromeLayout controlsEditorOverridesForKey:key
                                                                          store:store
                                                                        console:console
                                                                      scopeGame:gameB];
  CHECK([otherStart isEqualToDictionary:(@{@"dpad" : dpad, @"b" : b})],
        @"game scope without a game layout: the editor starts from the console's layout in effect");

  // "Reset" at console scope removes the console's value: the editor comes
  // back to nothing, never to game A's layout.
  [store setValue:nil forKey:key console:console game:nil];
  NSDictionary *afterReset = [LibretroChromeLayout controlsEditorOverridesForKey:key
                                                                          store:store
                                                                        console:console
                                                                      scopeGame:nil];
  CHECK(afterReset.count == 0, @"console reset: the editor comes back to the default layout (%lu entries)",
        (unsigned long)afterReset.count);
  // "Reset" at game scope: the console's layout in effect again.
  [store setValue:@{@"dpad" : dpad} forKey:key console:console game:nil];
  [store setValue:nil forKey:key console:console game:gameA];
  NSDictionary *gameReset = [LibretroChromeLayout controlsEditorOverridesForKey:key
                                                                         store:store
                                                                       console:console
                                                                     scopeGame:gameA];
  CHECK([gameReset isEqualToDictionary:@{@"dpad" : dpad}] &&
            ![LibretroChromeLayout game:gameA hasOwnLayoutForKey:key store:store console:console],
        @"game reset: the editor comes back to the console's layout");

  // Malformed entries are dropped.
  [store setValue:@{@"dpad" : dpad, @"x" : @3, @"y" : @[ @1 ]} forKey:key console:console game:nil];
  NSDictionary *clean = [LibretroChromeLayout controlsEditorOverridesForKey:key store:store console:console scopeGame:nil];
  CHECK([clean isEqualToDictionary:@{@"dpad" : dpad}], @"only {item: override dictionary} entries are edited");
  [store setValue:@"broken" forKey:key console:console game:nil];
  CHECK([LibretroChromeLayout controlsEditorOverridesForKey:key store:store console:console scopeGame:nil].count == 0,
        @"a value that is not a dictionary gives an empty layout");
}

int main(int argc, const char *argv[]) {
  @autoreleasepool {
    NSString *base = argc > 1 ? @(argv[1]) : NSTemporaryDirectory();
    NSString *work = [base stringByAppendingPathComponent:[NSString stringWithFormat:@"chrome-layout-%@",
                                                                                    [NSUUID UUID].UUIDString]];
    [[NSFileManager defaultManager] createDirectoryAtPath:work withIntermediateDirectories:YES attributes:nil error:nil];
    TestRules();
    TestReportedCases();
    TestDefaultSkins();
    TestControlsEditor(work);
  }
  printf("%s: %d failure(s)\n", failures == 0 ? "chrome_layout_test passed" : "chrome_layout_test FAILED", failures);
  return failures == 0 ? 0 : 1;
}
