// Behavioural test of NeoStation's default skins (LibretroDefaultSkins):
// for the 17 consoles, both orientations, iPhone SE to iPad Pro 13 and a
// resizable iPad window, with and without safe areas, and every DS / 3DS
// screen arrangement (swapped or not): every control inside the view and
// the safe area, no two controls overlapping, no control on the game in
// portrait nor on a DS / 3DS screen, the touch-screen item exactly over the
// bottom screen, every input known to the console's input map and every
// button of the console present.
#import <Foundation/Foundation.h>

#import "LibretroDefaultSkins.h"
#import "LibretroInputMap.h"
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

/// One failed invariant of one generated layout (printed up to a limit).
static void Fail(NSString *tag, NSString *message) {
  failures++;
  if (printedFailures++ < 300) printf("FAIL %s: %s\n", tag.UTF8String, message.UTF8String);
}

static const double kTolerance = 0.01;

static BOOL Overlaps(LibretroRect a, LibretroRect b) {
  double width = MIN(a.x + a.w, b.x + b.w) - MAX(a.x, b.x);
  double height = MIN(a.y + a.h, b.y + b.h) - MAX(a.y, b.y);
  return width > kTolerance && height > kTolerance;
}

static BOOL Inside(LibretroRect inner, LibretroRect outer) {
  return inner.x >= outer.x - kTolerance && inner.y >= outer.y - kTolerance &&
         inner.x + inner.w <= outer.x + outer.w + kTolerance && inner.y + inner.h <= outer.y + outer.h + kTolerance;
}

static BOOL Same(LibretroRect a, LibretroRect b) { return LibretroRectEqualToRect(a, b, 1e-9); }

static NSString *Describe(LibretroRect rect) {
  return [NSString stringWithFormat:@"{%.1f, %.1f, %.1f, %.1f}", rect.x, rect.y, rect.w, rect.h];
}

/// Realistic safe areas: iPhone SE (none), notched iPhones, iPads.
static LibretroInsets InsetsFor(double width, double height, BOOL real) {
  LibretroInsets none = {0, 0, 0, 0};
  if (!real) return none;
  BOOL portrait = height > width;
  double shorter = MIN(width, height);
  if (shorter <= 320) {
    LibretroInsets classic = {portrait ? 20 : 0, 0, 0, 0};
    return classic;
  }
  if (shorter < 600) {
    double notch = shorter >= 430 ? 59 : 47;
    LibretroInsets phonePortrait = {notch, 0, 34, 0};
    LibretroInsets phoneLandscape = {0, notch, 21, notch};
    return portrait ? phonePortrait : phoneLandscape;
  }
  LibretroInsets tablet = {24, 0, 20, 0};
  return tablet;
}

static LibretroRect RegionFor(NSString *console, NSString *role) {
  if ([role isEqualToString:@"top"]) return LibretroRectMake(0, 0, 1, 0.5);
  if ([role isEqualToString:@"bottom"]) {
    return [console isEqualToString:@"3ds"] ? LibretroRectMake(0.1, 0.5, 0.8, 0.5) : LibretroRectMake(0, 0.5, 1, 0.5);
  }
  return LibretroRectMake(0, 0, 1, 1);
}

