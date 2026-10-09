#import "LibretroInputMap.h"

#include <math.h>

#include "libretro.h"

#define JOYPAD_BIT(identifier) ((uint16_t)(1u << (identifier)))

static const double kAnalogScale = 0x7fff;

NSArray<NSString *> *LibretroGamepadElements(void) {
  return @[
    @"buttonA", @"buttonB", @"buttonX", @"buttonY", @"leftShoulder", @"rightShoulder", @"leftTrigger",
    @"rightTrigger", @"leftThumbstickButton", @"rightThumbstickButton", @"buttonOptions", @"buttonMenu", @"dpadUp",
    @"dpadDown", @"dpadLeft", @"dpadRight"
  ];
}

int LibretroGamepadPassthroughButton(NSString *element) {
  static NSDictionary<NSString *, NSNumber *> *table;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    // RetroPad follows the SNES layout: B bottom, A right, Y left, X top.
    table = @{
      @"buttonA" : @(RETRO_DEVICE_ID_JOYPAD_B),
      @"buttonB" : @(RETRO_DEVICE_ID_JOYPAD_A),
      @"buttonX" : @(RETRO_DEVICE_ID_JOYPAD_Y),
      @"buttonY" : @(RETRO_DEVICE_ID_JOYPAD_X),
      @"leftShoulder" : @(RETRO_DEVICE_ID_JOYPAD_L),
      @"rightShoulder" : @(RETRO_DEVICE_ID_JOYPAD_R),
      @"leftTrigger" : @(RETRO_DEVICE_ID_JOYPAD_L2),
      @"rightTrigger" : @(RETRO_DEVICE_ID_JOYPAD_R2),
      @"leftThumbstickButton" : @(RETRO_DEVICE_ID_JOYPAD_L3),
      @"rightThumbstickButton" : @(RETRO_DEVICE_ID_JOYPAD_R3),
      @"buttonOptions" : @(RETRO_DEVICE_ID_JOYPAD_SELECT),
      @"buttonMenu" : @(RETRO_DEVICE_ID_JOYPAD_START),
      @"dpadUp" : @(RETRO_DEVICE_ID_JOYPAD_UP),
      @"dpadDown" : @(RETRO_DEVICE_ID_JOYPAD_DOWN),
      @"dpadLeft" : @(RETRO_DEVICE_ID_JOYPAD_LEFT),
      @"dpadRight" : @(RETRO_DEVICE_ID_JOYPAD_RIGHT),
    };
  });
  NSNumber *identifier = [element isKindOfClass:[NSString class]] ? table[element] : nil;
  return identifier != nil ? identifier.intValue : -1;
}

#pragma mark - Targets

static LibretroInputTarget NoTarget(void) {
  LibretroInputTarget target = {LibretroInputTargetNone, 0, 0, 0, 0, LibretroFrontendActionNone};
  return target;
}

static LibretroInputTarget ButtonTarget(unsigned identifier) {
  LibretroInputTarget target = NoTarget();
  target.kind = LibretroInputTargetButton;
  target.identifier = identifier;
  return target;
}

static LibretroInputTarget AnalogTarget(unsigned stick, unsigned axis, int sign) {
  LibretroInputTarget target = NoTarget();
  target.kind = LibretroInputTargetAnalog;
  target.stick = stick;
  target.axis = axis;
  target.sign = sign;
  return target;
}

static LibretroInputTarget PointerTarget(void) {
  LibretroInputTarget target = NoTarget();
  target.kind = LibretroInputTargetPointer;
  return target;
}

static LibretroInputTarget ActionTarget(LibretroFrontendAction action) {
  LibretroInputTarget target = NoTarget();
  target.kind = LibretroInputTargetAction;
  target.action = action;
  return target;
}

static NSValue *BoxTarget(LibretroInputTarget target) {
  return [NSValue valueWithBytes:&target objCType:@encode(LibretroInputTarget)];
}

static LibretroInputTarget UnboxTarget(NSValue *value) {
  LibretroInputTarget target = NoTarget();
  [value getValue:&target size:sizeof(target)];
  return target;
}

#pragma mark - Names

static NSArray<NSString *> *DirectionSuffixes(void) {
  return @[ @"Up", @"Down", @"Left", @"Right" ];
}

