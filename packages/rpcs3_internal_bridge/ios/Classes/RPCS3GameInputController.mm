#import "RPCS3GameInputController.h"

#import <GameController/GameController.h>
#import <QuartzCore/QuartzCore.h>
#include <math.h>

static const char* const kRPCS3InputMarker = "NEOSTATION_RPCS3_INPUT_V1";

static inline float RPCS3Clamp(float value, float minimum, float maximum) {
  return fminf(maximum, fmaxf(minimum, value));
}

static inline void RPCS3SetBit(uint32_t* bits, uint32_t bit, BOOL pressed) {
  if (pressed) *bits |= bit;
  else *bits &= ~bit;
}

@interface RPCS3InputPassthroughView : UIView
@end

@implementation RPCS3InputPassthroughView
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent*)event {
  if (self.hidden || self.alpha <= 0.01 || !self.userInteractionEnabled) return NO;
  for (UIView* child in self.subviews.reverseObjectEnumerator) {
    if (child.hidden || child.alpha <= 0.01 || !child.userInteractionEnabled) continue;
    CGPoint childPoint = [self convertPoint:point toView:child];
    if ([child pointInside:childPoint withEvent:event]) return YES;
  }
  return NO;
}
@end

typedef void (^RPCS3StickChanged)(float x, float y);

@interface RPCS3TouchStickView : UIView
@property(nonatomic, copy) RPCS3StickChanged valueChanged;
@property(nonatomic, strong) UIView* knob;
@property(nonatomic, assign) BOOL trackingTouch;
@end

@implementation RPCS3TouchStickView
- (instancetype)initWithFrame:(CGRect)frame {
  self = [super initWithFrame:frame];
  if (self) {
    self.multipleTouchEnabled = NO;
    self.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.34];
    self.layer.borderWidth = 1.5;
    self.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.42].CGColor;
    self.clipsToBounds = NO;

    _knob = [[UIView alloc] initWithFrame:CGRectZero];
    _knob.userInteractionEnabled = NO;
    _knob.backgroundColor = [UIColor colorWithWhite:1 alpha:0.28];
    _knob.layer.borderWidth = 1.0;
    _knob.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.55].CGColor;
    [self addSubview:_knob];
  }
  return self;
}

- (void)layoutSubviews {
  [super layoutSubviews];
  CGFloat side = MIN(self.bounds.size.width, self.bounds.size.height);
  self.layer.cornerRadius = side * 0.5;
  CGFloat knobSide = side * 0.43;
  self.knob.bounds = CGRectMake(0, 0, knobSide, knobSide);
  self.knob.layer.cornerRadius = knobSide * 0.5;
  if (!self.trackingTouch) {
    self.knob.center = CGPointMake(CGRectGetMidX(self.bounds), CGRectGetMidY(self.bounds));
  }
}

- (void)updateFromPoint:(CGPoint)point {
  CGPoint center = CGPointMake(CGRectGetMidX(self.bounds), CGRectGetMidY(self.bounds));
  CGFloat side = MIN(self.bounds.size.width, self.bounds.size.height);
  CGFloat radius = MAX(1.0, side * 0.36);
  CGFloat dx = point.x - center.x;
  CGFloat dy = point.y - center.y;
  CGFloat distance = hypot(dx, dy);
  if (distance > radius) {
    dx = dx / distance * radius;
    dy = dy / distance * radius;
  }
  self.knob.center = CGPointMake(center.x + dx, center.y + dy);
  float x = RPCS3Clamp((float)(dx / radius), -1.0f, 1.0f);
  // UIKit Y grows down. GameController/RPCS3 frontend convention is positive up.
  float y = RPCS3Clamp((float)(-dy / radius), -1.0f, 1.0f);
  if (self.valueChanged) self.valueChanged(x, y);
}

- (void)touchesBegan:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
  self.trackingTouch = YES;
  UITouch* touch = touches.anyObject;
  if (touch) [self updateFromPoint:[touch locationInView:self]];
}

- (void)touchesMoved:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
  UITouch* touch = touches.anyObject;
  if (touch) [self updateFromPoint:[touch locationInView:self]];
}

- (void)endTracking {
  self.trackingTouch = NO;
  self.knob.center = CGPointMake(CGRectGetMidX(self.bounds), CGRectGetMidY(self.bounds));
  if (self.valueChanged) self.valueChanged(0.0f, 0.0f);
}

