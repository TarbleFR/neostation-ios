// Behavioural test of LibretroInputMap: the logical controls of each of the
// 17 consoles, their RetroPad / analog / pointer / action targets and glyphs,
// the controller defaults (identical to the historical positional mapping),
// blocked screen-swap buttons, user remaps, skin input aliases and analog
// magnitudes. The expected tables are written here from the header contract,
// independently of the implementation.
#import <Foundation/Foundation.h>

#import "LibretroInputMap.h"

#include <stdio.h>

#include "libretro.h"

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

#define BUTTON(name, glyph, joypad) @[ name, glyph, @(RETRO_DEVICE_ID_JOYPAD_##joypad) ]
#define C_BUTTON(name, glyph) @[ name, glyph, @(-1) ]
#define BIT(joypad) ((uint16_t)(1u << RETRO_DEVICE_ID_JOYPAD_##joypad))

/// console -> [[logical name, glyph, RetroPad id or -1 for analog], ...] in display order.
static NSDictionary<NSString *, NSArray *> *ExpectedButtons(void) {
  NSArray *nes = @[
    BUTTON(@"a", @"A", A), BUTTON(@"b", @"B", B), BUTTON(@"start", @"START", START),
    BUTTON(@"select", @"SELECT", SELECT)
  ];
  NSArray *gba = @[
    BUTTON(@"a", @"A", A), BUTTON(@"b", @"B", B), BUTTON(@"l", @"L", L), BUTTON(@"r", @"R", R),
    BUTTON(@"start", @"START", START), BUTTON(@"select", @"SELECT", SELECT)
  ];
  NSArray *snes = @[
    BUTTON(@"a", @"A", A), BUTTON(@"b", @"B", B), BUTTON(@"x", @"X", X), BUTTON(@"y", @"Y", Y),
    BUTTON(@"l", @"L", L), BUTTON(@"r", @"R", R), BUTTON(@"start", @"START", START),
    BUTTON(@"select", @"SELECT", SELECT)
  ];
  NSArray *genesis = @[
    BUTTON(@"a", @"A", Y), BUTTON(@"b", @"B", B), BUTTON(@"c", @"C", A), BUTTON(@"x", @"X", L),
    BUTTON(@"y", @"Y", X), BUTTON(@"z", @"Z", R), BUTTON(@"start", @"START", START), BUTTON(@"mode", @"MODE", SELECT)
  ];
  NSArray *masterSystem = @[ BUTTON(@"b", @"1", B), BUTTON(@"a", @"2", A), BUTTON(@"start", @"START", START) ];
  NSArray *arcade = @[
    BUTTON(@"b", @"1", B), BUTTON(@"a", @"2", A), BUTTON(@"y", @"3", Y), BUTTON(@"x", @"4", X),
    BUTTON(@"l", @"5", L), BUTTON(@"r", @"6", R), BUTTON(@"select", @"COIN", SELECT), BUTTON(@"start", @"START", START)
  ];
  NSArray *n64 = @[
    BUTTON(@"a", @"A", B), BUTTON(@"b", @"B", Y), BUTTON(@"z", @"Z", L2), BUTTON(@"l", @"L", L),
    BUTTON(@"r", @"R", R), BUTTON(@"start", @"START", START), C_BUTTON(@"cUp", @"C▲"), C_BUTTON(@"cDown", @"C▼"),
    C_BUTTON(@"cLeft", @"C◀"), C_BUTTON(@"cRight", @"C▶")
  ];
  NSArray *psx = @[
    BUTTON(@"a", @"○", A), BUTTON(@"b", @"✕", B), BUTTON(@"x", @"△", X), BUTTON(@"y", @"□", Y),
    BUTTON(@"l", @"L1", L), BUTTON(@"r", @"R1", R), BUTTON(@"l2", @"L2", L2), BUTTON(@"r2", @"R2", R2),
    BUTTON(@"l3", @"L3", L3), BUTTON(@"r3", @"R3", R3), BUTTON(@"start", @"START", START),
    BUTTON(@"select", @"SELECT", SELECT)
  ];
  NSArray *psp = @[
    BUTTON(@"a", @"○", A), BUTTON(@"b", @"✕", B), BUTTON(@"x", @"△", X), BUTTON(@"y", @"□", Y),
    BUTTON(@"l", @"L", L), BUTTON(@"r", @"R", R), BUTTON(@"start", @"START", START),
    BUTTON(@"select", @"SELECT", SELECT)
  ];
  NSArray *threeDS = @[
    BUTTON(@"a", @"A", A), BUTTON(@"b", @"B", B), BUTTON(@"x", @"X", X), BUTTON(@"y", @"Y", Y),
    BUTTON(@"l", @"L", L), BUTTON(@"r", @"R", R), BUTTON(@"l2", @"ZL", L2), BUTTON(@"r2", @"ZR", R2),
    BUTTON(@"start", @"START", START), BUTTON(@"select", @"SELECT", SELECT)
  ];
  return @{
    @"nes" : nes,
    @"gb" : nes,
    @"gbc" : nes,
    @"gba" : gba,
    @"snes" : snes,
    @"nds" : snes,
    @"md" : genesis,
    @"mcd" : genesis,
    @"32x" : genesis,
    @"sms" : masterSystem,
    @"gg" : masterSystem,
    @"sg1000" : masterSystem,
    @"arcade" : arcade,
    @"n64" : n64,
    @"psx" : psx,
    @"psp" : psp,
    @"3ds" : threeDS,
  };
}