/// Frontend actions, valid for every console and never sent to the core.
static NSDictionary<NSString *, NSNumber *> *ActionNames(void) {
  static NSDictionary<NSString *, NSNumber *> *actions;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    actions = @{
      @"menu" : @(LibretroFrontendActionMenu),
      @"quickSave" : @(LibretroFrontendActionQuickSave),
      @"quickLoad" : @(LibretroFrontendActionQuickLoad),
      @"fastForward" : @(LibretroFrontendActionFastForward),
      @"toggleFastForward" : @(LibretroFrontendActionToggleFastForward),
      @"swapScreens" : @(LibretroFrontendActionSwapScreens),
    };
  });
  return actions;
}

/// Lowercase raw skin input -> canonical logical name, for every console.
/// Whether the console can use the result is decided by its own table.
static NSDictionary<NSString *, NSString *> *AliasTable(void) {
  static NSDictionary<NSString *, NSString *> *table;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    NSMutableDictionary<NSString *, NSString *> *aliases = [NSMutableDictionary dictionary];
    NSArray<NSString *> *canonical = @[
      @"up", @"down", @"left", @"right", @"a", @"b", @"c", @"x", @"y", @"z", @"l", @"r", @"l2", @"r2", @"l3", @"r3",
      @"start", @"select", @"mode", @"cUp", @"cDown", @"cLeft", @"cRight", @"touchScreen"
    ];
    for (NSString *name in canonical) aliases[name.lowercaseString] = name;
    for (NSString *name in ActionNames()) aliases[name.lowercaseString] = name;
    for (NSString *suffix in DirectionSuffixes()) {
      NSString *left = [@"leftStick" stringByAppendingString:suffix];
      NSString *right = [@"rightStick" stringByAppendingString:suffix];
      aliases[left.lowercaseString] = left;
      aliases[right.lowercaseString] = right;
      aliases[[@"analogstick" stringByAppendingString:suffix.lowercaseString]] = left;
      aliases[[@"leftthumbstick" stringByAppendingString:suffix.lowercaseString]] = left;
      aliases[[@"leftanalog" stringByAppendingString:suffix.lowercaseString]] = left;
      aliases[[@"rightthumbstick" stringByAppendingString:suffix.lowercaseString]] = right;
      NSString *cButton = [@"c" stringByAppendingString:suffix];
      aliases[[@"c-" stringByAppendingString:suffix.lowercaseString]] = cButton;
    }
    aliases[@"c▲"] = @"cUp";
    aliases[@"c▼"] = @"cDown";
    aliases[@"c◀"] = @"cLeft";
    aliases[@"c▶"] = @"cRight";
    aliases[@"l1"] = @"l";
    aliases[@"r1"] = @"r";
    aliases[@"cross"] = @"b";
    aliases[@"circle"] = @"a";
    aliases[@"square"] = @"y";
    aliases[@"triangle"] = @"x";
    aliases[@"touchscreenx"] = @"touchScreen";
    aliases[@"touchscreeny"] = @"touchScreen";
    aliases[@"screenswap"] = @"swapScreens";
    aliases[@"reversescreens"] = @"swapScreens";
    table = [aliases copy];
  });
  return table;
}

/// Aliases that name PlayStation face buttons; other consoles refuse them.
static NSSet<NSString *> *PlayStationAliases(void) {
  static NSSet<NSString *> *aliases;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    aliases = [NSSet setWithArray:@[ @"cross", @"circle", @"square", @"triangle" ]];
  });
  return aliases;
}

#pragma mark - Map

@interface LibretroInputMap ()
- (instancetype)initWithConsole:(NSString *)console;
@end

@implementation LibretroInputMap {
  NSDictionary<NSString *, NSValue *> *_targets;
  NSDictionary<NSString *, NSString *> *_glyphs;
  NSDictionary<NSNumber *, NSString *> *_inputForJoypad;
  BOOL _playStation;
}

+ (NSArray<NSString *> *)consoles {
  return @[
    @"nes", @"snes", @"gb", @"gbc", @"gba", @"md", @"mcd", @"32x", @"sms", @"gg", @"sg1000", @"arcade", @"nds",
    @"n64", @"psx", @"psp", @"3ds"
  ];
}