/// Checks every invariant of one generated representation (each failure is
/// counted and printed). `strict` adds the 24-point minimum control size,
/// which only matters when the orientation matches the view.
static void CheckRepresentation(NSString *console, LibretroSkinRepresentation *rep, LibretroSkinOrientation orientation,
                                LibretroSize view, LibretroInsets insets, BOOL strict, NSString *tag) {
  LibretroInputMap *map = [LibretroInputMap mapForConsole:console];
  LibretroRect bounds = LibretroRectMake(0, 0, view.w, view.h);
  LibretroRect safeArea =
      LibretroRectMake(insets.left, insets.top, view.w - insets.left - insets.right, view.h - insets.top - insets.bottom);
  if (!rep.generated || rep.orientation != orientation || rep.mappingSize.w != view.w || rep.mappingSize.h != view.h) {
    Fail(tag, @"not generated at the view size");
  }
  if (rep.backgroundPath != nil) Fail(tag, @"default skins draw no image");

  NSMutableArray<LibretroSkinItem *> *controls = [NSMutableArray array];
  NSMutableArray<LibretroSkinItem *> *touchItems = [NSMutableArray array];
  NSMutableSet<NSString *> *identifiers = [NSMutableSet set];
  NSMutableSet<NSString *> *present = [NSMutableSet set];
  for (LibretroSkinItem *item in rep.items) {
    if ([identifiers containsObject:item.identifier]) Fail(tag, [@"duplicate identifier " stringByAppendingString:item.identifier]);
    [identifiers addObject:item.identifier];
    [present addObjectsFromArray:item.inputs];
    if (!Inside(item.frame, bounds)) {
      Fail(tag, [NSString stringWithFormat:@"%@ outside the view %@", item.identifier, Describe(item.frame)]);
    }
    for (NSString *input in item.inputs) {
      if ([map targetForInput:input].kind == LibretroInputTargetNone) {
        Fail(tag, [NSString stringWithFormat:@"%@ sends %@, unknown to the %@ map", item.identifier, input, console]);
      }
    }
    if (item.kind == LibretroSkinItemKindTouchScreen) {
      [touchItems addObject:item];
      continue;
    }
    [controls addObject:item];
    if (!item.movable) Fail(tag, [item.identifier stringByAppendingString:@" cannot move"]);
    if (!Inside(item.frame, safeArea)) {
      Fail(tag, [NSString stringWithFormat:@"%@ outside the safe area %@", item.identifier, Describe(item.frame)]);
    }
    if (strict && MIN(item.frame.w, item.frame.h) < 24) {
      Fail(tag, [NSString stringWithFormat:@"%@ smaller than 24 points %@", item.identifier, Describe(item.frame)]);
    }
    if (!Inside(item.frame, item.hitFrame)) Fail(tag, [item.identifier stringByAppendingString:@" hit frame smaller than it"]);
    if (item.shape == LibretroSkinItemShapeNone || item.fillColor == 0) {
      Fail(tag, [item.identifier stringByAppendingString:@" has no vector style"]);
    }
    if (item.kind == LibretroSkinItemKindButton) {
      NSString *glyph = [map glyphForInput:item.inputs.firstObject];
      if (item.inputs.count != 1 || (glyph != nil && ![item.label isEqualToString:glyph]) || item.label.length == 0) {
        Fail(tag, [item.identifier stringByAppendingString:@" label is not the console glyph"]);
      }
    } else if (item.inputs.count != 4) {
      Fail(tag, [item.identifier stringByAppendingString:@" D-pad / stick without four directions"]);
    }
  }
  for (NSUInteger i = 0; i < controls.count; i++) {
    for (NSUInteger j = i + 1; j < controls.count; j++) {
      if (Overlaps(controls[i].frame, controls[j].frame)) {
        Fail(tag, [NSString stringWithFormat:@"%@ %@ overlaps %@ %@", controls[i].identifier, Describe(controls[i].frame),
                                             controls[j].identifier, Describe(controls[j].frame)]);
      }
    }
  }
  for (NSString *button in map.buttons) {
    if (![present containsObject:button]) Fail(tag, [@"missing button " stringByAppendingString:button]);
  }

  if (rep.screens.count == 0) Fail(tag, @"no screen");
  BOOL dual = [LibretroDefaultSkins isDualScreenConsole:console];
  LibretroSkinScreen *bottom = nil;
  for (LibretroSkinScreen *screen in rep.screens) {
    if (!screen.hasOutputFrame || !(screen.outputFrame.w > 1) || !(screen.outputFrame.h > 1)) {
      Fail(tag, [NSString stringWithFormat:@"empty %@ screen %@", screen.role, Describe(screen.outputFrame)]);
    }
    if (!Inside(screen.outputFrame, safeArea)) Fail(tag, [screen.role stringByAppendingString:@" screen outside the safe area"]);
    if (!Same(screen.source, RegionFor(console, screen.role))) Fail(tag, [screen.role stringByAppendingString:@" wrong source"]);
    if ([screen.role isEqualToString:@"bottom"]) bottom = screen;
    if (screen.touchScreen != [screen.role isEqualToString:@"bottom"]) Fail(tag, @"touch flag not on the bottom screen");
    // The touch screen is never under a control or its touch area; in
    // portrait no control covers the game; DS / 3DS screens stay clear.
    BOOL clear = screen.touchScreen || orientation == LibretroSkinOrientationPortrait || dual;
    if (!clear) continue;
    for (LibretroSkinItem *control in controls) {
      LibretroRect area = screen.touchScreen ? control.hitFrame : control.frame;
      if (Overlaps(area, screen.outputFrame)) {
        Fail(tag, [NSString stringWithFormat:@"%@ %@ over the %@ screen %@", control.identifier, Describe(area), screen.role,
                                             Describe(screen.outputFrame)]);
      }
    }
  }
  if (!dual && (rep.screens.count != 1 || ![rep.screens.firstObject.role isEqualToString:@"full"])) {
    Fail(tag, @"single-screen consoles show one full screen");
  }
  if (map.hasTouchScreen && bottom != nil) {
    if (touchItems.count != 1) {
      Fail(tag, @"no touch-screen item over the bottom screen");
    } else {
      LibretroSkinItem *touch = touchItems.firstObject;
      if (!Same(touch.frame, bottom.outputFrame) || !Same(touch.hitFrame, touch.frame) || touch.movable ||
          ![touch.identifier isEqualToString:@"touchScreen"] || ![touch.inputs isEqualToArray:@[ @"touchScreen" ]]) {
        Fail(tag, [NSString stringWithFormat:@"touch item %@ not exactly over the bottom screen %@", Describe(touch.frame),
                                             Describe(bottom.outputFrame)]);
      }
    }
  } else if (touchItems.count > 0) {
    Fail(tag, @"touch-screen item without a bottom screen");
  }

  if (orientation == LibretroSkinOrientationPortrait) {
    LibretroRect panel = rep.panelFrame;
    if (rep.panelColor == 0 || rep.translucent || !Inside(panel, bounds) || panel.h <= 0) Fail(tag, @"no opaque panel");
    for (LibretroSkinScreen *screen in rep.screens) {
      if (screen.outputFrame.y + screen.outputFrame.h > panel.y + kTolerance) Fail(tag, @"panel over the game");
      if (screen.outputFrame.y < insets.top - kTolerance) Fail(tag, @"game under the top safe area");
    }
    for (LibretroSkinItem *control in controls) {
      if (!Inside(control.frame, panel)) Fail(tag, [control.identifier stringByAppendingString:@" outside the panel"]);
    }
  } else if (rep.panelColor != 0 || !rep.translucent) {
    Fail(tag, @"landscape controls are translucent, without panel");
  }

  LibretroSkinLayoutResult *layout = [LibretroSkinLayout layoutRepresentation:rep
                                                                     viewSize:view
                                                                   safeInsets:insets
                                                                    overrides:nil];
  BOOL identity = layout.items.count == rep.items.count && Same(layout.skinRect, bounds);
  for (NSUInteger index = 0; identity && index < rep.items.count; index++) {
    identity = Same(layout.items[index].frame, rep.items[index].frame);
  }
  for (NSUInteger index = 0; identity && index < rep.screens.count; index++) {
    identity = layout.screens.count == rep.screens.count &&
               Same(layout.screens[index].container, rep.screens[index].outputFrame) &&
               layout.screens[index].touchScreen == rep.screens[index].touchScreen;
  }
  if (!identity) Fail(tag, @"layout of a generated skin is not the identity");
  if (orientation == LibretroSkinOrientationPortrait && !Same(layout.panelFrame, rep.panelFrame)) {
    Fail(tag, @"layout panel differs");
  }
}