static BOOL IsButton(LibretroInputTarget target, unsigned joypad) {
  return target.kind == LibretroInputTargetButton && target.identifier == joypad;
}

static BOOL IsAnalog(LibretroInputTarget target, unsigned stick, unsigned axis, int sign) {
  return target.kind == LibretroInputTargetAnalog && target.stick == stick && target.axis == axis &&
         target.sign == sign;
}

static BOOL IsAction(LibretroInputTarget target, LibretroFrontendAction action) {
  return target.kind == LibretroInputTargetAction && target.action == action;
}

static BOOL IsNone(LibretroInputTarget target) { return target.kind == LibretroInputTargetNone; }

static NSArray<NSString *> *StickInputs(NSString *prefix) {
  return @[
    [prefix stringByAppendingString:@"Up"], [prefix stringByAppendingString:@"Down"],
    [prefix stringByAppendingString:@"Left"], [prefix stringByAppendingString:@"Right"]
  ];
}

static void TestElements(void) {
  NSArray<NSString *> *elements = @[
    @"buttonA", @"buttonB", @"buttonX", @"buttonY", @"leftShoulder", @"rightShoulder", @"leftTrigger",
    @"rightTrigger", @"leftThumbstickButton", @"rightThumbstickButton", @"buttonOptions", @"buttonMenu", @"dpadUp",
    @"dpadDown", @"dpadLeft", @"dpadRight"
  ];
  CHECK([LibretroGamepadElements() isEqualToArray:elements], @"16 remappable controller elements in header order");
  const int expected[16] = {
      RETRO_DEVICE_ID_JOYPAD_B,     RETRO_DEVICE_ID_JOYPAD_A,      RETRO_DEVICE_ID_JOYPAD_Y,
      RETRO_DEVICE_ID_JOYPAD_X,     RETRO_DEVICE_ID_JOYPAD_L,      RETRO_DEVICE_ID_JOYPAD_R,
      RETRO_DEVICE_ID_JOYPAD_L2,    RETRO_DEVICE_ID_JOYPAD_R2,     RETRO_DEVICE_ID_JOYPAD_L3,
      RETRO_DEVICE_ID_JOYPAD_R3,    RETRO_DEVICE_ID_JOYPAD_SELECT, RETRO_DEVICE_ID_JOYPAD_START,
      RETRO_DEVICE_ID_JOYPAD_UP,    RETRO_DEVICE_ID_JOYPAD_DOWN,   RETRO_DEVICE_ID_JOYPAD_LEFT,
      RETRO_DEVICE_ID_JOYPAD_RIGHT,
  };
  for (NSUInteger index = 0; index < elements.count; index++) {
    CHECK(LibretroGamepadPassthroughButton(elements[index]) == expected[index],
          @"%@ passes RetroPad id %d through (positional SNES layout)", elements[index], expected[index]);
  }
  CHECK(LibretroGamepadPassthroughButton(@"buttonHome") == -1 && LibretroGamepadPassthroughButton(@"") == -1,
        @"unknown elements have no RetroPad id");
}

