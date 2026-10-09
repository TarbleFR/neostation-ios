#import "LibretroTouchOverlay.h"

#import "LibretroInputState.h"

typedef NS_ENUM(NSInteger, LibretroOverlayKind) {
  LibretroOverlayKindButton,
  LibretroOverlayKindDPad,
  LibretroOverlayKindStick,
  LibretroOverlayKindStickButton,
};

#define BIT(identifier) ((uint16_t)(1u << (identifier)))

/// One control. Positions are fractions of the safe area; sizes are
/// fractions of its height so controls stay round on every screen.
@interface LibretroOverlayElement : NSObject
@property(nonatomic) LibretroOverlayKind kind;
@property(nonatomic, copy) NSString *label;
@property(nonatomic) uint16_t mask;
@property(nonatomic) CGPoint center;
@property(nonatomic) CGSize size;
@property(nonatomic) unsigned stick;
@property(nonatomic) int16_t stickX;
@property(nonatomic) int16_t stickY;
@property(nonatomic) CGRect frame;
@property(nonatomic, strong) UIView *view;
@property(nonatomic, strong) UIView *knob;
@end

@implementation LibretroOverlayElement
@end

@interface LibretroTouchTrack : NSObject
@property(nonatomic, weak) LibretroOverlayElement *element;
@property(nonatomic) uint16_t mask;
@property(nonatomic) BOOL pointer;
@end

@implementation LibretroTouchTrack
@end

static LibretroOverlayElement *Button(NSString *label, uint16_t mask, CGFloat x, CGFloat y, CGFloat w, CGFloat h) {
  LibretroOverlayElement *element = [LibretroOverlayElement new];
  element.kind = LibretroOverlayKindButton;
  element.label = label;
  element.mask = mask;
  element.center = CGPointMake(x, y);
  element.size = CGSizeMake(w, h);
  return element;
}

static LibretroOverlayElement *DPad(CGFloat x, CGFloat y, CGFloat size) {
  LibretroOverlayElement *element = [LibretroOverlayElement new];
  element.kind = LibretroOverlayKindDPad;
  element.label = @"";
  element.center = CGPointMake(x, y);
  element.size = CGSizeMake(size, size);
  return element;
}

static LibretroOverlayElement *Stick(unsigned stick, CGFloat x, CGFloat y, CGFloat size) {
  LibretroOverlayElement *element = [LibretroOverlayElement new];
  element.kind = LibretroOverlayKindStick;
  element.label = @"";
  element.stick = stick;
  element.center = CGPointMake(x, y);
  element.size = CGSizeMake(size, size);
  return element;
}

static LibretroOverlayElement *StickButton(NSString *label, unsigned stick, int16_t dx, int16_t dy, CGFloat x, CGFloat y,
                                           CGFloat size) {
  LibretroOverlayElement *element = Button(label, 0, x, y, size, size);
  element.kind = LibretroOverlayKindStickButton;
  element.stick = stick;
  element.stickX = dx;
  element.stickY = dy;
  return element;
}

static void AddShoulders(NSMutableArray *elements, NSString *left, uint16_t leftMask, NSString *right, uint16_t rightMask,
                         CGFloat y) {
  [elements addObject:Button(left, leftMask, 0.08, y, 0.19, 0.10)];
  [elements addObject:Button(right, rightMask, 0.92, y, 0.19, 0.10)];
}

static void AddSystemButtons(NSMutableArray *elements, NSString *select, NSString *start) {
  if (select != nil) [elements addObject:Button(select, BIT(RETRO_DEVICE_ID_JOYPAD_SELECT), 0.40, 0.93, 0.15, 0.08)];
  if (start != nil) [elements addObject:Button(start, BIT(RETRO_DEVICE_ID_JOYPAD_START), 0.60, 0.93, 0.15, 0.08)];
}