static void TestEveryLayout(void) {
  NSArray<NSArray<NSNumber *> *> *sizes =
      @[ @[ @320, @568 ], @[ @390, @844 ], @[ @430, @932 ], @[ @820, @1180 ], @[ @1032, @1376 ], @[ @1180, @820 ], @[ @700, @900 ] ];
  for (NSString *console in [LibretroDefaultSkins consoles]) {
    int before = failures;
    int layouts = 0;
    BOOL dual = [LibretroDefaultSkins isDualScreenConsole:console];
    for (NSArray<NSNumber *> *size in sizes) {
      for (int rotated = 0; rotated < 2; rotated++) {
        double width = rotated ? size[1].doubleValue : size[0].doubleValue;
        double height = rotated ? size[0].doubleValue : size[1].doubleValue;
        LibretroSkinOrientation orientation =
            width > height ? LibretroSkinOrientationLandscape : LibretroSkinOrientationPortrait;
        BOOL iPad = MIN(width, height) >= 600;
        for (int real = 0; real < 2; real++) {
          LibretroInsets insets = InsetsFor(width, height, real == 1);
          NSMutableArray *arrangements = [[LibretroDefaultSkins arrangementsForConsole:console orientation:orientation] mutableCopy];
          [arrangements addObject:[NSNull null]];  // the default one
          for (id arrangement in arrangements) {
            NSString *name = [arrangement isKindOfClass:[NSString class]] ? arrangement : nil;
            for (int swapped = 0; swapped < (dual ? 2 : 1); swapped++) {
              LibretroSkinRepresentation *rep = [LibretroDefaultSkins representationForConsole:console
                                                                                   orientation:orientation
                                                                                      viewSize:(LibretroSize){width, height}
                                                                                    safeInsets:insets
                                                                                          iPad:iPad
                                                                                   arrangement:name
                                                                                       swapped:swapped == 1
                                                                                       regions:nil];
              NSString *tag = [NSString stringWithFormat:@"%@ %@ %gx%g insets=%d %@%@", console,
                                                         LibretroSkinOrientationName(orientation), width, height, real,
                                                         name ?: @"default", swapped ? @" swapped" : @""];
              CheckRepresentation(console, rep, orientation, (LibretroSize){width, height}, insets, YES, tag);
              layouts++;
            }
          }
        }
      }
    }
    CHECK(failures == before, @"%@: %d generated layouts keep every control in place", console, layouts);
  }
}