static void TestConsoleTables(void) {
  NSArray<NSString *> *consoles = @[
    @"nes", @"snes", @"gb", @"gbc", @"gba", @"md", @"mcd", @"32x", @"sms", @"gg", @"sg1000", @"arcade", @"nds",
    @"n64", @"psx", @"psp", @"3ds"
  ];
  CHECK([[LibretroInputMap consoles] isEqualToArray:consoles], @"the 17 consoles in order");
  NSDictionary<NSString *, NSArray *> *expected = ExpectedButtons();
  NSSet<NSString *> *leftStick = [NSSet setWithArray:@[ @"n64", @"psp", @"3ds" ]];
  NSSet<NSString *> *touch = [NSSet setWithArray:@[ @"nds", @"3ds" ]];
  NSDictionary<NSString *, NSNumber *> *actions = @{
    @"menu" : @(LibretroFrontendActionMenu),
    @"quickSave" : @(LibretroFrontendActionQuickSave),
    @"quickLoad" : @(LibretroFrontendActionQuickLoad),
    @"fastForward" : @(LibretroFrontendActionFastForward),
    @"toggleFastForward" : @(LibretroFrontendActionToggleFastForward),
    @"swapScreens" : @(LibretroFrontendActionSwapScreens),
  };
  for (NSString *console in consoles) {
    LibretroInputMap *map = [LibretroInputMap mapForConsole:console];
    NSArray *table = expected[console];
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (NSArray *row in table) [names addObject:row[0]];
    CHECK([map.console isEqualToString:console], @"%@: map keeps its console id", console);
    CHECK([map.buttons isEqualToArray:names], @"%@: buttons %@", console, [names componentsJoinedByString:@" "]);
    for (NSArray *row in table) {
      NSString *name = row[0];
      int joypad = [row[2] intValue];
      CHECK([[map glyphForInput:name] isEqualToString:row[1]], @"%@: %@ is printed %@", console, name, row[1]);
      if (joypad >= 0) {
        CHECK(IsButton([map targetForInput:name], (unsigned)joypad), @"%@: %@ -> RetroPad %d", console, name, joypad);
      }
      CHECK([[map canonicalInput:name] isEqualToString:name], @"%@: %@ is canonical", console, name);
    }
    const unsigned directions[4] = {RETRO_DEVICE_ID_JOYPAD_UP, RETRO_DEVICE_ID_JOYPAD_DOWN,
                                    RETRO_DEVICE_ID_JOYPAD_LEFT, RETRO_DEVICE_ID_JOYPAD_RIGHT};
    NSArray<NSString *> *directionNames = @[ @"up", @"down", @"left", @"right" ];
    NSArray<NSString *> *directionKeys = @[ @"inputUp", @"inputDown", @"inputLeft", @"inputRight" ];
    for (NSUInteger index = 0; index < 4; index++) {
      NSString *name = directionNames[index];
      CHECK(IsButton([map targetForInput:name], directions[index]) && [map glyphForInput:name] == nil &&
                [[map labelKeyForInput:name] isEqualToString:directionKeys[index]],
            @"%@: %@ is the D-pad direction, labelled %@", console, name, directionKeys[index]);
    }
    for (NSString *action in actions) {
      LibretroInputTarget target = [map targetForInput:action];
      CHECK(IsAction(target, (LibretroFrontendAction)actions[action].integerValue) &&
                [map glyphForInput:action] == nil && [map labelKeyForInput:action] != nil,
            @"%@: %@ is a frontend action", console, action);
    }

    BOOL hasLeft = [leftStick containsObject:console];
    BOOL hasRight = [console isEqualToString:@"3ds"];
    BOOL hasTouch = [touch containsObject:console];
    CHECK(map.hasLeftStick == hasLeft && map.hasRightStick == hasRight && map.hasTouchScreen == hasTouch,
          @"%@: sticks and touch screen flags", console);
    NSArray<NSString *> *left = StickInputs(@"leftStick");
    NSArray<NSString *> *right = StickInputs(@"rightStick");
    const unsigned axes[4] = {1, 1, 0, 0};
    const int signs[4] = {-1, 1, -1, 1};
    for (NSUInteger index = 0; index < 4; index++) {
      LibretroInputTarget leftTarget = [map targetForInput:left[index]];
      LibretroInputTarget rightTarget = [map targetForInput:right[index]];
      CHECK(hasLeft ? IsAnalog(leftTarget, 0, axes[index], signs[index]) : IsNone(leftTarget),
            @"%@: %@ %@", console, left[index], hasLeft ? @"drives the left analog stick" : @"is not available");
      CHECK(hasRight ? IsAnalog(rightTarget, 1, axes[index], signs[index]) : IsNone(rightTarget),
            @"%@: %@ %@", console, right[index], hasRight ? @"drives the right analog stick" : @"is not available");
      if (hasLeft) {
        CHECK([[map labelKeyForInput:left[index]] isEqualToString:@"inputLeftStick"] &&
                  [map glyphForInput:left[index]] == nil,
              @"%@: %@ is labelled as the left stick", console, left[index]);
      }
    }
    LibretroInputTarget touchTarget = [map targetForInput:@"touchScreen"];
    CHECK(hasTouch ? touchTarget.kind == LibretroInputTargetPointer : IsNone(touchTarget),
          @"%@: touch screen %@", console, hasTouch ? @"goes to the pointer" : @"is not available");
    if (hasTouch) {
      CHECK([[map labelKeyForInput:@"touchScreen"] isEqualToString:@"inputTouchScreen"] &&
                [map glyphForInput:@"touchScreen"] == nil,
            @"%@: touch screen label", console);
    }

    uint16_t blocked = 0;
    if ([console isEqualToString:@"nds"]) blocked = BIT(R3);
    if ([console isEqualToString:@"3ds"]) blocked = BIT(L3) | BIT(R3);
    CHECK(map.blockedButtons == blocked, @"%@: blocked RetroPad buttons 0x%04x", console, (unsigned)blocked);

    // Controller defaults: identical to the historical positional mapping
    // (RetroPad id of each element), except blocked ids, which send nothing.
    for (NSString *element in LibretroGamepadElements()) {
      int passthrough = LibretroGamepadPassthroughButton(element);
      LibretroInputTarget target = [map gamepadTargetForElement:element overrides:nil];
      BOOL isBlocked = (blocked & (1u << passthrough)) != 0;
      CHECK(isBlocked ? IsNone(target) : IsButton(target, (unsigned)passthrough),
            @"%@: %@ %@", console, element,
            isBlocked ? @"sends nothing (blocked)" : @"keeps its historical RetroPad id");
      NSString *input = [map defaultInputForGamepadElement:element];
      if (input != nil) {
        CHECK(!isBlocked && IsButton([map targetForInput:input], (unsigned)passthrough),
              @"%@: %@ defaults to %@ with the same RetroPad id", console, element, input);
      }
    }
  }
}