static void AddDiamond(NSMutableArray *elements, NSString *top, uint16_t topMask, NSString *right, uint16_t rightMask,
                       NSString *bottom, uint16_t bottomMask, NSString *left, uint16_t leftMask, CGFloat x, CGFloat y) {
  const CGFloat size = 0.15;
  const CGFloat offset = 0.13;
  [elements addObject:Button(top, topMask, x, y - offset, size, size)];
  [elements addObject:Button(right, rightMask, x + offset * 0.62, y, size, size)];
  [elements addObject:Button(bottom, bottomMask, x, y + offset, size, size)];
  [elements addObject:Button(left, leftMask, x - offset * 0.62, y, size, size)];
}

static NSArray<LibretroOverlayElement *> *LayoutForProfile(NSString *profile, BOOL *pointer) {
  NSMutableArray<LibretroOverlayElement *> *elements = [NSMutableArray array];
  const uint16_t A = BIT(RETRO_DEVICE_ID_JOYPAD_A), B = BIT(RETRO_DEVICE_ID_JOYPAD_B);
  const uint16_t X = BIT(RETRO_DEVICE_ID_JOYPAD_X), Y = BIT(RETRO_DEVICE_ID_JOYPAD_Y);
  const uint16_t L = BIT(RETRO_DEVICE_ID_JOYPAD_L), R = BIT(RETRO_DEVICE_ID_JOYPAD_R);
  const uint16_t L2 = BIT(RETRO_DEVICE_ID_JOYPAD_L2), R2 = BIT(RETRO_DEVICE_ID_JOYPAD_R2);
  *pointer = NO;
  if ([profile isEqualToString:@"snes"] || [profile isEqualToString:@"nds"]) {
    [elements addObject:DPad(0.13, 0.64, 0.38)];
    AddDiamond(elements, @"X", X, @"A", A, @"B", B, @"Y", Y, 0.87, 0.64);
    AddShoulders(elements, @"L", L, @"R", R, 0.14);
    AddSystemButtons(elements, @"SELECT", @"START");
    *pointer = [profile isEqualToString:@"nds"];
  } else if ([profile isEqualToString:@"gba"]) {
    [elements addObject:DPad(0.13, 0.64, 0.38)];
    [elements addObject:Button(@"B", B, 0.80, 0.72, 0.17, 0.17)];
    [elements addObject:Button(@"A", A, 0.93, 0.58, 0.17, 0.17)];
    AddShoulders(elements, @"L", L, @"R", R, 0.14);
    AddSystemButtons(elements, @"SELECT", @"START");
  } else if ([profile isEqualToString:@"md"]) {
    [elements addObject:DPad(0.13, 0.64, 0.38)];
    [elements addObject:Button(@"A", Y, 0.71, 0.78, 0.14, 0.14)];
    [elements addObject:Button(@"B", B, 0.82, 0.71, 0.14, 0.14)];
    [elements addObject:Button(@"C", A, 0.93, 0.64, 0.14, 0.14)];
    [elements addObject:Button(@"X", L, 0.71, 0.56, 0.12, 0.12)];
    [elements addObject:Button(@"Y", X, 0.82, 0.49, 0.12, 0.12)];
    [elements addObject:Button(@"Z", R, 0.93, 0.42, 0.12, 0.12)];
    AddSystemButtons(elements, @"MODE", @"START");
  } else if ([profile isEqualToString:@"sms"]) {
    [elements addObject:DPad(0.13, 0.64, 0.38)];
    [elements addObject:Button(@"1", B, 0.80, 0.72, 0.17, 0.17)];
    [elements addObject:Button(@"2", A, 0.93, 0.58, 0.17, 0.17)];
    AddSystemButtons(elements, nil, @"START");
  } else if ([profile isEqualToString:@"arcade"]) {
    [elements addObject:DPad(0.13, 0.64, 0.38)];
    [elements addObject:Button(@"1", B, 0.71, 0.76, 0.14, 0.14)];
    [elements addObject:Button(@"2", A, 0.82, 0.70, 0.14, 0.14)];
    [elements addObject:Button(@"6", R, 0.93, 0.64, 0.14, 0.14)];
    [elements addObject:Button(@"3", Y, 0.71, 0.55, 0.14, 0.14)];
    [elements addObject:Button(@"4", X, 0.82, 0.49, 0.14, 0.14)];
    [elements addObject:Button(@"5", L, 0.93, 0.43, 0.14, 0.14)];
    AddSystemButtons(elements, @"COIN", @"START");
  } else if ([profile isEqualToString:@"n64"]) {
    [elements addObject:Stick(0, 0.13, 0.62, 0.36)];
    [elements addObject:Button(@"A", B, 0.80, 0.78, 0.16, 0.16)];
    [elements addObject:Button(@"B", Y, 0.69, 0.66, 0.15, 0.15)];
    [elements addObject:StickButton(@"C▲", 1, 0, -32767, 0.90, 0.36, 0.10)];
    [elements addObject:StickButton(@"C▼", 1, 0, 32767, 0.90, 0.58, 0.10)];
    [elements addObject:StickButton(@"C◀", 1, -32767, 0, 0.83, 0.47, 0.10)];
    [elements addObject:StickButton(@"C▶", 1, 32767, 0, 0.97, 0.47, 0.10)];
    AddShoulders(elements, @"L", L, @"R", R, 0.14);
    [elements addObject:Button(@"Z", L2, 0.08, 0.30, 0.19, 0.10)];
    AddSystemButtons(elements, nil, @"START");
  } else if ([profile isEqualToString:@"psx"]) {
    [elements addObject:DPad(0.13, 0.64, 0.38)];
    AddDiamond(elements, @"△", X, @"○", A, @"✕", B, @"□", Y, 0.87, 0.64);
    AddShoulders(elements, @"L1", L, @"R1", R, 0.14);
    [elements addObject:Button(@"L2", L2, 0.08, 0.29, 0.19, 0.10)];
    [elements addObject:Button(@"R2", R2, 0.92, 0.29, 0.19, 0.10)];
    AddSystemButtons(elements, @"SELECT", @"START");
  } else if ([profile isEqualToString:@"psp"]) {
    [elements addObject:DPad(0.12, 0.46, 0.30)];
    [elements addObject:Stick(0, 0.24, 0.80, 0.26)];
    AddDiamond(elements, @"△", X, @"○", A, @"✕", B, @"□", Y, 0.87, 0.60);
    AddShoulders(elements, @"L", L, @"R", R, 0.14);
    AddSystemButtons(elements, @"SELECT", @"START");
  } else if ([profile isEqualToString:@"3ds"]) {
    [elements addObject:Stick(0, 0.12, 0.44, 0.30)];
    [elements addObject:DPad(0.24, 0.80, 0.26)];
    AddDiamond(elements, @"X", X, @"A", A, @"B", B, @"Y", Y, 0.87, 0.60);
    AddShoulders(elements, @"L", L, @"R", R, 0.14);
    [elements addObject:Button(@"ZL", L2, 0.08, 0.29, 0.19, 0.10)];
    [elements addObject:Button(@"ZR", R2, 0.92, 0.29, 0.19, 0.10)];
    AddSystemButtons(elements, @"SELECT", @"START");
    *pointer = YES;
  } else {
    // nes, gb and any two-button handheld or console.
    [elements addObject:DPad(0.13, 0.64, 0.38)];
    [elements addObject:Button(@"B", B, 0.80, 0.72, 0.17, 0.17)];
    [elements addObject:Button(@"A", A, 0.93, 0.58, 0.17, 0.17)];
    AddSystemButtons(elements, @"SELECT", @"START");
  }
  return elements;
}