static void TestMismatchedOrientation(void) {
  // Robustness: an orientation that does not match the view's shape (the
  // view is resized during a rotation) still gives a usable skin.
  for (NSString *console in [LibretroDefaultSkins consoles]) {
    int before = failures;
    for (NSArray<NSNumber *> *size in @[ @[ @844, @390 ], @[ @390, @844 ], @[ @1180, @820 ] ]) {
      double width = size[0].doubleValue, height = size[1].doubleValue;
      LibretroSkinOrientation orientation =
          width > height ? LibretroSkinOrientationPortrait : LibretroSkinOrientationLandscape;
      LibretroInsets none = {0, 0, 0, 0};
      LibretroSkinRepresentation *rep = [LibretroDefaultSkins representationForConsole:console
                                                                           orientation:orientation
                                                                              viewSize:(LibretroSize){width, height}
                                                                            safeInsets:none
                                                                                  iPad:NO
                                                                           arrangement:nil
                                                                               swapped:NO
                                                                               regions:nil];
      NSString *tag = [NSString stringWithFormat:@"%@ %@ in %gx%g", console, LibretroSkinOrientationName(orientation), width,
                                                 height];
      CheckRepresentation(console, rep, orientation, (LibretroSize){width, height}, none, NO, tag);
    }
    CHECK(failures == before, @"%@: usable with an orientation that does not match the view", console);
  }
}

static LibretroSkinItem *ItemNamed(LibretroSkinRepresentation *rep, NSString *identifier) {
  for (LibretroSkinItem *item in rep.items) {
    if ([item.identifier isEqualToString:identifier]) return item;
  }
  return nil;
}

static LibretroSkinRepresentation *Phone(NSString *console, LibretroSkinOrientation orientation, NSString *arrangement,
                                         BOOL swapped, NSDictionary *regions) {
  BOOL portrait = orientation == LibretroSkinOrientationPortrait;
  LibretroSize view = portrait ? (LibretroSize){390, 844} : (LibretroSize){844, 390};
  return [LibretroDefaultSkins representationForConsole:console
                                            orientation:orientation
                                               viewSize:view
                                             safeInsets:InsetsFor(view.w, view.h, YES)
                                                   iPad:NO
                                            arrangement:arrangement
                                                swapped:swapped
                                                regions:regions];
}