static void TestBlockedButtons(void) {
  LibretroInputMap *nds = [LibretroInputMap mapForConsole:@"nds"];
  CHECK(![nds.buttons containsObject:@"r3"] && IsNone([nds targetForInput:@"r3"]) && [nds canonicalInput:@"r3"] == nil,
        @"nds: r3 (DeSmuME screen switch) is absent");
  CHECK([nds defaultInputForGamepadElement:@"rightThumbstickButton"] == nil &&
            IsNone([nds gamepadTargetForElement:@"rightThumbstickButton" overrides:nil]),
        @"nds: right thumbstick button sends nothing");
  CHECK(IsButton([nds gamepadTargetForElement:@"leftThumbstickButton" overrides:nil], RETRO_DEVICE_ID_JOYPAD_L3) &&
            IsButton([nds gamepadTargetForElement:@"leftTrigger" overrides:nil], RETRO_DEVICE_ID_JOYPAD_L2),
        @"nds: microphone (L3) and lid (L2) still pass through");
  LibretroInputMap *threeDS = [LibretroInputMap mapForConsole:@"3ds"];
  for (NSString *raw in @[ @"l3", @"r3", @"L3", @"home", @"homeMenu" ]) {
    CHECK([threeDS canonicalInput:raw] == nil, @"3ds: %@ is refused (HOME, screen swap, touch tap)", raw);
  }
  CHECK(![threeDS.buttons containsObject:@"l3"] && ![threeDS.buttons containsObject:@"r3"] &&
            IsNone([threeDS targetForInput:@"l3"]) && IsNone([threeDS targetForInput:@"r3"]),
        @"3ds: l3 and r3 are absent");
  CHECK([threeDS defaultInputForGamepadElement:@"leftThumbstickButton"] == nil &&
            [threeDS defaultInputForGamepadElement:@"rightThumbstickButton"] == nil &&
            IsNone([threeDS gamepadTargetForElement:@"leftThumbstickButton" overrides:nil]) &&
            IsNone([threeDS gamepadTargetForElement:@"rightThumbstickButton" overrides:nil]),
        @"3ds: thumbstick buttons send nothing");
  CHECK(IsButton([threeDS gamepadTargetForElement:@"buttonA" overrides:@{@"buttonA" : @"l3"}],
                 RETRO_DEVICE_ID_JOYPAD_B),
        @"3ds: a remap to l3 is ignored (default kept)");
  LibretroCoreInput state = {0, {{0, 0}, {0, 0}}};
  [threeDS applyInput:@"l3" magnitude:1 toState:&state];
  [threeDS applyInput:@"r3" magnitude:1 toState:&state];
  [nds applyInput:@"r3" magnitude:1 toState:&state];
  CHECK(state.buttons == 0, @"blocked buttons are never set in the core input");
}