+ (instancetype)mapForConsole:(NSString *)console {
  static NSMutableDictionary<NSString *, LibretroInputMap *> *cache;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    cache = [NSMutableDictionary dictionary];
  });
  NSString *key = [console isKindOfClass:[NSString class]] ? console : @"";
  @synchronized(cache) {
    LibretroInputMap *map = cache[key];
    if (map == nil) {
      map = [[LibretroInputMap alloc] initWithConsole:key];
      cache[key] = map;
    }
    return map;
  }
}

- (instancetype)initWithConsole:(NSString *)console {
  self = [super init];
  if (self == nil) return nil;
  _console = [console copy];
  NSMutableDictionary<NSString *, NSValue *> *targets = [NSMutableDictionary dictionary];
  NSMutableDictionary<NSString *, NSString *> *glyphs = [NSMutableDictionary dictionary];
  NSMutableArray<NSString *> *buttons = [NSMutableArray array];
  void (^button)(NSString *, NSString *, unsigned) = ^(NSString *name, NSString *glyph, unsigned identifier) {
    targets[name] = BoxTarget(ButtonTarget(identifier));
    glyphs[name] = glyph;
    [buttons addObject:name];
  };
  void (^stick)(NSString *, unsigned) = ^(NSString *prefix, unsigned index) {
    targets[[prefix stringByAppendingString:@"Up"]] = BoxTarget(AnalogTarget(index, 1, -1));
    targets[[prefix stringByAppendingString:@"Down"]] = BoxTarget(AnalogTarget(index, 1, 1));
    targets[[prefix stringByAppendingString:@"Left"]] = BoxTarget(AnalogTarget(index, 0, -1));
    targets[[prefix stringByAppendingString:@"Right"]] = BoxTarget(AnalogTarget(index, 0, 1));
  };

  BOOL known = [[LibretroInputMap consoles] containsObject:console];
  _playStation = [console isEqualToString:@"psx"] || [console isEqualToString:@"psp"];
  if (known) {
    targets[@"up"] = BoxTarget(ButtonTarget(RETRO_DEVICE_ID_JOYPAD_UP));
    targets[@"down"] = BoxTarget(ButtonTarget(RETRO_DEVICE_ID_JOYPAD_DOWN));
    targets[@"left"] = BoxTarget(ButtonTarget(RETRO_DEVICE_ID_JOYPAD_LEFT));
    targets[@"right"] = BoxTarget(ButtonTarget(RETRO_DEVICE_ID_JOYPAD_RIGHT));
  }
  NSSet<NSString *> *nintendo = [NSSet setWithArray:@[ @"nes", @"gb", @"gbc", @"gba", @"snes", @"nds" ]];
  NSSet<NSString *> *genesis = [NSSet setWithArray:@[ @"md", @"mcd", @"32x" ]];
  NSSet<NSString *> *masterSystem = [NSSet setWithArray:@[ @"sms", @"gg", @"sg1000" ]];
  if ([nintendo containsObject:console]) {
    BOOL fourFace = [console isEqualToString:@"snes"] || [console isEqualToString:@"nds"];
    BOOL shoulders = fourFace || [console isEqualToString:@"gba"];
    button(@"a", @"A", RETRO_DEVICE_ID_JOYPAD_A);
    button(@"b", @"B", RETRO_DEVICE_ID_JOYPAD_B);
    if (fourFace) {
      button(@"x", @"X", RETRO_DEVICE_ID_JOYPAD_X);
      button(@"y", @"Y", RETRO_DEVICE_ID_JOYPAD_Y);
    }
    if (shoulders) {
      button(@"l", @"L", RETRO_DEVICE_ID_JOYPAD_L);
      button(@"r", @"R", RETRO_DEVICE_ID_JOYPAD_R);
    }
    button(@"start", @"START", RETRO_DEVICE_ID_JOYPAD_START);
    button(@"select", @"SELECT", RETRO_DEVICE_ID_JOYPAD_SELECT);
    if ([console isEqualToString:@"nds"]) {
      targets[@"touchScreen"] = BoxTarget(PointerTarget());
      _hasTouchScreen = YES;
      // DeSmuME's R3 is "Quick Screen Switch".
      _blockedButtons = JOYPAD_BIT(RETRO_DEVICE_ID_JOYPAD_R3);
    }
  } else if ([genesis containsObject:console]) {
    // Genesis Plus GX and PicoDrive use the same RetroPad layout.
    button(@"a", @"A", RETRO_DEVICE_ID_JOYPAD_Y);
    button(@"b", @"B", RETRO_DEVICE_ID_JOYPAD_B);
    button(@"c", @"C", RETRO_DEVICE_ID_JOYPAD_A);
    button(@"x", @"X", RETRO_DEVICE_ID_JOYPAD_L);
    button(@"y", @"Y", RETRO_DEVICE_ID_JOYPAD_X);
    button(@"z", @"Z", RETRO_DEVICE_ID_JOYPAD_R);
    button(@"start", @"START", RETRO_DEVICE_ID_JOYPAD_START);
    button(@"mode", @"MODE", RETRO_DEVICE_ID_JOYPAD_SELECT);
  } else if ([masterSystem containsObject:console]) {
    button(@"b", @"1", RETRO_DEVICE_ID_JOYPAD_B);
    button(@"a", @"2", RETRO_DEVICE_ID_JOYPAD_A);
    button(@"start", @"START", RETRO_DEVICE_ID_JOYPAD_START);
  } else if ([console isEqualToString:@"arcade"]) {
    button(@"b", @"1", RETRO_DEVICE_ID_JOYPAD_B);
    button(@"a", @"2", RETRO_DEVICE_ID_JOYPAD_A);
    button(@"y", @"3", RETRO_DEVICE_ID_JOYPAD_Y);
    button(@"x", @"4", RETRO_DEVICE_ID_JOYPAD_X);
    button(@"l", @"5", RETRO_DEVICE_ID_JOYPAD_L);
    button(@"r", @"6", RETRO_DEVICE_ID_JOYPAD_R);
    button(@"select", @"COIN", RETRO_DEVICE_ID_JOYPAD_SELECT);
    button(@"start", @"START", RETRO_DEVICE_ID_JOYPAD_START);
  } else if ([console isEqualToString:@"n64"]) {
    // mupen64plus-next: RetroPad B is N64 A, Y is N64 B, L2 is Z.
    button(@"a", @"A", RETRO_DEVICE_ID_JOYPAD_B);
    button(@"b", @"B", RETRO_DEVICE_ID_JOYPAD_Y);
    button(@"z", @"Z", RETRO_DEVICE_ID_JOYPAD_L2);
    button(@"l", @"L", RETRO_DEVICE_ID_JOYPAD_L);
    button(@"r", @"R", RETRO_DEVICE_ID_JOYPAD_R);
    button(@"start", @"START", RETRO_DEVICE_ID_JOYPAD_START);
    // C buttons drive the right analog stick, as the historical overlay did.
    NSArray<NSString *> *cButtons = @[ @"cUp", @"cDown", @"cLeft", @"cRight" ];
    NSArray<NSString *> *cGlyphs = @[ @"C▲", @"C▼", @"C◀", @"C▶" ];
    const unsigned axes[4] = {1, 1, 0, 0};
    const int signs[4] = {-1, 1, -1, 1};
    for (NSUInteger index = 0; index < cButtons.count; index++) {
      targets[cButtons[index]] = BoxTarget(AnalogTarget(1, axes[index], signs[index]));
      glyphs[cButtons[index]] = cGlyphs[index];
      [buttons addObject:cButtons[index]];
    }
    stick(@"leftStick", 0);
    _hasLeftStick = YES;
  } else if ([console isEqualToString:@"psx"]) {
    // Digital pad: the core's DualShock analog mode is not selected.
    button(@"a", @"○", RETRO_DEVICE_ID_JOYPAD_A);
    button(@"b", @"✕", RETRO_DEVICE_ID_JOYPAD_B);
    button(@"x", @"△", RETRO_DEVICE_ID_JOYPAD_X);
    button(@"y", @"□", RETRO_DEVICE_ID_JOYPAD_Y);
    button(@"l", @"L1", RETRO_DEVICE_ID_JOYPAD_L);
    button(@"r", @"R1", RETRO_DEVICE_ID_JOYPAD_R);
    button(@"l2", @"L2", RETRO_DEVICE_ID_JOYPAD_L2);
    button(@"r2", @"R2", RETRO_DEVICE_ID_JOYPAD_R2);
    button(@"l3", @"L3", RETRO_DEVICE_ID_JOYPAD_L3);
    button(@"r3", @"R3", RETRO_DEVICE_ID_JOYPAD_R3);
    button(@"start", @"START", RETRO_DEVICE_ID_JOYPAD_START);
    button(@"select", @"SELECT", RETRO_DEVICE_ID_JOYPAD_SELECT);
  } else if ([console isEqualToString:@"psp"]) {
    // PPSSPP libretro: Circle = A, Cross = B, Triangle = X, Square = Y.
    button(@"a", @"○", RETRO_DEVICE_ID_JOYPAD_A);
    button(@"b", @"✕", RETRO_DEVICE_ID_JOYPAD_B);
    button(@"x", @"△", RETRO_DEVICE_ID_JOYPAD_X);
    button(@"y", @"□", RETRO_DEVICE_ID_JOYPAD_Y);
    button(@"l", @"L", RETRO_DEVICE_ID_JOYPAD_L);
    button(@"r", @"R", RETRO_DEVICE_ID_JOYPAD_R);
    button(@"start", @"START", RETRO_DEVICE_ID_JOYPAD_START);
    button(@"select", @"SELECT", RETRO_DEVICE_ID_JOYPAD_SELECT);
    stick(@"leftStick", 0);
    _hasLeftStick = YES;
  } else if ([console isEqualToString:@"3ds"]) {
    button(@"a", @"A", RETRO_DEVICE_ID_JOYPAD_A);
    button(@"b", @"B", RETRO_DEVICE_ID_JOYPAD_B);
    button(@"x", @"X", RETRO_DEVICE_ID_JOYPAD_X);
    button(@"y", @"Y", RETRO_DEVICE_ID_JOYPAD_Y);
    button(@"l", @"L", RETRO_DEVICE_ID_JOYPAD_L);
    button(@"r", @"R", RETRO_DEVICE_ID_JOYPAD_R);
    button(@"l2", @"ZL", RETRO_DEVICE_ID_JOYPAD_L2);
    button(@"r2", @"ZR", RETRO_DEVICE_ID_JOYPAD_R2);
    button(@"start", @"START", RETRO_DEVICE_ID_JOYPAD_START);
    button(@"select", @"SELECT", RETRO_DEVICE_ID_JOYPAD_SELECT);
    stick(@"leftStick", 0);   // Circle Pad
    stick(@"rightStick", 1);  // C-Stick
    targets[@"touchScreen"] = BoxTarget(PointerTarget());
    _hasLeftStick = YES;
    _hasRightStick = YES;
    _hasTouchScreen = YES;
    // Azahar: L3 is HOME and swaps the screens, R3 taps the touch screen.
    _blockedButtons = JOYPAD_BIT(RETRO_DEVICE_ID_JOYPAD_L3) | JOYPAD_BIT(RETRO_DEVICE_ID_JOYPAD_R3);
  }
  NSDictionary<NSString *, NSNumber *> *actions = ActionNames();
  for (NSString *name in actions) {
    targets[name] = BoxTarget(ActionTarget((LibretroFrontendAction)actions[name].integerValue));
  }

  NSMutableDictionary<NSNumber *, NSString *> *inputForJoypad = [NSMutableDictionary dictionary];
  for (NSString *name in targets) {
    LibretroInputTarget target = UnboxTarget(targets[name]);
    if (target.kind == LibretroInputTargetButton) inputForJoypad[@(target.identifier)] = name;
  }
  _targets = [targets copy];
  _glyphs = [glyphs copy];
  _buttons = [buttons copy];
  _inputForJoypad = [inputForJoypad copy];
  return self;
}