@implementation LibretroTouchOverlay {
  LibretroInputState *_input;
  NSArray<LibretroOverlayElement *> *_elements;
  NSMapTable<UITouch *, LibretroTouchTrack *> *_tracks;
}

- (instancetype)initWithProfile:(NSString *)profile input:(LibretroInputState *)input {
  self = [super initWithFrame:CGRectZero];
  if (self) {
    _input = input;
    BOOL pointer = NO;
    _elements = LayoutForProfile(profile ?: @"nes", &pointer);
    _usesPointer = pointer;
    _tracks = [NSMapTable strongToStrongObjectsMapTable];
    self.multipleTouchEnabled = YES;
    self.backgroundColor = UIColor.clearColor;
    self.accessibilityIdentifier = @"libretro-touch-overlay";
    for (LibretroOverlayElement *element in _elements) {
      UIView *view = [[UIView alloc] initWithFrame:CGRectZero];
      view.userInteractionEnabled = NO;
      view.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.28];
      view.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.55].CGColor;
      view.layer.borderWidth = 1.5;
      if (element.label.length > 0) {
        UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
        label.text = element.label;
        label.textAlignment = NSTextAlignmentCenter;
        label.textColor = [UIColor colorWithWhite:1.0 alpha:0.85];
        label.adjustsFontSizeToFitWidth = YES;
        label.minimumScaleFactor = 0.5;
        label.tag = 1;
        [view addSubview:label];
      }
      if (element.kind == LibretroOverlayKindStick) {
        UIView *knob = [[UIView alloc] initWithFrame:CGRectZero];
        knob.userInteractionEnabled = NO;
        knob.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.40];
        [view addSubview:knob];
        element.knob = knob;
      }
      if (element.kind == LibretroOverlayKindDPad) {
        for (NSString *arrow in @[ @"▲", @"▼", @"◀", @"▶" ]) {
          UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
          label.text = arrow;
          label.textAlignment = NSTextAlignmentCenter;
          label.textColor = [UIColor colorWithWhite:1.0 alpha:0.75];
          label.tag = 2;
          [view addSubview:label];
        }
      }
      element.view = view;
      [self addSubview:view];
    }
  }
  return self;
}