static void TestDefaultsPerConsole(void) {
  LibretroInputMap *n64 = [LibretroInputMap mapForConsole:@"n64"];
  NSDictionary<NSString *, NSString *> *n64Defaults = @{
    @"buttonA" : @"a",
    @"buttonX" : @"b",
    @"leftTrigger" : @"z",
    @"leftShoulder" : @"l",
    @"rightShoulder" : @"r",
    @"buttonMenu" : @"start",
    @"dpadUp" : @"up",
  };
  for (NSString *element in n64Defaults) {
    CHECK([[n64 defaultInputForGamepadElement:element] isEqualToString:n64Defaults[element]],
          @"n64: %@ is N64 %@ as before", element, n64Defaults[element]);
  }
  for (NSString *element in @[ @"buttonB", @"buttonY", @"rightTrigger", @"buttonOptions", @"leftThumbstickButton" ]) {
    CHECK([n64 defaultInputForGamepadElement:element] == nil &&
              IsButton([n64 gamepadTargetForElement:element overrides:nil],
                       (unsigned)LibretroGamepadPassthroughButton(element)),
          @"n64: %@ passes its RetroPad id through (core C-button functions)", element);
  }

  LibretroInputMap *psp = [LibretroInputMap mapForConsole:@"psp"];
  NSDictionary<NSString *, NSString *> *pspGlyphs =
      @{@"buttonA" : @"✕", @"buttonB" : @"○", @"buttonX" : @"□", @"buttonY" : @"△"};
  for (NSString *element in pspGlyphs) {
    NSString *input = [psp defaultInputForGamepadElement:element];
    CHECK(input != nil && [[psp glyphForInput:input] isEqualToString:pspGlyphs[element]],
          @"psp: %@ is %@ (positional, Cross at the bottom)", element, pspGlyphs[element]);
  }
  CHECK(IsButton([psp targetForInput:@"b"], RETRO_DEVICE_ID_JOYPAD_B) &&
            IsButton([psp targetForInput:@"a"], RETRO_DEVICE_ID_JOYPAD_A) &&
            IsButton([psp targetForInput:@"x"], RETRO_DEVICE_ID_JOYPAD_X) &&
            IsButton([psp targetForInput:@"y"], RETRO_DEVICE_ID_JOYPAD_Y),
        @"psp: Cross = B, Circle = A, Triangle = X, Square = Y (PPSSPP libretro)");
  CHECK([[psp labelKeyForInput:@"a"] isEqualToString:@"buttonCircle"] &&
            [[psp labelKeyForInput:@"b"] isEqualToString:@"buttonCross"] &&
            [[psp labelKeyForInput:@"x"] isEqualToString:@"buttonTriangle"] &&
            [[psp labelKeyForInput:@"y"] isEqualToString:@"buttonSquare"],
        @"psp: face buttons have spoken names");
  LibretroInputMap *psx = [LibretroInputMap mapForConsole:@"psx"];
  CHECK([[psx labelKeyForInput:@"b"] isEqualToString:@"buttonCross"] && [psx labelKeyForInput:@"l"] == nil &&
            [psx labelKeyForInput:@"start"] == nil,
        @"psx: spoken names only for the symbols");

  for (NSString *console in @[ @"md", @"mcd", @"32x" ]) {
    LibretroInputMap *genesis = [LibretroInputMap mapForConsole:console];
    NSDictionary<NSString *, NSString *> *defaults = @{
      @"buttonA" : @"b",
      @"buttonB" : @"c",
      @"buttonX" : @"a",
      @"buttonY" : @"y",
      @"leftShoulder" : @"x",
      @"rightShoulder" : @"z",
      @"buttonOptions" : @"mode",
      @"buttonMenu" : @"start",
    };
    BOOL all = YES;
    for (NSString *element in defaults) {
      all = all && [[genesis defaultInputForGamepadElement:element] isEqualToString:defaults[element]];
    }
    CHECK(all, @"%@: Genesis Plus GX / PicoDrive controller layout", console);
    CHECK([genesis defaultInputForGamepadElement:@"leftTrigger"] == nil &&
              IsButton([genesis gamepadTargetForElement:@"leftTrigger" overrides:nil], RETRO_DEVICE_ID_JOYPAD_L2),
          @"%@: unmapped trigger passes through", console);
  }

  LibretroInputMap *nes = [LibretroInputMap mapForConsole:@"nes"];
  CHECK([nes defaultInputForGamepadElement:@"leftShoulder"] == nil &&
            IsButton([nes gamepadTargetForElement:@"leftShoulder" overrides:nil], RETRO_DEVICE_ID_JOYPAD_L) &&
            IsButton([nes gamepadTargetForElement:@"buttonX" overrides:nil], RETRO_DEVICE_ID_JOYPAD_Y),
        @"nes: L (FDS disk side) and Y (turbo) still pass through");
  CHECK([[nes defaultInputForGamepadElement:@"buttonA"] isEqualToString:@"b"] &&
            [[nes defaultInputForGamepadElement:@"buttonB"] isEqualToString:@"a"],
        @"nes: bottom button is B, right button is A");

  LibretroInputMap *unknown = [LibretroInputMap mapForConsole:@"pico"];
  CHECK(unknown.buttons.count == 0 && IsNone([unknown targetForInput:@"a"]) && IsNone([unknown targetForInput:@"up"]),
        @"unknown console: empty logical table");
  CHECK(IsButton([unknown gamepadTargetForElement:@"buttonA" overrides:nil], RETRO_DEVICE_ID_JOYPAD_B) &&
            IsButton([unknown gamepadTargetForElement:@"dpadLeft" overrides:nil], RETRO_DEVICE_ID_JOYPAD_LEFT) &&
            unknown.blockedButtons == 0,
        @"unknown console: controllers use the passthrough mapping");
  CHECK(IsAction([unknown targetForInput:@"menu"], LibretroFrontendActionMenu) &&
            [[unknown canonicalInput:@"Menu"] isEqualToString:@"menu"] && [unknown canonicalInput:@"a"] == nil,
        @"unknown console: frontend actions only");
}