- (NSString *)glyphForInput:(NSString *)input {
  if (![input isKindOfClass:[NSString class]]) return nil;
  return _glyphs[input];
}

- (NSString *)labelKeyForInput:(NSString *)input {
  LibretroInputTarget target = [self targetForInput:input];
  switch (target.kind) {
    case LibretroInputTargetNone:
      return nil;
    case LibretroInputTargetPointer:
      return @"inputTouchScreen";
    case LibretroInputTargetAction:
      switch (target.action) {
        case LibretroFrontendActionMenu:
          return @"inputMenu";
        case LibretroFrontendActionQuickSave:
          return @"inputQuickSave";
        case LibretroFrontendActionQuickLoad:
          return @"inputQuickLoad";
        case LibretroFrontendActionFastForward:
          return @"inputFastForward";
        case LibretroFrontendActionToggleFastForward:
          return @"inputToggleFastForward";
        case LibretroFrontendActionSwapScreens:
          return @"swapScreens";
        case LibretroFrontendActionNone:
          return nil;
      }
      return nil;
    case LibretroInputTargetAnalog:
      if ([input hasPrefix:@"leftStick"]) return @"inputLeftStick";
      if ([input hasPrefix:@"rightStick"]) return @"inputRightStick";
      return nil;  // N64 C buttons: the glyph is the name.
    case LibretroInputTargetButton:
      break;
  }
  NSDictionary<NSString *, NSString *> *directions =
      @{@"up" : @"inputUp", @"down" : @"inputDown", @"left" : @"inputLeft", @"right" : @"inputRight"};
  NSString *direction = directions[input];
  if (direction != nil) return direction;
  if (_playStation) {
    NSDictionary<NSString *, NSString *> *faces =
        @{@"a" : @"buttonCircle", @"b" : @"buttonCross", @"x" : @"buttonTriangle", @"y" : @"buttonSquare"};
    return faces[input];
  }
  return nil;
}