static void TestCatalog(void) {
  NSArray<NSString *> *consoles = [LibretroDefaultSkins consoles];
  CHECK(consoles.count == 17 && [consoles isEqualToArray:[LibretroInputMap consoles]],
        @"17 consoles, the input map's list");
  for (NSString *console in consoles) {
    BOOL dual = [console isEqualToString:@"nds"] || [console isEqualToString:@"3ds"];
    CHECK([LibretroDefaultSkins isDualScreenConsole:console] == dual, @"%@ dual screen: %d", console, dual);
    for (NSNumber *value in @[ @(LibretroSkinOrientationPortrait), @(LibretroSkinOrientationLandscape) ]) {
      LibretroSkinOrientation orientation = (LibretroSkinOrientation)value.integerValue;
      NSArray<NSString *> *arrangements = [LibretroDefaultSkins arrangementsForConsole:console orientation:orientation];
      NSString *preferred = [LibretroDefaultSkins defaultArrangementForConsole:console orientation:orientation];
      CHECK(dual ? (arrangements.count > 0 && [arrangements containsObject:preferred]) : arrangements.count == 0,
            @"%@ %@ arrangements", console, LibretroSkinOrientationName(orientation));
    }
    LibretroSkin *skin = [LibretroDefaultSkins skinForConsole:console];
    CHECK([skin.identifier isEqualToString:@"default"] && [skin.installedIdentifier isEqualToString:LibretroDefaultSkinIdentifier] &&
              [skin.consoles isEqualToArray:@[ console ]] && skin.representations.count == 0 && skin.warnings.count == 0,
          @"%@ default skin descriptor", console);
    CHECK([[skin orientationsForIPad:NO] isEqualToArray:(@[ @"portrait", @"landscape" ])] &&
              [[skin orientationsForIPad:YES] isEqualToArray:(@[ @"portrait", @"landscape" ])],
          @"%@ default skin has both orientations", console);
  }
  NSArray<NSString *> *portrait = [LibretroDefaultSkins arrangementsForConsole:@"nds" orientation:LibretroSkinOrientationPortrait];
  NSArray<NSString *> *landscape = [LibretroDefaultSkins arrangementsForConsole:@"3ds" orientation:LibretroSkinOrientationLandscape];
  CHECK([portrait isEqualToArray:(@[ LibretroArrangementStacked, LibretroArrangementLargeTop, LibretroArrangementTopOnly,
                                     LibretroArrangementBottomOnly ])],
        @"portrait arrangements");
  CHECK([landscape isEqualToArray:(@[ LibretroArrangementSideBySide, LibretroArrangementLargeTop, LibretroArrangementStacked,
                                      LibretroArrangementTopOnly, LibretroArrangementBottomOnly ])],
        @"landscape arrangements");
  CHECK([LibretroArrangementSideBySide isEqualToString:@"sideBySide"] && [LibretroArrangementLargeTop isEqualToString:@"largeTop"],
        @"arrangement identifiers");
}