static void TestOverrides(void) {
  LibretroInputMap *snes = [LibretroInputMap mapForConsole:@"snes"];
  CHECK(IsButton([snes gamepadTargetForElement:@"buttonA" overrides:@{@"buttonA" : @"a"}], RETRO_DEVICE_ID_JOYPAD_A),
        @"a controller button can send another logical button");
  CHECK(IsAction([snes gamepadTargetForElement:@"buttonY" overrides:@{@"buttonY" : @"menu"}],
                 LibretroFrontendActionMenu) &&
            IsAction([snes gamepadTargetForElement:@"leftTrigger" overrides:@{@"leftTrigger" : @"quickSave"}],
                     LibretroFrontendActionQuickSave) &&
            IsAction([snes gamepadTargetForElement:@"rightTrigger" overrides:@{@"rightTrigger" : @"toggleFastForward"}],
                     LibretroFrontendActionToggleFastForward),
        @"a controller button can trigger frontend actions");
  CHECK(IsButton([snes gamepadTargetForElement:@"buttonA" overrides:@{@"buttonA" : @"c"}], RETRO_DEVICE_ID_JOYPAD_B) &&
            IsButton([snes gamepadTargetForElement:@"buttonA" overrides:@{@"buttonA" : @"bogus"}],
                     RETRO_DEVICE_ID_JOYPAD_B),
        @"an override this console cannot use falls back to the default");
  NSDictionary *wrongType = @{@"buttonA" : @1};
  CHECK(IsButton([snes gamepadTargetForElement:@"buttonA" overrides:wrongType], RETRO_DEVICE_ID_JOYPAD_B),
        @"a non-string override is ignored");
  CHECK(IsButton([snes gamepadTargetForElement:@"buttonB" overrides:@{@"buttonA" : @"y"}], RETRO_DEVICE_ID_JOYPAD_A),
        @"an override only changes its own element");
  LibretroInputMap *psp = [LibretroInputMap mapForConsole:@"psp"];
  CHECK(IsButton([psp gamepadTargetForElement:@"buttonA" overrides:@{@"buttonA" : @"circle"}],
                 RETRO_DEVICE_ID_JOYPAD_A),
        @"overrides accept skin aliases");
  LibretroInputMap *n64 = [LibretroInputMap mapForConsole:@"n64"];
  CHECK(IsAnalog([n64 gamepadTargetForElement:@"buttonB" overrides:@{@"buttonB" : @"cDown"}], 1, 1, 1),
        @"a controller button can send an N64 C button (right analog)");
  LibretroInputMap *nds = [LibretroInputMap mapForConsole:@"nds"];
  CHECK(IsButton([nds gamepadTargetForElement:@"buttonA" overrides:@{@"buttonA" : @"touchScreen"}],
                 RETRO_DEVICE_ID_JOYPAD_B),
        @"a controller button cannot target the touch screen");
  CHECK(IsAction([nds gamepadTargetForElement:@"rightThumbstickButton"
                                     overrides:@{@"rightThumbstickButton" : @"swapScreens"}],
                 LibretroFrontendActionSwapScreens),
        @"a blocked element can still be given a frontend action");
}

