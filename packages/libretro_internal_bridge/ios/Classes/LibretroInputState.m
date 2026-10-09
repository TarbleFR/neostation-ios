#import "LibretroInputState.h"

#import <GameController/GameController.h>

#include <os/lock.h>
#include <string.h>

/// Physical elements a user can remap, in LibretroGamepadElements() order.
#define LIBRETRO_GAMEPAD_ELEMENT_LIMIT 32

static int16_t AxisValue(float value) {
  if (value > 1.0f) value = 1.0f;
  if (value < -1.0f) value = -1.0f;
  return (int16_t)(value * 32767.0f);
}

/// Button of `pad` for a LibretroGamepadElements() name; nil when the
/// controller has no such button (thumbstick buttons and Options are
/// optional on some controllers).
static GCControllerButtonInput *ElementButton(GCExtendedGamepad *pad, NSString *element) {
  if ([element isEqualToString:@"buttonA"]) return pad.buttonA;
  if ([element isEqualToString:@"buttonB"]) return pad.buttonB;
  if ([element isEqualToString:@"buttonX"]) return pad.buttonX;
  if ([element isEqualToString:@"buttonY"]) return pad.buttonY;
  if ([element isEqualToString:@"leftShoulder"]) return pad.leftShoulder;
  if ([element isEqualToString:@"rightShoulder"]) return pad.rightShoulder;
  if ([element isEqualToString:@"leftTrigger"]) return pad.leftTrigger;
  if ([element isEqualToString:@"rightTrigger"]) return pad.rightTrigger;
  if ([element isEqualToString:@"leftThumbstickButton"]) return pad.leftThumbstickButton;
  if ([element isEqualToString:@"rightThumbstickButton"]) return pad.rightThumbstickButton;
  if ([element isEqualToString:@"buttonOptions"]) return pad.buttonOptions;
  if ([element isEqualToString:@"buttonMenu"]) return pad.buttonMenu;
  if ([element isEqualToString:@"dpadUp"]) return pad.dpad.up;
  if ([element isEqualToString:@"dpadDown"]) return pad.dpad.down;
  if ([element isEqualToString:@"dpadLeft"]) return pad.dpad.left;
  if ([element isEqualToString:@"dpadRight"]) return pad.dpad.right;
  return nil;
}

@implementation LibretroInputState {
  // Shared with the emulation thread (under _lock).
  os_unfair_lock _lock;
  LibretroCoreInput _touch;
  int16_t _pointerX;
  int16_t _pointerY;
  BOOL _pointerPressed;
  uint16_t _padButtons[LIBRETRO_MAX_PORTS];
  int16_t _padAnalog[LIBRETRO_MAX_PORTS][2][2];
  uint16_t _blockedButtons;
  BOOL _hasPhysicalController;
  // Main thread only.
  NSArray<NSString *> *_elements;
  LibretroInputTarget _elementTargets[LIBRETRO_GAMEPAD_ELEMENT_LIMIT];
  NSUInteger _elementCount;
  NSSet<NSNumber *> *_heldActions;
  BOOL _menuChordHeld;
  BOOL _remappedMenuHeld;
  NSString *_pressedGamepadElement;
}

- (instancetype)init {
  self = [super init];
  if (self) {
    _lock = OS_UNFAIR_LOCK_INIT;
    _heldActions = [NSSet set];
    [self setInputMap:[LibretroInputMap mapForConsole:@"nes"] gamepadRemap:nil];
  }
  return self;
}

- (void)setTouchInput:(LibretroCoreInput)input {
  os_unfair_lock_lock(&_lock);
  _touch = input;
  os_unfair_lock_unlock(&_lock);
}

- (void)setPointerX:(int16_t)x y:(int16_t)y pressed:(BOOL)pressed {
  os_unfair_lock_lock(&_lock);
  _pointerX = x;
  _pointerY = y;
  _pointerPressed = pressed;
  os_unfair_lock_unlock(&_lock);
}

- (void)setInputMap:(LibretroInputMap *)inputMap gamepadRemap:(NSDictionary<NSString *, NSString *> *)remap {
  LibretroInputMap *map = inputMap ?: [LibretroInputMap mapForConsole:@"nes"];
  // Dart null arrives as NSNull: no remap then.
  NSDictionary<NSString *, NSString *> *overrides = [remap isKindOfClass:[NSDictionary class]] ? remap : nil;
  NSArray<NSString *> *elements = LibretroGamepadElements();
  NSUInteger count = MIN(elements.count, (NSUInteger)LIBRETRO_GAMEPAD_ELEMENT_LIMIT);
  for (NSUInteger index = 0; index < count; index++) {
    _elementTargets[index] = [map gamepadTargetForElement:elements[index] overrides:overrides];
  }
  _elements = [elements subarrayWithRange:NSMakeRange(0, count)];
  _elementCount = count;
  os_unfair_lock_lock(&_lock);
  _blockedButtons = map.blockedButtons;
  os_unfair_lock_unlock(&_lock);
}

- (BOOL)hasPhysicalController {
  os_unfair_lock_lock(&_lock);
  BOOL value = _hasPhysicalController;
  os_unfair_lock_unlock(&_lock);
  return value;
}

- (NSString *)pressedGamepadElement {
  return _pressedGamepadElement;
}