- (void)layoutSubviews {
  [super layoutSubviews];
  CGRect safe = UIEdgeInsetsInsetRect(self.bounds, self.safeAreaInsets);
  if (safe.size.width < 1 || safe.size.height < 1) return;
  const CGFloat unit = safe.size.height;
  for (LibretroOverlayElement *element in _elements) {
    CGSize size = CGSizeMake(element.size.width * unit, element.size.height * unit);
    CGPoint center = CGPointMake(CGRectGetMinX(safe) + element.center.x * safe.size.width,
                                 CGRectGetMinY(safe) + element.center.y * safe.size.height);
    CGRect frame = CGRectMake(center.x - size.width / 2, center.y - size.height / 2, size.width, size.height);
    element.frame = frame;
    element.view.frame = frame;
    BOOL round = element.kind != LibretroOverlayKindButton || fabs(size.width - size.height) < 1.0;
    element.view.layer.cornerRadius = round ? MIN(size.width, size.height) / 2 : size.height * 0.3;
    UILabel *label = [element.view viewWithTag:1];
    if ([label isKindOfClass:UILabel.class]) {
      label.frame = element.view.bounds;
      label.font = [UIFont systemFontOfSize:MIN(size.width, size.height) * 0.42 weight:UIFontWeightSemibold];
    }
    if (element.kind == LibretroOverlayKindDPad) {
      NSArray<UIView *> *arrows = [element.view.subviews filteredArrayUsingPredicate:
          [NSPredicate predicateWithBlock:^BOOL(UIView *view, __unused NSDictionary *bindings) {
            return view.tag == 2;
          }]];
      CGFloat third = size.width / 3;
      CGRect slots[4] = {
          CGRectMake(third, 0, third, third),
          CGRectMake(third, 2 * third, third, third),
          CGRectMake(0, third, third, third),
          CGRectMake(2 * third, third, third, third),
      };
      for (NSUInteger index = 0; index < arrows.count && index < 4; index++) {
        arrows[index].frame = slots[index];
        ((UILabel *)arrows[index]).font = [UIFont systemFontOfSize:third * 0.5];
      }
    }
    if (element.knob != nil) {
      CGFloat knob = size.width * 0.42;
      element.knob.frame = CGRectMake((size.width - knob) / 2, (size.height - knob) / 2, knob, knob);
      element.knob.layer.cornerRadius = knob / 2;
    }
  }
}