- (NSString *)canonicalInput:(NSString *)raw {
  if (![raw isKindOfClass:[NSString class]]) return nil;
  NSCharacterSet *spaces = [NSCharacterSet whitespaceAndNewlineCharacterSet];
  NSString *key = [raw stringByTrimmingCharactersInSet:spaces].lowercaseString;
  NSString *canonical = AliasTable()[key];
  if (canonical == nil) return nil;
  if (!_playStation && [PlayStationAliases() containsObject:key]) return nil;
  // Unusable or blocked for this console (3ds l3 / r3, nds r3...).
  if ([self targetForInput:canonical].kind == LibretroInputTargetNone) return nil;
  return canonical;
}

- (LibretroInputTarget)targetForInput:(NSString *)input {
  NSValue *value = [input isKindOfClass:[NSString class]] ? _targets[input] : nil;
  if (value == nil) return NoTarget();
  LibretroInputTarget target = UnboxTarget(value);
  if (target.kind == LibretroInputTargetButton &&
      (target.identifier > 15 || (_blockedButtons & JOYPAD_BIT(target.identifier)) != 0)) {
    return NoTarget();
  }
  return target;
}

- (void)applyInput:(NSString *)input magnitude:(double)magnitude toState:(LibretroCoreInput *)state {
  LibretroInputTarget target = [self targetForInput:input];
  if (target.kind == LibretroInputTargetButton) {
    state->buttons |= JOYPAD_BIT(target.identifier);
  } else if (target.kind == LibretroInputTargetAnalog && target.stick < 2 && target.axis < 2) {
    // A magnitude, never a signed value: the sign comes from the target.
    double amount = magnitude > 0.0 ? fmin(magnitude, 1.0) : 1.0;
    state->analog[target.stick][target.axis] = (int16_t)lround(target.sign * amount * kAnalogScale);
  }
}

