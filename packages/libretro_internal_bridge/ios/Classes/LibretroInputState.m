#import "LibretroInputState.h"

#import <GameController/GameController.h>

#include <os/lock.h>

static int16_t AxisValue(float value) {
  if (value > 1.0f) value = 1.0f;
  if (value < -1.0f) value = -1.0f;
  return (int16_t)(value * 32767.0f);
}

@implementation LibretroInputState {
  os_unfair_lock _lock;
  uint16_t _touchButtons;
  int16_t _touchStick[2][2];
  int16_t _pointerX;
  int16_t _pointerY;
  BOOL _pointerPressed;
  uint16_t _padButtons[LIBRETRO_MAX_PORTS];
  int16_t _padAnalog[LIBRETRO_MAX_PORTS][2][2];
  BOOL _menuChordHeld;
  BOOL _hasPhysicalController;
}

- (instancetype)init {
  self = [super init];
  if (self) _lock = OS_UNFAIR_LOCK_INIT;
  return self;
}

- (void)setTouchButtons:(uint16_t)buttons {
  os_unfair_lock_lock(&_lock);
  _touchButtons = buttons;
  os_unfair_lock_unlock(&_lock);
}

- (void)setTouchStick:(unsigned)stick x:(int16_t)x y:(int16_t)y {
  if (stick > 1) return;
  os_unfair_lock_lock(&_lock);
  _touchStick[stick][0] = x;
  _touchStick[stick][1] = y;
  os_unfair_lock_unlock(&_lock);
}

- (void)setPointerX:(int16_t)x y:(int16_t)y pressed:(BOOL)pressed {
  os_unfair_lock_lock(&_lock);
  _pointerX = x;
  _pointerY = y;
  _pointerPressed = pressed;
  os_unfair_lock_unlock(&_lock);
}

- (BOOL)hasPhysicalController {
  os_unfair_lock_lock(&_lock);
  BOOL value = _hasPhysicalController;
  os_unfair_lock_unlock(&_lock);
  return value;
}

static void SetBit(uint16_t *buttons, unsigned identifier, BOOL pressed) {
  if (pressed) *buttons |= (uint16_t)(1u << identifier);
}

- (BOOL)pollControllers {
  uint16_t buttons[LIBRETRO_MAX_PORTS] = {0};
  int16_t analog[LIBRETRO_MAX_PORTS][2][2] = {{{0}}};
  BOOL menuChord = NO;
  BOOL any = NO;
  NSUInteger port = 0;
  for (GCController *controller in GCController.controllers) {
    GCExtendedGamepad *pad = controller.extendedGamepad;
    if (pad == nil) continue;
    if (port >= LIBRETRO_MAX_PORTS) break;
    any = YES;
    uint16_t *state = &buttons[port];
    SetBit(state, RETRO_DEVICE_ID_JOYPAD_UP, pad.dpad.up.isPressed);
    SetBit(state, RETRO_DEVICE_ID_JOYPAD_DOWN, pad.dpad.down.isPressed);
    SetBit(state, RETRO_DEVICE_ID_JOYPAD_LEFT, pad.dpad.left.isPressed);
    SetBit(state, RETRO_DEVICE_ID_JOYPAD_RIGHT, pad.dpad.right.isPressed);
    // RetroPad follows the SNES layout: B bottom, A right, Y left, X top.
    SetBit(state, RETRO_DEVICE_ID_JOYPAD_B, pad.buttonA.isPressed);
    SetBit(state, RETRO_DEVICE_ID_JOYPAD_A, pad.buttonB.isPressed);
    SetBit(state, RETRO_DEVICE_ID_JOYPAD_Y, pad.buttonX.isPressed);
    SetBit(state, RETRO_DEVICE_ID_JOYPAD_X, pad.buttonY.isPressed);
    SetBit(state, RETRO_DEVICE_ID_JOYPAD_L, pad.leftShoulder.isPressed);
    SetBit(state, RETRO_DEVICE_ID_JOYPAD_R, pad.rightShoulder.isPressed);
    SetBit(state, RETRO_DEVICE_ID_JOYPAD_L2, pad.leftTrigger.isPressed);
    SetBit(state, RETRO_DEVICE_ID_JOYPAD_R2, pad.rightTrigger.isPressed);
    SetBit(state, RETRO_DEVICE_ID_JOYPAD_L3, pad.leftThumbstickButton.isPressed);
    SetBit(state, RETRO_DEVICE_ID_JOYPAD_R3, pad.rightThumbstickButton.isPressed);
    SetBit(state, RETRO_DEVICE_ID_JOYPAD_SELECT, pad.buttonOptions.isPressed);
    SetBit(state, RETRO_DEVICE_ID_JOYPAD_START, pad.buttonMenu.isPressed);
    analog[port][0][0] = AxisValue(pad.leftThumbstick.xAxis.value);
    analog[port][0][1] = AxisValue(-pad.leftThumbstick.yAxis.value);
    analog[port][1][0] = AxisValue(pad.rightThumbstick.xAxis.value);
    analog[port][1][1] = AxisValue(-pad.rightThumbstick.yAxis.value);
    BOOL home = NO;
    if (@available(iOS 14.0, *)) home = pad.buttonHome.isPressed;
    if (home || (pad.buttonOptions.isPressed && pad.buttonMenu.isPressed)) menuChord = YES;
    port++;
  }
  os_unfair_lock_lock(&_lock);
  memcpy(_padButtons, buttons, sizeof(_padButtons));
  memcpy(_padAnalog, analog, sizeof(_padAnalog));
  _hasPhysicalController = any;
  BOOL requested = menuChord && !_menuChordHeld;
  _menuChordHeld = menuChord;
  os_unfair_lock_unlock(&_lock);
  return requested;
}

- (void)snapshot:(LibretroInputSnapshot *)snapshot {
  if (snapshot == NULL) return;
  os_unfair_lock_lock(&_lock);
  for (unsigned port = 0; port < LIBRETRO_MAX_PORTS; port++) {
    snapshot->buttons[port] = _padButtons[port] | (port == 0 ? _touchButtons : 0);
    for (unsigned stick = 0; stick < 2; stick++) {
      for (unsigned axis = 0; axis < 2; axis++) {
        int16_t value = _padAnalog[port][stick][axis];
        if (port == 0 && _touchStick[stick][axis] != 0) value = _touchStick[stick][axis];
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
  _touchButtons = 0;
  memset(_touchStick, 0, sizeof(_touchStick));
  _pointerPressed = NO;
  os_unfair_lock_unlock(&_lock);
}

@end