static void TestCanonicalInputs(void) {
  LibretroInputMap *psp = [LibretroInputMap mapForConsole:@"psp"];
  NSDictionary<NSString *, NSString *> *pspAliases = @{
    @"l1" : @"l",
    @"R1" : @"r",
    @"Cross" : @"b",
    @"circle" : @"a",
    @"SQUARE" : @"y",
    @"triangle" : @"x",
    @"leftThumbstickUp" : @"leftStickUp",
    @"analogStickLeft" : @"leftStickLeft",
    @"leftanalogdown" : @"leftStickDown",
    @"LeftStickRight" : @"leftStickRight",
    @"MENU" : @"menu",
    @"quickSave" : @"quickSave",
    @"quickLoad" : @"quickLoad",
    @"fastForward" : @"fastForward",
    @"toggleFastForward" : @"toggleFastForward",
    @" start " : @"start",
  };
  for (NSString *raw in pspAliases) {
    CHECK([[psp canonicalInput:raw] isEqualToString:pspAliases[raw]], @"psp: '%@' -> %@", raw, pspAliases[raw]);
  }
  for (NSString *raw in @[ @"filters", @"touchScreenX", @"rightThumbstickUp", @"l2", @"c", @"" ]) {
    CHECK([psp canonicalInput:raw] == nil, @"psp: '%@' is not usable", raw);
  }
  LibretroInputMap *snes = [LibretroInputMap mapForConsole:@"snes"];
  CHECK([snes canonicalInput:@"cross"] == nil && [snes canonicalInput:@"triangle"] == nil &&
            [[snes canonicalInput:@"X"] isEqualToString:@"x"] && [[snes canonicalInput:@"L1"] isEqualToString:@"l"],
        @"snes: PlayStation names are refused, letters accepted");
  LibretroInputMap *n64 = [LibretroInputMap mapForConsole:@"n64"];
  NSDictionary<NSString *, NSString *> *n64Aliases = @{
    @"cUp" : @"cUp",
    @"c-up" : @"cUp",
    @"C-Down" : @"cDown",
    @"cleft" : @"cLeft",
    @"C▶" : @"cRight",
    @"c▲" : @"cUp",
    @"analogStickUp" : @"leftStickUp",
    @"z" : @"z",
  };
  for (NSString *raw in n64Aliases) {
    CHECK([[n64 canonicalInput:raw] isEqualToString:n64Aliases[raw]], @"n64: '%@' -> %@", raw, n64Aliases[raw]);
  }
  CHECK([n64 canonicalInput:@"select"] == nil && [n64 canonicalInput:@"x"] == nil, @"n64: no select, no x");
  LibretroInputMap *nds = [LibretroInputMap mapForConsole:@"nds"];
  NSDictionary<NSString *, NSString *> *ndsAliases = @{
    @"touchScreenX" : @"touchScreen",
    @"touchScreenY" : @"touchScreen",
    @"screenSwap" : @"swapScreens",
    @"reverseScreens" : @"swapScreens",
    @"swapScreens" : @"swapScreens",
  };
  for (NSString *raw in ndsAliases) {
    CHECK([[nds canonicalInput:raw] isEqualToString:ndsAliases[raw]], @"nds: '%@' -> %@", raw, ndsAliases[raw]);
  }
  LibretroInputMap *threeDS = [LibretroInputMap mapForConsole:@"3ds"];
  CHECK([[threeDS canonicalInput:@"rightThumbstickDown"] isEqualToString:@"rightStickDown"] &&
            [[threeDS canonicalInput:@"leftThumbstickLeft"] isEqualToString:@"leftStickLeft"] &&
            [[threeDS canonicalInput:@"touchScreenY"] isEqualToString:@"touchScreen"] &&
            [[threeDS canonicalInput:@"l2"] isEqualToString:@"l2"],
        @"3ds: Circle Pad, C-Stick, touch screen and ZL");
  LibretroInputMap *md = [LibretroInputMap mapForConsole:@"md"];
  CHECK([[md canonicalInput:@"C"] isEqualToString:@"c"] && [[md canonicalInput:@"mode"] isEqualToString:@"mode"] &&
            [md canonicalInput:@"select"] == nil,
        @"md: C and MODE, no select");
  LibretroInputMap *sms = [LibretroInputMap mapForConsole:@"sms"];
  CHECK([sms canonicalInput:@"select"] == nil && [sms canonicalInput:@"x"] == nil &&
            [[sms canonicalInput:@"b"] isEqualToString:@"b"],
        @"sms: buttons 1 and 2 and start only");
}