- (void)touchesEnded:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event { [self endTracking]; }
- (void)touchesCancelled:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event { [self endTracking]; }
@end

@interface RPCS3GameInputController ()
@property(nonatomic, weak) UIView* hostView;
@property(nonatomic, assign) rpcs3_ios_api* api;
@property(nonatomic, strong) RPCS3InputPassthroughView* touchOverlay;
@property(nonatomic, strong, nullable) GCController* physicalController;
@property(nonatomic, assign) rpcs3_ios_pad_state touchState;
@property(nonatomic, assign) BOOL started;

@property(nonatomic, strong) UIButton* dpadUp;
@property(nonatomic, strong) UIButton* dpadDown;
@property(nonatomic, strong) UIButton* dpadLeft;
@property(nonatomic, strong) UIButton* dpadRight;
@property(nonatomic, strong) UIButton* square;
@property(nonatomic, strong) UIButton* cross;
@property(nonatomic, strong) UIButton* circle;
@property(nonatomic, strong) UIButton* triangle;
@property(nonatomic, strong) UIButton* l1;
@property(nonatomic, strong) UIButton* l2;
@property(nonatomic, strong) UIButton* r1;
@property(nonatomic, strong) UIButton* r2;
@property(nonatomic, strong) UIButton* selectButton;
@property(nonatomic, strong) UIButton* startButton;
@property(nonatomic, strong) UIButton* psButton;
@property(nonatomic, strong) RPCS3TouchStickView* leftStick;
@property(nonatomic, strong) RPCS3TouchStickView* rightStick;
@end

@implementation RPCS3GameInputController

- (instancetype)initWithHostView:(UIView*)hostView api:(rpcs3_ios_api*)api {
  self = [super init];
  if (self) {
    _hostView = hostView;
    _api = api;
    memset(&_touchState, 0, sizeof(_touchState));
    _touchState.size = sizeof(_touchState);
    [self installTouchOverlay];
  }
  return self;
}