- (LibretroOverlayElement *)elementAtPoint:(CGPoint)point buttonsOnly:(BOOL)buttonsOnly {
  LibretroOverlayElement *best = nil;
  CGFloat bestDistance = CGFLOAT_MAX;
  for (LibretroOverlayElement *element in _elements) {
    if (buttonsOnly && element.kind != LibretroOverlayKindButton && element.kind != LibretroOverlayKindStickButton) {
      continue;
    }
    CGRect area = CGRectInset(element.frame, -element.frame.size.width * 0.12, -element.frame.size.height * 0.12);
    if (!CGRectContainsPoint(area, point)) continue;
    CGFloat dx = point.x - CGRectGetMidX(element.frame);
    CGFloat dy = point.y - CGRectGetMidY(element.frame);
    CGFloat distance = dx * dx + dy * dy;
    if (distance < bestDistance) {
      bestDistance = distance;
      best = element;
    }
  }
  return best;
}

static uint16_t DPadMask(LibretroOverlayElement *element, CGPoint point) {
  CGFloat dx = point.x - CGRectGetMidX(element.frame);
  CGFloat dy = point.y - CGRectGetMidY(element.frame);
  CGFloat dead = element.frame.size.width * 0.12;
  if (dx * dx + dy * dy < dead * dead) return 0;
  double angle = atan2(-dy, dx) * 180.0 / M_PI;
  if (angle < 0) angle += 360.0;
  uint16_t mask = 0;
  if (angle < 67.5 || angle >= 292.5) mask |= BIT(RETRO_DEVICE_ID_JOYPAD_RIGHT);
  if (angle >= 22.5 && angle < 157.5) mask |= BIT(RETRO_DEVICE_ID_JOYPAD_UP);
  if (angle >= 112.5 && angle < 247.5) mask |= BIT(RETRO_DEVICE_ID_JOYPAD_LEFT);
  if (angle >= 202.5 && angle < 337.5) mask |= BIT(RETRO_DEVICE_ID_JOYPAD_DOWN);
  return mask;
}

- (void)updateStick:(LibretroOverlayElement *)element point:(CGPoint)point active:(BOOL)active {
  CGFloat radius = element.frame.size.width * 0.5;
  CGFloat dx = active ? (point.x - CGRectGetMidX(element.frame)) / radius : 0;
  CGFloat dy = active ? (point.y - CGRectGetMidY(element.frame)) / radius : 0;
  CGFloat magnitude = hypot(dx, dy);
  if (magnitude > 1.0) {
    dx /= magnitude;
    dy /= magnitude;
  }
  [_input setTouchStick:element.stick x:(int16_t)(dx * 32767.0) y:(int16_t)(dy * 32767.0)];
  if (element.knob != nil) {
    CGSize size = element.view.bounds.size;
    CGFloat knob = element.knob.bounds.size.width;
    element.knob.center = CGPointMake(size.width / 2 + dx * (size.width - knob) / 2,
                                      size.height / 2 + dy * (size.height - knob) / 2);
  }
}

- (void)updatePointer:(CGPoint)point pressed:(BOOL)pressed {
  CGRect video = self.videoRect;
  if (video.size.width < 1 || video.size.height < 1) {
    [_input setPointerX:0 y:0 pressed:NO];
    return;
  }
  double x = (point.x - video.origin.x) / video.size.width * 2.0 - 1.0;
  double y = (point.y - video.origin.y) / video.size.height * 2.0 - 1.0;
  BOOL inside = x >= -1.0 && x <= 1.0 && y >= -1.0 && y <= 1.0;
  x = MAX(-1.0, MIN(1.0, x));
  y = MAX(-1.0, MIN(1.0, y));
  [_input setPointerX:(int16_t)(x * 32767.0) y:(int16_t)(y * 32767.0) pressed:pressed && inside];
}