- (NSString *)defaultInputForGamepadElement:(NSString *)element {
  int identifier = LibretroGamepadPassthroughButton(element);
  if (identifier < 0 || identifier > 15) return nil;
  if ((_blockedButtons & JOYPAD_BIT(identifier)) != 0) return nil;
  return _inputForJoypad[@(identifier)];
}

- (LibretroInputTarget)gamepadTargetForElement:(NSString *)element
                                     overrides:(NSDictionary<NSString *, NSString *> *)overrides {
  id choice = [element isKindOfClass:[NSString class]] ? overrides[element] : nil;
  if ([choice isKindOfClass:[NSString class]]) {
    NSString *canonical = [self canonicalInput:choice];
    LibretroInputTarget target = canonical != nil ? [self targetForInput:canonical] : NoTarget();
    // A button cannot point at the touch screen: no coordinates to send.
    if (target.kind == LibretroInputTargetButton || target.kind == LibretroInputTargetAnalog ||
        target.kind == LibretroInputTargetAction) {
      return target;
    }
  }
  NSString *input = [self defaultInputForGamepadElement:element];
  if (input != nil) return [self targetForInput:input];
  int identifier = LibretroGamepadPassthroughButton(element);
  if (identifier < 0 || identifier > 15) return NoTarget();
  if ((_blockedButtons & JOYPAD_BIT(identifier)) != 0) return NoTarget();
  // No logical input for this id: keep the historical RetroPad id so core
  // functions on extra buttons (Nestopia FDS disk side on L...) still work.
  return ButtonTarget((unsigned)identifier);
}

@end