- (UIButton*)makeButton:(NSString*)title bit:(uint32_t)bit accessibility:(NSString*)accessibility {
  UIButton* button = [UIButton buttonWithType:UIButtonTypeSystem];
  button.tag = (NSInteger)bit;
  button.tintColor = UIColor.whiteColor;
  button.titleLabel.font = [UIFont systemFontOfSize:18 weight:UIFontWeightSemibold];
  button.backgroundColor = [UIColor colorWithWhite:0.06 alpha:0.38];
  button.layer.borderWidth = 1.0;
  button.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.38].CGColor;
  button.layer.cornerRadius = 22;
  button.accessibilityLabel = accessibility;
  [button setTitle:title forState:UIControlStateNormal];
  [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
  [button addTarget:self action:@selector(touchButtonDown:) forControlEvents:UIControlEventTouchDown];
  [button addTarget:self action:@selector(touchButtonUp:) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
  [self.touchOverlay addSubview:button];
  return button;
}

- (void)installTouchOverlay {
  UIView* host = self.hostView;
  if (!host) return;

  self.touchOverlay = [[RPCS3InputPassthroughView alloc] initWithFrame:host.bounds];
  self.touchOverlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  self.touchOverlay.backgroundColor = UIColor.clearColor;
  self.touchOverlay.accessibilityIdentifier = @"rpcs3.touch.controls";
  [host addSubview:self.touchOverlay];

  self.dpadUp = [self makeButton:@"▲" bit:rpcs3_ios_pad_up accessibility:@"D-pad Up"];
  self.dpadDown = [self makeButton:@"▼" bit:rpcs3_ios_pad_down accessibility:@"D-pad Down"];
  self.dpadLeft = [self makeButton:@"◀" bit:rpcs3_ios_pad_left accessibility:@"D-pad Left"];
  self.dpadRight = [self makeButton:@"▶" bit:rpcs3_ios_pad_right accessibility:@"D-pad Right"];

  self.square = [self makeButton:@"□" bit:rpcs3_ios_pad_square accessibility:@"Square"];
  self.cross = [self makeButton:@"✕" bit:rpcs3_ios_pad_cross accessibility:@"Cross"];
  self.circle = [self makeButton:@"○" bit:rpcs3_ios_pad_circle accessibility:@"Circle"];
  self.triangle = [self makeButton:@"△" bit:rpcs3_ios_pad_triangle accessibility:@"Triangle"];

  self.l1 = [self makeButton:@"L1" bit:rpcs3_ios_pad_l1 accessibility:@"L1"];
  self.l2 = [self makeButton:@"L2" bit:rpcs3_ios_pad_l2 accessibility:@"L2"];
  self.r1 = [self makeButton:@"R1" bit:rpcs3_ios_pad_r1 accessibility:@"R1"];
  self.r2 = [self makeButton:@"R2" bit:rpcs3_ios_pad_r2 accessibility:@"R2"];
  self.selectButton = [self makeButton:@"SELECT" bit:rpcs3_ios_pad_select accessibility:@"Select"];
  self.startButton = [self makeButton:@"START" bit:rpcs3_ios_pad_start accessibility:@"Start"];
  self.psButton = [self makeButton:@"PS" bit:rpcs3_ios_pad_ps accessibility:@"PS"];

  self.leftStick = [[RPCS3TouchStickView alloc] initWithFrame:CGRectZero];
  self.leftStick.accessibilityLabel = @"Left analog stick";
  [self.touchOverlay addSubview:self.leftStick];
  self.rightStick = [[RPCS3TouchStickView alloc] initWithFrame:CGRectZero];
  self.rightStick.accessibilityLabel = @"Right analog stick";
  [self.touchOverlay addSubview:self.rightStick];

  __weak RPCS3GameInputController* weakSelf = self;
  self.leftStick.valueChanged = ^(float x, float y) {
    RPCS3GameInputController* strongSelf = weakSelf;
    if (!strongSelf || strongSelf.physicalController) return;
    strongSelf->_touchState.left_x = x;
    strongSelf->_touchState.left_y = y;
    [strongSelf sendTouchState];
  };
  self.rightStick.valueChanged = ^(float x, float y) {
    RPCS3GameInputController* strongSelf = weakSelf;
    if (!strongSelf || strongSelf.physicalController) return;
    strongSelf->_touchState.right_x = x;
    strongSelf->_touchState.right_y = y;
    [strongSelf sendTouchState];
  };
}

- (void)start {
  if (self.started) return;
  self.started = YES;
  NSLog(@"%s: direct RPCS3 physical/touch input active", kRPCS3InputMarker);
  NSNotificationCenter* center = NSNotificationCenter.defaultCenter;
  [center addObserver:self selector:@selector(controllerDidConnect:) name:GCControllerDidConnectNotification object:nil];
  [center addObserver:self selector:@selector(controllerDidDisconnect:) name:GCControllerDidDisconnectNotification object:nil];
  [self selectFirstPhysicalController];
  [self updateTouchVisibility];
}

- (void)stop {
  if (!self.started) return;
  self.started = NO;
  [NSNotificationCenter.defaultCenter removeObserver:self name:GCControllerDidConnectNotification object:nil];
  [NSNotificationCenter.defaultCenter removeObserver:self name:GCControllerDidDisconnectNotification object:nil];
  [self unbindPhysicalController];
  [self clearCorePadState];
  self.touchOverlay.hidden = YES;
}

- (BOOL)isUsableController:(GCController*)controller {
  return controller.extendedGamepad != nil || controller.microGamepad != nil;
}

- (void)selectFirstPhysicalController {
  if (self.physicalController) return;
  for (GCController* controller in [GCController controllers]) {
    if ([self isUsableController:controller]) {
      [self bindPhysicalController:controller];
      return;
    }
  }
}

- (void)controllerDidConnect:(NSNotification*)notification {
  GCController* controller = [notification.object isKindOfClass:GCController.class] ? notification.object : nil;
  if (!controller || self.physicalController || ![self isUsableController:controller]) return;
  [self bindPhysicalController:controller];
}

- (void)controllerDidDisconnect:(NSNotification*)notification {
  GCController* controller = [notification.object isKindOfClass:GCController.class] ? notification.object : nil;
  if (!controller || controller != self.physicalController) return;
  [self unbindPhysicalController];
  [self clearCorePadState];
  [self selectFirstPhysicalController];
  [self updateTouchVisibility];
}

- (void)bindPhysicalController:(GCController*)controller {
  [self unbindPhysicalController];
  self.physicalController = controller;
  memset(&_touchState, 0, sizeof(_touchState));
  _touchState.size = sizeof(_touchState);
  [self clearCorePadState];

  __weak RPCS3GameInputController* weakSelf = self;
  if (controller.extendedGamepad) {
    GCExtendedGamepad* pad = controller.extendedGamepad;
    pad.valueChangedHandler = ^(GCExtendedGamepad* gamepad, GCControllerElement* element) {
      dispatch_async(dispatch_get_main_queue(), ^{
        RPCS3GameInputController* strongSelf = weakSelf;
        if (strongSelf && strongSelf.physicalController == controller) {
          [strongSelf updateFromExtendedGamepad:gamepad];
        }
      });
    };
    [self updateFromExtendedGamepad:pad];
  } else if (controller.microGamepad) {
    GCMicroGamepad* pad = controller.microGamepad;
    pad.valueChangedHandler = ^(GCMicroGamepad* gamepad, GCControllerElement* element) {
      dispatch_async(dispatch_get_main_queue(), ^{
        RPCS3GameInputController* strongSelf = weakSelf;
        if (strongSelf && strongSelf.physicalController == controller) {
          [strongSelf updateFromMicroGamepad:gamepad];
        }
      });
    };
    [self updateFromMicroGamepad:pad];
  }
  [self updateTouchVisibility];
}

- (void)unbindPhysicalController {
  GCController* controller = self.physicalController;
  if (!controller) return;
  if (controller.extendedGamepad) controller.extendedGamepad.valueChangedHandler = nil;
  if (controller.microGamepad) controller.microGamepad.valueChangedHandler = nil;
  self.physicalController = nil;
}

- (GCControllerButtonInput*)optionalButtonOnProfile:(id)profile key:(NSString*)key {
  @try {
    id value = [profile valueForKey:key];
    return [value isKindOfClass:GCControllerButtonInput.class] ? value : nil;
  } @catch (__unused NSException* exception) {
    return nil;
  }
}

- (void)updateFromExtendedGamepad:(GCExtendedGamepad*)pad {
  if (!self.started || !pad || !self.physicalController) return;
  rpcs3_ios_pad_state state = {};
  state.size = sizeof(state);

  RPCS3SetBit(&state.buttons, rpcs3_ios_pad_up, pad.dpad.up.isPressed);
  RPCS3SetBit(&state.buttons, rpcs3_ios_pad_down, pad.dpad.down.isPressed);
  RPCS3SetBit(&state.buttons, rpcs3_ios_pad_left, pad.dpad.left.isPressed);
  RPCS3SetBit(&state.buttons, rpcs3_ios_pad_right, pad.dpad.right.isPressed);
  RPCS3SetBit(&state.buttons, rpcs3_ios_pad_cross, pad.buttonA.isPressed);
  RPCS3SetBit(&state.buttons, rpcs3_ios_pad_circle, pad.buttonB.isPressed);
  RPCS3SetBit(&state.buttons, rpcs3_ios_pad_square, pad.buttonX.isPressed);
  RPCS3SetBit(&state.buttons, rpcs3_ios_pad_triangle, pad.buttonY.isPressed);
  RPCS3SetBit(&state.buttons, rpcs3_ios_pad_l1, pad.leftShoulder.isPressed);
  RPCS3SetBit(&state.buttons, rpcs3_ios_pad_r1, pad.rightShoulder.isPressed);

  state.l2 = RPCS3Clamp(pad.leftTrigger.value, 0.0f, 1.0f);
  state.r2 = RPCS3Clamp(pad.rightTrigger.value, 0.0f, 1.0f);
  RPCS3SetBit(&state.buttons, rpcs3_ios_pad_l2, pad.leftTrigger.isPressed || state.l2 > 0.01f);
  RPCS3SetBit(&state.buttons, rpcs3_ios_pad_r2, pad.rightTrigger.isPressed || state.r2 > 0.01f);

  state.left_x = RPCS3Clamp(pad.leftThumbstick.xAxis.value, -1.0f, 1.0f);
  state.left_y = RPCS3Clamp(pad.leftThumbstick.yAxis.value, -1.0f, 1.0f);
  state.right_x = RPCS3Clamp(pad.rightThumbstick.xAxis.value, -1.0f, 1.0f);
  state.right_y = RPCS3Clamp(pad.rightThumbstick.yAxis.value, -1.0f, 1.0f);

  GCControllerButtonInput* leftThumb = [self optionalButtonOnProfile:pad key:@"leftThumbstickButton"];
  GCControllerButtonInput* rightThumb = [self optionalButtonOnProfile:pad key:@"rightThumbstickButton"];
  GCControllerButtonInput* options = [self optionalButtonOnProfile:pad key:@"buttonOptions"];
  GCControllerButtonInput* menu = [self optionalButtonOnProfile:pad key:@"buttonMenu"];
  GCControllerButtonInput* home = [self optionalButtonOnProfile:pad key:@"buttonHome"];
  RPCS3SetBit(&state.buttons, rpcs3_ios_pad_l3, leftThumb.isPressed);
  RPCS3SetBit(&state.buttons, rpcs3_ios_pad_r3, rightThumb.isPressed);
  RPCS3SetBit(&state.buttons, rpcs3_ios_pad_select, options.isPressed);
  RPCS3SetBit(&state.buttons, rpcs3_ios_pad_start, menu.isPressed);
  RPCS3SetBit(&state.buttons, rpcs3_ios_pad_ps, home.isPressed);

  [self sendState:&state];
}

- (void)updateFromMicroGamepad:(GCMicroGamepad*)pad {
  if (!self.started || !pad || !self.physicalController) return;
  rpcs3_ios_pad_state state = {};
  state.size = sizeof(state);
  RPCS3SetBit(&state.buttons, rpcs3_ios_pad_up, pad.dpad.up.isPressed);
  RPCS3SetBit(&state.buttons, rpcs3_ios_pad_down, pad.dpad.down.isPressed);
  RPCS3SetBit(&state.buttons, rpcs3_ios_pad_left, pad.dpad.left.isPressed);
  RPCS3SetBit(&state.buttons, rpcs3_ios_pad_right, pad.dpad.right.isPressed);
  RPCS3SetBit(&state.buttons, rpcs3_ios_pad_cross, pad.buttonA.isPressed);
  RPCS3SetBit(&state.buttons, rpcs3_ios_pad_square, pad.buttonX.isPressed);
  [self sendState:&state];
}

- (void)touchButtonDown:(UIButton*)sender {
  if (!self.started || self.physicalController) return;
  uint32_t bit = (uint32_t)sender.tag;
  _touchState.buttons |= bit;
  if (bit == rpcs3_ios_pad_l2) _touchState.l2 = 1.0f;
  if (bit == rpcs3_ios_pad_r2) _touchState.r2 = 1.0f;
  sender.backgroundColor = [UIColor colorWithWhite:1 alpha:0.34];
  [self sendTouchState];
}

- (void)touchButtonUp:(UIButton*)sender {
  uint32_t bit = (uint32_t)sender.tag;
  _touchState.buttons &= ~bit;
  if (bit == rpcs3_ios_pad_l2) _touchState.l2 = 0.0f;
  if (bit == rpcs3_ios_pad_r2) _touchState.r2 = 0.0f;
  sender.backgroundColor = [UIColor colorWithWhite:0.06 alpha:0.38];
  if (!self.physicalController) [self sendTouchState];
}

- (void)sendTouchState {
  if (!self.started || self.physicalController) return;
  _touchState.size = sizeof(_touchState);
  [self sendState:&_touchState];
}

- (void)sendState:(const rpcs3_ios_pad_state*)state {
  if (!state || !_api || !_api->set_pad_state) return;
  _api->set_pad_state(0, state);
}

- (void)clearCorePadState {
  rpcs3_ios_pad_state state = {};
  state.size = sizeof(state);
  [self sendState:&state];
}

- (void)updateTouchVisibility {
  BOOL showTouch = self.started && self.physicalController == nil;
  self.touchOverlay.hidden = !showTouch;
  self.touchOverlay.userInteractionEnabled = showTouch;
}

- (void)setFrameForView:(UIView*)view center:(CGPoint)center size:(CGSize)size {
  view.bounds = CGRectMake(0, 0, size.width, size.height);
  view.center = center;
  if ([view isKindOfClass:UIButton.class]) {
    ((UIButton*)view).layer.cornerRadius = MIN(size.width, size.height) * 0.46;
  }
}

- (void)layoutControlsInBounds:(CGRect)bounds safeAreaInsets:(UIEdgeInsets)insets {
  if (!self.touchOverlay) return;
  self.touchOverlay.frame = bounds;

  CGFloat width = CGRectGetWidth(bounds);
  CGFloat height = CGRectGetHeight(bounds);
  if (width <= 0 || height <= 0) return;

  CGFloat shortSide = MIN(width, height);
  CGFloat button = MIN(56.0, MAX(42.0, shortSide * 0.12));
  CGFloat miniWidth = MIN(74.0, MAX(58.0, button * 1.35));
  CGFloat miniHeight = MIN(40.0, MAX(32.0, button * 0.72));
  CGFloat stick = MIN(116.0, MAX(86.0, shortSide * 0.24));
  CGFloat edge = 14.0;
  CGFloat left = insets.left + edge;
  CGFloat right = insets.right + edge;
  CGFloat bottom = insets.bottom + edge;
  CGFloat top = insets.top + edge;
  CGFloat d = button * 0.88;

  CGPoint dpadCenter = CGPointMake(left + button * 1.55, height - bottom - button * 1.55);
  [self setFrameForView:self.dpadUp center:CGPointMake(dpadCenter.x, dpadCenter.y - d) size:CGSizeMake(button, button)];
  [self setFrameForView:self.dpadDown center:CGPointMake(dpadCenter.x, dpadCenter.y + d) size:CGSizeMake(button, button)];
  [self setFrameForView:self.dpadLeft center:CGPointMake(dpadCenter.x - d, dpadCenter.y) size:CGSizeMake(button, button)];
  [self setFrameForView:self.dpadRight center:CGPointMake(dpadCenter.x + d, dpadCenter.y) size:CGSizeMake(button, button)];

  CGPoint faceCenter = CGPointMake(width - right - button * 1.55, height - bottom - button * 1.55);
  [self setFrameForView:self.triangle center:CGPointMake(faceCenter.x, faceCenter.y - d) size:CGSizeMake(button, button)];
  [self setFrameForView:self.cross center:CGPointMake(faceCenter.x, faceCenter.y + d) size:CGSizeMake(button, button)];
  [self setFrameForView:self.square center:CGPointMake(faceCenter.x - d, faceCenter.y) size:CGSizeMake(button, button)];
  [self setFrameForView:self.circle center:CGPointMake(faceCenter.x + d, faceCenter.y) size:CGSizeMake(button, button)];

  CGFloat stickY = height - bottom - stick * 0.58;
  CGFloat leftStickX = MIN(width * 0.39, left + button * 4.35);
  CGFloat rightStickX = MAX(width * 0.61, width - right - button * 4.35);
  [self setFrameForView:self.leftStick center:CGPointMake(leftStickX, stickY) size:CGSizeMake(stick, stick)];
  [self setFrameForView:self.rightStick center:CGPointMake(rightStickX, stickY) size:CGSizeMake(stick, stick)];

  CGFloat shoulderY = top + miniHeight * 0.5;
  [self setFrameForView:self.l2 center:CGPointMake(left + 82.0, shoulderY) size:CGSizeMake(miniWidth, miniHeight)];
  [self setFrameForView:self.l1 center:CGPointMake(left + 82.0 + miniWidth + 8.0, shoulderY) size:CGSizeMake(miniWidth, miniHeight)];
  [self setFrameForView:self.r2 center:CGPointMake(width - right - 82.0, shoulderY) size:CGSizeMake(miniWidth, miniHeight)];
  [self setFrameForView:self.r1 center:CGPointMake(width - right - 82.0 - miniWidth - 8.0, shoulderY) size:CGSizeMake(miniWidth, miniHeight)];

  CGFloat centerY = top + miniHeight * 0.5;
  [self setFrameForView:self.selectButton center:CGPointMake(width * 0.5 - miniWidth - 12.0, centerY) size:CGSizeMake(miniWidth, miniHeight)];
  [self setFrameForView:self.psButton center:CGPointMake(width * 0.5, centerY) size:CGSizeMake(miniHeight, miniHeight)];
  [self setFrameForView:self.startButton center:CGPointMake(width * 0.5 + miniWidth + 12.0, centerY) size:CGSizeMake(miniWidth, miniHeight)];
}

- (void)dealloc {
  [self stop];
}

@end