- (void)publish {
  uint16_t buttons = 0;
  int16_t stickButtons[2][2] = {{0, 0}, {0, 0}};
  BOOL stickButtonActive[2] = {NO, NO};
  for (UITouch *touch in _tracks) {
    LibretroTouchTrack *track = [_tracks objectForKey:touch];
    buttons |= track.mask;
    LibretroOverlayElement *element = track.element;
    if (element.kind == LibretroOverlayKindStickButton) {
      stickButtonActive[element.stick] = YES;
      if (element.stickX != 0) stickButtons[element.stick][0] = element.stickX;
      if (element.stickY != 0) stickButtons[element.stick][1] = element.stickY;
    }
  }
  for (unsigned stick = 0; stick < 2; stick++) {
    BOOL ownedBySticks = NO;
    for (LibretroOverlayElement *element in _elements) {
      if (element.kind == LibretroOverlayKindStick && element.stick == stick) ownedBySticks = YES;
    }
    if (!ownedBySticks) {
      [_input setTouchStick:stick
                          x:stickButtonActive[stick] ? stickButtons[stick][0] : 0
                          y:stickButtonActive[stick] ? stickButtons[stick][1] : 0];
    }
  }
  [_input setTouchButtons:buttons];
  for (LibretroOverlayElement *element in _elements) {
    BOOL pressed = NO;
    for (UITouch *touch in _tracks) {
      if ([_tracks objectForKey:touch].element == element) pressed = YES;
    }
    element.view.backgroundColor = [UIColor colorWithWhite:pressed ? 1.0 : 0.0 alpha:pressed ? 0.30 : 0.28];
  }
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
  for (UITouch *touch in touches) {
    CGPoint point = [touch locationInView:self];
    LibretroTouchTrack *track = [LibretroTouchTrack new];
    LibretroOverlayElement *element = [self elementAtPoint:point buttonsOnly:NO];
    if (element != nil) {
      track.element = element;
      if (element.kind == LibretroOverlayKindDPad) track.mask = DPadMask(element, point);
      else if (element.kind == LibretroOverlayKindButton) track.mask = element.mask;
      else if (element.kind == LibretroOverlayKindStick) [self updateStick:element point:point active:YES];
    } else if (_usesPointer) {
      track.pointer = YES;
      [self updatePointer:point pressed:YES];
    }
    [_tracks setObject:track forKey:touch];
  }
  [self publish];
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
  for (UITouch *touch in touches) {
    LibretroTouchTrack *track = [_tracks objectForKey:touch];
    if (track == nil) continue;
    CGPoint point = [touch locationInView:self];
    if (track.pointer) {
      [self updatePointer:point pressed:YES];
      continue;
    }
    LibretroOverlayElement *element = track.element;
    if (element.kind == LibretroOverlayKindDPad) {
      track.mask = DPadMask(element, point);
    } else if (element.kind == LibretroOverlayKindStick) {
      [self updateStick:element point:point active:YES];
    } else {
      // Fingers may slide from one face button to the next.
      LibretroOverlayElement *slid = [self elementAtPoint:point buttonsOnly:YES];
      track.element = slid;
      track.mask = slid.kind == LibretroOverlayKindButton ? slid.mask : 0;
    }
  }
  [self publish];
}

- (void)endTouches:(NSSet<UITouch *> *)touches {
  for (UITouch *touch in touches) {
    LibretroTouchTrack *track = [_tracks objectForKey:touch];
    if (track == nil) continue;
    if (track.pointer) [_input setPointerX:0 y:0 pressed:NO];
    if (track.element.kind == LibretroOverlayKindStick) [self updateStick:track.element point:CGPointZero active:NO];
    [_tracks removeObjectForKey:touch];
  }
  [self publish];
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
  [self endTouches:touches];
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
  [self endTouches:touches];
}

- (void)releaseAllTouches {
  for (LibretroOverlayElement *element in _elements) {
    if (element.kind == LibretroOverlayKindStick) [self updateStick:element point:CGPointZero active:NO];
  }
  [_tracks removeAllObjects];
  [_input reset];
  [self publish];
}

@end