- (BOOL)pollControllers {
  uint16_t buttons[LIBRETRO_MAX_PORTS] = {0};
  int16_t analog[LIBRETRO_MAX_PORTS][2][2] = {{{0}}};
  BOOL menuChord = NO;
  BOOL remappedMenu = NO;
  BOOL any = NO;
  NSString *pressedElement = nil;
  NSMutableSet<NSNumber *> *actions = [NSMutableSet set];
  NSUInteger port = 0;
  for (GCController *controller in GCController.controllers) {
    GCExtendedGamepad *pad = controller.extendedGamepad;
    if (pad == nil) continue;
    if (port >= LIBRETRO_MAX_PORTS) break;
    any = YES;
    // Sticks keep their analog role: left -> analog 0, right -> analog 1,
    // Y inverted (libretro: positive is down).
    analog[port][0][0] = AxisValue(pad.leftThumbstick.xAxis.value);
    analog[port][0][1] = AxisValue(-pad.leftThumbstick.yAxis.value);
    analog[port][1][0] = AxisValue(pad.rightThumbstick.xAxis.value);
    analog[port][1][1] = AxisValue(-pad.rightThumbstick.yAxis.value);
    LibretroCoreInput remapped = {0, {{0, 0}, {0, 0}}};
    for (NSUInteger index = 0; index < _elementCount; index++) {
      GCControllerButtonInput *button = ElementButton(pad, _elements[index]);
      if (button == nil || !button.isPressed) continue;
      if (pressedElement == nil) pressedElement = _elements[index];
      LibretroInputTarget target = _elementTargets[index];
      switch (target.kind) {
        case LibretroInputTargetButton:
          if (target.identifier < 16) remapped.buttons |= (uint16_t)(1u << target.identifier);
          break;
        case LibretroInputTargetAnalog:
          if (target.stick < 2 && target.axis < 2) {
            remapped.analog[target.stick][target.axis] = target.sign < 0 ? -32767 : 32767;
          }
          break;
        case LibretroInputTargetAction:
          if (target.action == LibretroFrontendActionMenu) {
            remappedMenu = YES;
          } else if (target.action != LibretroFrontendActionNone) {
            [actions addObject:@(target.action)];
          }
          break;
        case LibretroInputTargetPointer:
        case LibretroInputTargetNone:
          break;
      }
    }
    buttons[port] = remapped.buttons;
    // A button remapped to a stick direction wins over the resting stick.
    for (unsigned stick = 0; stick < 2; stick++) {
      for (unsigned axis = 0; axis < 2; axis++) {
        if (remapped.analog[stick][axis] != 0) analog[port][stick][axis] = remapped.analog[stick][axis];
      }
    }
    BOOL home = pad.buttonHome.isPressed;
    BOOL options = pad.buttonOptions.isPressed;
    BOOL menu = pad.buttonMenu.isPressed;
    if (home || (options && menu)) menuChord = YES;
    port++;
  }

  os_unfair_lock_lock(&_lock);
  memcpy(_padButtons, buttons, sizeof(_padButtons));
  memcpy(_padAnalog, analog, sizeof(_padAnalog));
  _hasPhysicalController = any;
  os_unfair_lock_unlock(&_lock);

  BOOL requested = (menuChord && !_menuChordHeld) || (remappedMenu && !_remappedMenuHeld);
  _menuChordHeld = menuChord;
  _remappedMenuHeld = remappedMenu;
  _pressedGamepadElement = [pressedElement copy];

  // Frontend actions other than the menu: reported on press and release.
  NSSet<NSNumber *> *previous = _heldActions;
  NSSet<NSNumber *> *current = [actions copy];
  _heldActions = current;
  void (^handler)(LibretroFrontendAction, BOOL) = self.actionHandler;
  if (handler != nil) {
    for (NSNumber *action in previous) {
      if (![current containsObject:action]) handler((LibretroFrontendAction)action.integerValue, NO);
    }
    for (NSNumber *action in current) {
      if (![previous containsObject:action]) handler((LibretroFrontendAction)action.integerValue, YES);
    }
  }
  return requested;
}

- (void)snapshot:(LibretroInputSnapshot *)snapshot {
  if (snapshot == NULL) return;
  os_unfair_lock_lock(&_lock);
  uint16_t allowed = (uint16_t)~_blockedButtons;
  for (unsigned port = 0; port < LIBRETRO_MAX_PORTS; port++) {
    uint16_t buttons = _padButtons[port] | (port == 0 ? _touch.buttons : 0);
    snapshot->buttons[port] = (uint16_t)(buttons & allowed);
    for (unsigned stick = 0; stick < 2; stick++) {
      for (unsigned axis = 0; axis < 2; axis++) {
        int16_t value = _padAnalog[port][stick][axis];
        if (port == 0 && _touch.analog[stick][axis] != 0) value = _touch.analog[stick][axis];
        snapshot->analog[port][stick][axis] = value;
      }
    }
  }
  snapshot->pointerX = _pointerX;
  snapshot->pointerY = _pointerY;
  snapshot->pointerPressed = _pointerPressed;
  os_unfair_lock_unlock(&_lock);
}

- (void)reset {
  os_unfair_lock_lock(&_lock);
  memset(&_touch, 0, sizeof(_touch));
  _pointerPressed = NO;
  os_unfair_lock_unlock(&_lock);
}

@end