static void TestApplyInput(void) {
  LibretroInputMap *snes = [LibretroInputMap mapForConsole:@"snes"];
  LibretroCoreInput state = {0, {{0, 0}, {0, 0}}};
  [snes applyInput:@"a" magnitude:1 toState:&state];
  [snes applyInput:@"b" magnitude:0 toState:&state];
  [snes applyInput:@"up" magnitude:1 toState:&state];
  CHECK(state.buttons == (BIT(A) | BIT(B) | BIT(UP)), @"buttons are OR-ed");
  [snes applyInput:@"menu" magnitude:1 toState:&state];
  [snes applyInput:@"bogus" magnitude:1 toState:&state];
  [snes applyInput:@"leftStickUp" magnitude:1 toState:&state];
  CHECK(state.buttons == (BIT(A) | BIT(B) | BIT(UP)) && state.analog[0][1] == 0,
        @"actions, unknown and unavailable inputs change nothing");

  LibretroInputMap *n64 = [LibretroInputMap mapForConsole:@"n64"];
  LibretroCoreInput analog = {0, {{0, 0}, {0, 0}}};
  [n64 applyInput:@"cUp" magnitude:0 toState:&analog];
  CHECK(analog.analog[1][1] == -0x7fff && analog.buttons == 0, @"magnitude 0 means full deflection");
  [n64 applyInput:@"cRight" magnitude:0.5 toState:&analog];
  CHECK(analog.analog[1][0] == 16384, @"magnitude scales the axis");
  [n64 applyInput:@"leftStickDown" magnitude:0.25 toState:&analog];
  CHECK(analog.analog[0][1] == 8192, @"left stick down is positive y");
  [n64 applyInput:@"leftStickLeft" magnitude:3 toState:&analog];
  CHECK(analog.analog[0][0] == -0x7fff, @"magnitude is clamped to 1");
  [n64 applyInput:@"leftStickUp" magnitude:-0.5 toState:&analog];
  CHECK(analog.analog[0][1] < 0, @"a signed value never inverts the direction");

  LibretroInputMap *nds = [LibretroInputMap mapForConsole:@"nds"];
  LibretroCoreInput touch = {0, {{0, 0}, {0, 0}}};
  [nds applyInput:@"touchScreen" magnitude:1 toState:&touch];
  CHECK(touch.buttons == 0 && touch.analog[0][0] == 0 && touch.analog[1][1] == 0, @"the pointer is not a button");

  LibretroInputMap *threeDS = [LibretroInputMap mapForConsole:@"3ds"];
  LibretroCoreInput sticks = {0, {{0, 0}, {0, 0}}};
  [threeDS applyInput:@"rightStickLeft" magnitude:1 toState:&sticks];
  [threeDS applyInput:@"leftStickRight" magnitude:1 toState:&sticks];
  [threeDS applyInput:@"l2" magnitude:1 toState:&sticks];
  CHECK(sticks.analog[1][0] == -0x7fff && sticks.analog[0][0] == 0x7fff && sticks.buttons == BIT(L2),
        @"3ds: C-Stick, Circle Pad and ZL");
}

static void TestLabels(void) {
  LibretroInputMap *snes = [LibretroInputMap mapForConsole:@"snes"];
  CHECK([snes labelKeyForInput:@"a"] == nil && [snes labelKeyForInput:@"start"] == nil,
        @"letters and START need no spoken name");
  NSDictionary<NSString *, NSString *> *actionKeys = @{
    @"menu" : @"inputMenu",
    @"quickSave" : @"inputQuickSave",
    @"quickLoad" : @"inputQuickLoad",
    @"fastForward" : @"inputFastForward",
    @"toggleFastForward" : @"inputToggleFastForward",
    @"swapScreens" : @"swapScreens",
  };
  for (NSString *action in actionKeys) {
    CHECK([[snes labelKeyForInput:action] isEqualToString:actionKeys[action]], @"%@ is labelled %@", action,
          actionKeys[action]);
  }
  LibretroInputMap *threeDS = [LibretroInputMap mapForConsole:@"3ds"];
  CHECK([[threeDS labelKeyForInput:@"rightStickLeft"] isEqualToString:@"inputRightStick"] &&
            [[threeDS glyphForInput:@"l2"] isEqualToString:@"ZL"] && [threeDS glyphForInput:@"rightStickUp"] == nil,
        @"3ds: C-Stick label and ZL glyph");
  LibretroInputMap *n64 = [LibretroInputMap mapForConsole:@"n64"];
  CHECK([n64 labelKeyForInput:@"cUp"] == nil && [[n64 glyphForInput:@"cUp"] isEqualToString:@"C▲"],
        @"n64: C buttons are named by their glyph");
  CHECK([snes glyphForInput:@"bogus"] == nil && [snes labelKeyForInput:@"bogus"] == nil &&
            [snes glyphForInput:@"c"] == nil,
        @"unknown inputs have neither glyph nor label");
}

int main(int argc, const char *argv[]) {
  @autoreleasepool {
    TestElements();
    TestConsoleTables();
    TestBlockedButtons();
    TestDefaultsPerConsole();
    TestOverrides();
    TestCanonicalInputs();
    TestApplyInput();
    TestLabels();
  }
  if (failures > 0) {
    printf("%d input map check(s) failed\n", failures);
    return 1;
  }
  printf("All input map checks passed\n");
  return 0;
}