static void TestScreens(void) {
  // Swapping keeps the touch screen on the bottom screen.
  LibretroSkinRepresentation *stacked = Phone(@"nds", LibretroSkinOrientationPortrait, LibretroArrangementStacked, NO, nil);
  LibretroSkinRepresentation *swapped = Phone(@"nds", LibretroSkinOrientationPortrait, LibretroArrangementStacked, YES, nil);
  CHECK(stacked.screens.count == 2 && [stacked.screens[0].role isEqualToString:@"top"] &&
            [stacked.screens[1].role isEqualToString:@"bottom"] &&
            stacked.screens[0].outputFrame.y < stacked.screens[1].outputFrame.y,
        @"stacked: top screen above the bottom one");
  CHECK(swapped.screens.count == 2 && [swapped.screens[0].role isEqualToString:@"bottom"] &&
            Same(ItemNamed(swapped, @"touchScreen").frame, swapped.screens[0].outputFrame),
        @"swapped: the touch screen follows the bottom screen to the upper place");
  // Screens are listed in place order (upper place first), so swapping keeps
  // the two places and exchanges which screen fills them.
  CHECK(stacked.screens.count == 2 && swapped.screens.count == 2 &&
            Same(stacked.screens[0].outputFrame, swapped.screens[0].outputFrame) &&
            Same(stacked.screens[1].outputFrame, swapped.screens[1].outputFrame) &&
            [swapped.screens[1].role isEqualToString:@"top"],
        @"swapped: the two places are exchanged");
  LibretroSkinRepresentation *topOnly = Phone(@"nds", LibretroSkinOrientationPortrait, LibretroArrangementTopOnly, NO, nil);
  CHECK(topOnly.screens.count == 1 && [topOnly.screens[0].role isEqualToString:@"top"] &&
            ItemNamed(topOnly, @"touchScreen") == nil,
        @"top screen only: no touch screen");
  LibretroSkinRepresentation *bottomOnly = Phone(@"3ds", LibretroSkinOrientationLandscape, LibretroArrangementBottomOnly, NO, nil);
  CHECK(bottomOnly.screens.count == 1 && bottomOnly.screens[0].touchScreen &&
            Same(ItemNamed(bottomOnly, @"touchScreen").frame, bottomOnly.screens[0].outputFrame),
        @"bottom screen only: touch screen over it");
  LibretroSkinRepresentation *large = Phone(@"3ds", LibretroSkinOrientationLandscape, LibretroArrangementLargeTop, NO, nil);
  CHECK(large.screens.count == 2 && large.screens[0].outputFrame.w > large.screens[1].outputFrame.w * 1.9,
        @"large top: the top screen is much larger");
  LibretroSkinRepresentation *side = Phone(@"nds", LibretroSkinOrientationLandscape, LibretroArrangementSideBySide, NO, nil);
  CHECK(side.screens.count == 2 && fabs(side.screens[0].outputFrame.y - side.screens[1].outputFrame.y) < 1e-6 &&
            side.screens[0].outputFrame.x < side.screens[1].outputFrame.x,
        @"side by side: same height, top screen on the left");
  LibretroSkinRepresentation *fallback = Phone(@"3ds", LibretroSkinOrientationPortrait, @"unknown", NO, nil);
  CHECK(fallback.screens.count == 2 && [fallback.screens[1].role isEqualToString:@"bottom"],
        @"unknown arrangement: the default one");

  // 3DS: top 400x240 (5:3), bottom 320x240 (4:3), same pixel scale.
  LibretroSkinRepresentation *threeDS = Phone(@"3ds", LibretroSkinOrientationPortrait, LibretroArrangementStacked, NO, nil);
  CHECK(threeDS.screens.count == 2, @"two 3DS screens");
  if (threeDS.screens.count == 2) {
    LibretroRect top = threeDS.screens[0].outputFrame, bottom = threeDS.screens[1].outputFrame;
    CHECK(fabs(top.w / top.h - 5.0 / 3.0) < 1e-6 && fabs(bottom.w / bottom.h - 4.0 / 3.0) < 1e-6 &&
              fabs(top.h - bottom.h) < 1e-6,
          @"3DS screens keep their shapes %@ %@", Describe(top), Describe(bottom));
    CHECK(Same(threeDS.screens[1].source, LibretroRectMake(0.1, 0.5, 0.8, 0.5)), @"3DS bottom source");
  }

  // Regions sent by the Dart catalog are used as given.
  NSDictionary *regions = @{@"top" : @[ @0, @0, @1, @0.5 ], @"bottom" : @[ @0.125, @0.5, @0.75, @0.5 ]};
  LibretroSkinRepresentation *custom = Phone(@"3ds", LibretroSkinOrientationPortrait, LibretroArrangementStacked, NO, regions);
  CHECK(custom.screens.count == 2 && Same(custom.screens[1].source, LibretroRectMake(0.125, 0.5, 0.75, 0.5)) &&
            fabs(custom.screens[1].outputFrame.w / custom.screens[1].outputFrame.h - 1.25) < 1e-6,
        @"catalog regions give the source and the shape");
  NSDictionary *broken = @{@"top" : @[ @"x" ], @"bottom" : @[ @0, @0, @0, @0 ]};
  LibretroSkinRepresentation *repaired = Phone(@"nds", LibretroSkinOrientationPortrait, LibretroArrangementStacked, NO, broken);
  CHECK(repaired.screens.count == 2 && Same(repaired.screens[0].source, LibretroRectMake(0, 0, 1, 0.5)) &&
            Same(repaired.screens[1].source, LibretroRectMake(0, 0.5, 1, 0.5)),
        @"invalid regions fall back to NeoStation's");

  // Single-screen consoles: the game at the top in portrait, the safe area
  // in landscape.
  LibretroSkinRepresentation *gba = Phone(@"gba", LibretroSkinOrientationPortrait, nil, NO, nil);
  LibretroRect game = gba.screens[0].outputFrame;
  CHECK(Same(game, LibretroRectMake(0, 47, 390, 260)) && gba.screens[0].touchScreen == NO,
        @"GBA portrait: 3:2 game area below the notch %@", Describe(game));
  CHECK(fabs(gba.panelFrame.y - (game.y + game.h) - 6) < 1e-6 && fabs(gba.panelFrame.y + gba.panelFrame.h - 844) < 1e-9,
        @"panel from below the game to the bottom edge %@", Describe(gba.panelFrame));
  LibretroSkinRepresentation *wide = Phone(@"psp", LibretroSkinOrientationLandscape, nil, NO, nil);
  CHECK(Same(wide.screens[0].outputFrame, LibretroRectMake(47, 0, 750, 369)), @"landscape: the whole safe area %@",
        Describe(wide.screens[0].outputFrame));
}

static void TestStyle(void) {
  LibretroSkinRepresentation *snes = Phone(@"snes", LibretroSkinOrientationPortrait, nil, NO, nil);
  CHECK(ItemNamed(snes, @"a").fillColor == 0xFFD7263D && ItemNamed(snes, @"b").fillColor == 0xFFF2C12E &&
            ItemNamed(snes, @"x").fillColor == 0xFF2D5DA8 && ItemNamed(snes, @"y").fillColor == 0xFF2E9447,
        @"SNES: A red, B yellow, X blue, Y green");
  LibretroSkinItem *a = ItemNamed(snes, @"a"), *x = ItemNamed(snes, @"x"), *b = ItemNamed(snes, @"b"),
                   *y = ItemNamed(snes, @"y");
  CHECK(x.frame.y < a.frame.y && b.frame.y > a.frame.y && y.frame.x < a.frame.x && a.frame.x > b.frame.x,
        @"SNES diamond: X top, A right, B bottom, Y left");
  LibretroSkinRepresentation *psx = Phone(@"psx", LibretroSkinOrientationPortrait, nil, NO, nil);
  CHECK([ItemNamed(psx, @"x").label isEqualToString:@"△"] && ItemNamed(psx, @"x").labelColor == 0xFF35C08A &&
            [ItemNamed(psx, @"a").label isEqualToString:@"○"] && ItemNamed(psx, @"a").labelColor == 0xFFF0506E &&
            [ItemNamed(psx, @"b").label isEqualToString:@"✕"] && ItemNamed(psx, @"b").labelColor == 0xFF6E9BE6 &&
            [ItemNamed(psx, @"y").label isEqualToString:@"□"] && ItemNamed(psx, @"y").labelColor == 0xFFE58FC8,
        @"PlayStation symbols in their colours");
  CHECK(ItemNamed(psx, @"l3") != nil && ItemNamed(psx, @"r3") != nil && ItemNamed(psx, @"l2").shape == LibretroSkinItemShapeRounded,
        @"PlayStation L2 / R2 shoulders and L3 / R3 present");
  LibretroSkinRepresentation *n64 = Phone(@"n64", LibretroSkinOrientationLandscape, nil, NO, nil);
  CHECK(ItemNamed(n64, @"a").fillColor == 0xFF1F4FB4 && ItemNamed(n64, @"b").fillColor == 0xFF1F8A3B &&
            ItemNamed(n64, @"cUp").fillColor == 0xFFF2C200 && ItemNamed(n64, @"leftStick").kind == LibretroSkinItemKindThumbstick &&
            ItemNamed(n64, @"dpad") == nil,
        @"N64: blue A, green B, yellow C buttons, analog stick");
  LibretroSkinRepresentation *md = Phone(@"md", LibretroSkinOrientationPortrait, nil, NO, nil);
  CHECK(ItemNamed(md, @"x").frame.w < ItemNamed(md, @"a").frame.w && [ItemNamed(md, @"mode").label isEqualToString:@"MODE"] &&
            ItemNamed(md, @"mode").shape == LibretroSkinItemShapePill,
        @"Genesis: small X Y Z, MODE pill");
  LibretroSkinRepresentation *arcade = Phone(@"arcade", LibretroSkinOrientationPortrait, nil, NO, nil);
  CHECK([ItemNamed(arcade, @"select").label isEqualToString:@"COIN"] && [ItemNamed(arcade, @"b").label isEqualToString:@"1"] &&
            [ItemNamed(arcade, @"r").label isEqualToString:@"6"],
        @"arcade: six numbered buttons and COIN");
  LibretroSkinRepresentation *gba = Phone(@"gba", LibretroSkinOrientationPortrait, nil, NO, nil);
  CHECK(ItemNamed(gba, @"a").frame.y < ItemNamed(gba, @"b").frame.y && ItemNamed(gba, @"a").frame.x > ItemNamed(gba, @"b").frame.x,
        @"Game Boy: A above and right of B");
  LibretroSkinRepresentation *threeDS = Phone(@"3ds", LibretroSkinOrientationPortrait, nil, NO, nil);
  LibretroSkinItem *circlePad = ItemNamed(threeDS, @"leftStick"), *dpad = ItemNamed(threeDS, @"dpad");
  LibretroSkinItem *cStick = ItemNamed(threeDS, @"rightStick");
  CHECK(circlePad.frame.y + circlePad.frame.h <= dpad.frame.y && cStick.frame.w < circlePad.frame.w &&
            [ItemNamed(threeDS, @"l2").label isEqualToString:@"ZL"] && [ItemNamed(threeDS, @"r2").label isEqualToString:@"ZR"],
        @"3DS: Circle Pad above the D-pad, small C-stick, ZL / ZR");
  CHECK(ItemNamed(threeDS, @"l3") == nil && ItemNamed(threeDS, @"home") == nil, @"3DS: no HOME / L3");
  CHECK(ItemNamed(snes, @"dpad").thumbstickSize.w == 0 && circlePad.thumbstickSize.w > 0 &&
            circlePad.thumbstickSize.w < circlePad.frame.w,
        @"sticks carry a knob size");
  CHECK(snes.panelColor != 0 && [snes.device isEqualToString:@"iphone"] && [snes.displayType isEqualToString:@"edgeToEdge"],
        @"portrait panel colour, device and display type");
  LibretroSkinRepresentation *tablet =
      [LibretroDefaultSkins representationForConsole:@"snes"
                                         orientation:LibretroSkinOrientationLandscape
                                            viewSize:(LibretroSize){1180, 820}
                                          safeInsets:InsetsFor(1180, 820, YES)
                                                iPad:YES
                                         arrangement:nil
                                             swapped:NO
                                             regions:nil];
  CHECK([tablet.device isEqualToString:@"ipad"] && [tablet.displayType isEqualToString:@"standard"] &&
            ItemNamed(tablet, @"dpad").frame.w > ItemNamed(snes, @"dpad").frame.w &&
            ItemNamed(tablet, @"dpad").frame.w <= 150 * 1.5 + 1e-6,
        @"iPad: larger controls, capped");
}

int main(int argc, const char *argv[]) {
  @autoreleasepool {
    TestCatalog();
    TestScreens();
    TestStyle();
    TestEveryLayout();
    TestMismatchedOrientation();
  }
  printf("%s: %d failure(s)\n", failures == 0 ? "default_skins_test passed" : "default_skins_test FAILED", failures);
  return failures == 0 ? 0 : 1;
}
