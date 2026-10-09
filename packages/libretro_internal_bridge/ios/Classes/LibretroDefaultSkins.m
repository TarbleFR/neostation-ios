#import "LibretroDefaultSkins.h"

#import "LibretroInputMap.h"

#include <math.h>

NSString *const LibretroArrangementStacked = @"stacked";
NSString *const LibretroArrangementSideBySide = @"sideBySide";
NSString *const LibretroArrangementLargeTop = @"largeTop";
NSString *const LibretroArrangementTopOnly = @"topOnly";
NSString *const LibretroArrangementBottomOnly = @"bottomOnly";

// Design units: sizes below are in points for a 390-point-wide iPhone and
// are multiplied by a scale `k` chosen for the view (shorter side, then
// shrunk until every control fits).
static const double DefaultDesignSide = 390.0;
static const double DefaultPillWidth = 72.0;
static const double DefaultPillHeight = 30.0;
static const double DefaultPillGap = 14.0;
static const double DefaultShoulderGap = 8.0;
static const double DefaultMinimumScale = 0.4;

/// Colours of a console's default skin (0xAARRGGBB).
typedef struct {
  uint32_t panel;
  uint32_t dpad;
  uint32_t stick;
  uint32_t face;
  uint32_t faceLabel;
  uint32_t shoulder;
  uint32_t shoulderLabel;
  uint32_t pill;
  uint32_t pillLabel;
} DefaultStyle;

static BOOL DefaultIs(NSString *console, NSArray<NSString *> *consoles) {
  return [consoles containsObject:console];
}

static DefaultStyle DefaultStyleForConsole(NSString *console) {
  DefaultStyle style = {
      .panel = 0xFF2B2B2E,
      .dpad = 0xFF151517,
      .stick = 0xFF55565E,
      .face = 0xFF3A3A3E,
      .faceLabel = 0xFFFFFFFF,
      .shoulder = 0xFF4A4A50,
      .shoulderLabel = 0xFFFFFFFF,
      .pill = 0xFF4A4A50,
      .pillLabel = 0xFFFFFFFF,
  };
  if ([console isEqualToString:@"nes"]) {
    style.face = 0xFFC8102E;
    style.pill = 0xFF5C5C60;
  } else if ([console isEqualToString:@"snes"]) {
    style = (DefaultStyle){0xFFC9C9D1, 0xFF3B3B42, 0xFF55565E, 0xFF5A5A63, 0xFFFFFFFF,
                           0xFF9A9AA4, 0xFF2A2A30, 0xFF8C8C96, 0xFF1F1F24};
  } else if ([console isEqualToString:@"gb"]) {
    style = (DefaultStyle){0xFFC4C1B8, 0xFF2A2A2C, 0xFF55565E, 0xFF8E2252, 0xFFFFFFFF,
                           0xFF8A8A92, 0xFF2A2A2C, 0xFF8A8A92, 0xFF2A2A2C};
  } else if ([console isEqualToString:@"gbc"]) {
    style = (DefaultStyle){0xFF5A3F95, 0xFF26232E, 0xFF55565E, 0xFF2A2633, 0xFFFFFFFF,
                           0xFF3B3446, 0xFFE8E4F0, 0xFF3B3446, 0xFFE8E4F0};
  } else if ([console isEqualToString:@"gba"]) {
    style = (DefaultStyle){0xFF433A8F, 0xFF2B2B36, 0xFF55565E, 0xFFE3E3EA, 0xFF2B2B36,
                           0xFF9C9CB0, 0xFF22222C, 0xFF2B2B36, 0xFFE3E3EA};
  } else if (DefaultIs(console, @[ @"md", @"mcd", @"32x" ])) {
    style = (DefaultStyle){0xFF1B1B1D, 0xFF2C2C2F, 0xFF55565E, 0xFF333336, 0xFFD9D9DE,
                           0xFF3A3A3D, 0xFFD9D9DE, 0xFF3A3A3D, 0xFFD9D9DE};
  } else if ([console isEqualToString:@"sms"]) {
    style = (DefaultStyle){0xFF1E1E20, 0xFF2E2E31, 0xFF55565E, 0xFF55555A, 0xFFFFFFFF,
                           0xFF3A3A3D, 0xFFFFFFFF, 0xFFC62828, 0xFFFFFFFF};
  } else if ([console isEqualToString:@"gg"]) {
    style = (DefaultStyle){0xFF232327, 0xFF34343A, 0xFF55565E, 0xFF2F3A55, 0xFFE0E6F5,
                           0xFF3A3A3D, 0xFFFFFFFF, 0xFF1F5FB0, 0xFFFFFFFF};
  } else if ([console isEqualToString:@"sg1000"]) {
    style = (DefaultStyle){0xFF2A2A2D, 0xFF1A1A1C, 0xFF55565E, 0xFFB3261E, 0xFFFFFFFF,
                           0xFF3A3A3D, 0xFFFFFFFF, 0xFF6B6B70, 0xFFFFFFFF};
  } else if ([console isEqualToString:@"arcade"]) {
    style = (DefaultStyle){0xFF141416, 0xFF242428, 0xFF55565E, 0xFF3A3A3E, 0xFFFFFFFF,
                           0xFF3A3A3E, 0xFFFFFFFF, 0xFFF5F5F5, 0xFF202020};
  } else if ([console isEqualToString:@"nds"]) {
    style = (DefaultStyle){0xFFE4E5EA, 0xFF35373D, 0xFF55565E, 0xFF4A4D55, 0xFFFFFFFF,
                           0xFFB8BAC2, 0xFF2A2C31, 0xFFB8BAC2, 0xFF2A2C31};
  } else if ([console isEqualToString:@"n64"]) {
    style = (DefaultStyle){0xFF8F9097, 0xFF5E5F66, 0xFF5E5F66, 0xFF5E5F66, 0xFFFFFFFF,
                           0xFF6F7078, 0xFFFFFFFF, 0xFF6F7078, 0xFFFFFFFF};
  } else if ([console isEqualToString:@"psx"]) {
    style = (DefaultStyle){0xFFBEBFC5, 0xFF5A5B61, 0xFF4A4B51, 0xFF2F3036, 0xFFFFFFFF,
                           0xFF8D8E95, 0xFF26272B, 0xFF4A4B51, 0xFFFFFFFF};
  } else if ([console isEqualToString:@"psp"]) {
    style = (DefaultStyle){0xFF121214, 0xFF2A2A2E, 0xFF4A4A50, 0xFF26262A, 0xFFFFFFFF,
                           0xFF2A2A2E, 0xFFD0D0D6, 0xFF2A2A2E, 0xFFD0D0D6};
  } else if ([console isEqualToString:@"3ds"]) {
    style = (DefaultStyle){0xFF23262E, 0xFF15171C, 0xFF5B606B, 0xFF3A3E48, 0xFFFFFFFF,
                           0xFF3A3E48, 0xFFE0E3EA, 0xFF3A3E48, 0xFFE0E3EA};
  }
  return style;
}

/// Colours that follow the original controller of the console.
static BOOL DefaultInputColors(NSString *console, NSString *input, uint32_t *fill, uint32_t *label) {
  static const uint32_t dark = 0xFF2A2200;
  if (DefaultIs(console, @[ @"snes", @"3ds" ])) {
    // SNES (PAL / Super Famicom) and New 3DS: A red, B yellow, X blue, Y green.
    NSDictionary<NSString *, NSArray<NSNumber *> *> *colors = @{
      @"a" : @[ @0xFFD7263D, @0xFFFFFFFF ],
      @"b" : @[ @0xFFF2C12E, @(dark) ],
      @"x" : @[ @0xFF2D5DA8, @0xFFFFFFFF ],
      @"y" : @[ @0xFF2E9447, @0xFFFFFFFF ],
    };
    NSArray<NSNumber *> *pair = colors[input];
    if (pair == nil) return NO;
    *fill = pair[0].unsignedIntValue;
    *label = pair[1].unsignedIntValue;
    return YES;
  }
  if (DefaultIs(console, @[ @"psx", @"psp" ])) {
    // PlayStation symbols: triangle green, circle red, cross blue, square pink.
    NSDictionary<NSString *, NSNumber *> *symbols =
        @{@"x" : @0xFF35C08A, @"a" : @0xFFF0506E, @"b" : @0xFF6E9BE6, @"y" : @0xFFE58FC8};
    NSNumber *symbol = symbols[input];
    if (symbol == nil) return NO;
    *fill = DefaultStyleForConsole(console).face;
    *label = symbol.unsignedIntValue;
    return YES;
  }
  if ([console isEqualToString:@"n64"]) {
    // A blue, B green, C buttons yellow, START red.
    if ([input isEqualToString:@"a"]) {
      *fill = 0xFF1F4FB4;
      *label = 0xFFFFFFFF;
    } else if ([input isEqualToString:@"b"]) {
      *fill = 0xFF1F8A3B;
      *label = 0xFFFFFFFF;
    } else if ([input hasPrefix:@"c"]) {
      *fill = 0xFFF2C200;
      *label = dark;
    } else if ([input isEqualToString:@"start"]) {
      *fill = 0xFFD12A2A;
      *label = 0xFFFFFFFF;
    } else if ([input isEqualToString:@"z"]) {
      *fill = 0xFF55565C;
      *label = 0xFFFFFFFF;
    } else {
      return NO;
    }
    return YES;
  }
  if ([console isEqualToString:@"arcade"]) {
    // Six coloured buttons, gold COIN.
    NSDictionary<NSString *, NSArray<NSNumber *> *> *colors = @{
      @"b" : @[ @0xFFE53935, @0xFFFFFFFF ],
      @"a" : @[ @0xFFFDD835, @(dark) ],
      @"y" : @[ @0xFF43A047, @0xFFFFFFFF ],
      @"x" : @[ @0xFF1E88E5, @0xFFFFFFFF ],
      @"l" : @[ @0xFFF5F5F5, @0xFF202020 ],
      @"r" : @[ @0xFF8E24AA, @0xFFFFFFFF ],
      @"select" : @[ @0xFFFFB300, @(dark) ],
    };
    NSArray<NSNumber *> *pair = colors[input];
    if (pair == nil) return NO;
    *fill = pair[0].unsignedIntValue;
    *label = pair[1].unsignedIntValue;
    return YES;
  }
  if (DefaultIs(console, @[ @"md", @"mcd", @"32x" ]) && DefaultIs(input, @[ @"x", @"y", @"z" ])) {
    // Six-button pad: smaller grey X, Y, Z.
    *fill = 0xFF4A4A4E;
    *label = 0xFFD9D9DE;
    return YES;
  }
  return NO;
}

#pragma mark - Plan (design units)

/// One planned control, frame in design units relative to its group.
@interface LibretroDefaultPart : NSObject
@property(nonatomic, copy) NSString *identifier;
@property(nonatomic, assign) LibretroSkinItemKind kind;
@property(nonatomic, assign) LibretroSkinItemShape shape;
@property(nonatomic, copy) NSArray<NSString *> *inputs;
@property(nonatomic, assign) LibretroRect frame;
@end

@implementation LibretroDefaultPart
@end

/// Controls placed together (D-pad and sticks, face buttons); normalized so
/// the bounding box starts at {0, 0}.
@interface LibretroDefaultGroup : NSObject
@property(nonatomic, strong) NSMutableArray<LibretroDefaultPart *> *parts;
@property(nonatomic, assign) double width;
@property(nonatomic, assign) double height;
- (void)addIdentifier:(NSString *)identifier
                 kind:(LibretroSkinItemKind)kind
                shape:(LibretroSkinItemShape)shape
               inputs:(NSArray<NSString *> *)inputs
                frame:(LibretroRect)frame;
- (void)addButton:(NSString *)input map:(LibretroInputMap *)map diameter:(double)diameter x:(double)x y:(double)y;
- (void)normalize;
@end

@implementation LibretroDefaultGroup

- (instancetype)init {
  self = [super init];
  if (self) {
    _parts = [NSMutableArray array];
  }
  return self;
}

- (void)addIdentifier:(NSString *)identifier
                 kind:(LibretroSkinItemKind)kind
                shape:(LibretroSkinItemShape)shape
               inputs:(NSArray<NSString *> *)inputs
                frame:(LibretroRect)frame {
  LibretroDefaultPart *part = [LibretroDefaultPart new];
  part.identifier = identifier;
  part.kind = kind;
  part.shape = shape;
  part.inputs = inputs;
  part.frame = frame;
  [_parts addObject:part];
}

/// Round face button centred on (x, y), only when the console has `input`.
- (void)addButton:(NSString *)input map:(LibretroInputMap *)map diameter:(double)diameter x:(double)x y:(double)y {
  if (![map.buttons containsObject:input]) return;
  [self addIdentifier:input
                 kind:LibretroSkinItemKindButton
                shape:LibretroSkinItemShapeCircle
               inputs:@[ input ]
                frame:LibretroRectMake(x - diameter / 2, y - diameter / 2, diameter, diameter)];
}

- (void)normalize {
  if (_parts.count == 0) {
    _width = 0;
    _height = 0;
    return;
  }
  double minX = INFINITY, minY = INFINITY, maxX = -INFINITY, maxY = -INFINITY;
  for (LibretroDefaultPart *part in _parts) {
    LibretroRect frame = part.frame;
    minX = MIN(minX, frame.x);
    minY = MIN(minY, frame.y);
    maxX = MAX(maxX, frame.x + frame.w);
    maxY = MAX(maxY, frame.y + frame.h);
  }
  for (LibretroDefaultPart *part in _parts) {
    LibretroRect frame = part.frame;
    frame.x -= minX;
    frame.y -= minY;
    part.frame = frame;
  }
  _width = maxX - minX;
  _height = maxY - minY;
}

@end

/// Every control of a console's default skin: left group (D-pad, sticks),
/// right group (face buttons), shoulders and pills (outer first).
@interface LibretroDefaultPlan : NSObject
@property(nonatomic, strong) LibretroDefaultGroup *left;
@property(nonatomic, strong) LibretroDefaultGroup *right;
@property(nonatomic, copy) NSArray<NSString *> *leftShoulders;
@property(nonatomic, copy) NSArray<NSString *> *rightShoulders;
@property(nonatomic, copy) NSArray<NSString *> *leftPills;
@property(nonatomic, copy) NSArray<NSString *> *rightPills;
@end

@implementation LibretroDefaultPlan
@end

static NSArray<NSString *> *DefaultLeftStickInputs(void) {
  return @[ @"leftStickUp", @"leftStickDown", @"leftStickLeft", @"leftStickRight" ];
}

static NSArray<NSString *> *DefaultRightStickInputs(void) {
  return @[ @"rightStickUp", @"rightStickDown", @"rightStickLeft", @"rightStickRight" ];
}

static NSArray<NSString *> *DefaultAvailable(NSArray<NSString *> *inputs, LibretroInputMap *map,
                                             NSMutableSet<NSString *> *used) {
  NSMutableArray<NSString *> *available = [NSMutableArray array];
  for (NSString *input in inputs) {
    if (![map.buttons containsObject:input] || [used containsObject:input]) continue;
    [used addObject:input];
    [available addObject:input];
  }
  return available;
}

static LibretroDefaultPlan *DefaultPlanForConsole(NSString *console, LibretroInputMap *map) {
  BOOL directions = [map targetForInput:@"up"].kind == LibretroInputTargetButton;
  NSArray<NSString *> *dpadInputs = @[ @"up", @"down", @"left", @"right" ];

  // Left: D-pad and / or Circle Pad, analog stick.
  LibretroDefaultGroup *left = [LibretroDefaultGroup new];
  if (map.hasLeftStick && (!directions || [console isEqualToString:@"n64"])) {
    [left addIdentifier:@"leftStick"
                   kind:LibretroSkinItemKindThumbstick
                  shape:LibretroSkinItemShapeStick
                 inputs:DefaultLeftStickInputs()
                  frame:LibretroRectMake(0, 0, 136, 136)];
  } else if (map.hasLeftStick) {
    if ([console isEqualToString:@"3ds"]) {
      // Circle Pad above the D-pad, as on the console.
      [left addIdentifier:@"leftStick"
                     kind:LibretroSkinItemKindThumbstick
                    shape:LibretroSkinItemShapeStick
                   inputs:DefaultLeftStickInputs()
                    frame:LibretroRectMake(4, 0, 112, 112)];
      [left addIdentifier:@"dpad"
                     kind:LibretroSkinItemKindDPad
                    shape:LibretroSkinItemShapeDPad
                   inputs:dpadInputs
                    frame:LibretroRectMake(0, 126, 120, 120)];
    } else {
      // PSP: D-pad above the analog nub.
      [left addIdentifier:@"dpad"
                     kind:LibretroSkinItemKindDPad
                    shape:LibretroSkinItemShapeDPad
                   inputs:dpadInputs
                    frame:LibretroRectMake(0, 0, 124, 124)];
      [left addIdentifier:@"leftStick"
                     kind:LibretroSkinItemKindThumbstick
                    shape:LibretroSkinItemShapeStick
                   inputs:DefaultLeftStickInputs()
                    frame:LibretroRectMake(8, 138, 108, 108)];
    }
  } else if (directions) {
    [left addIdentifier:@"dpad"
                   kind:LibretroSkinItemKindDPad
                  shape:LibretroSkinItemShapeDPad
                 inputs:dpadInputs
                  frame:LibretroRectMake(0, 0, 150, 150)];
  }
  [left normalize];

  // Right: face buttons laid out like the original controller.
  LibretroDefaultGroup *right = [LibretroDefaultGroup new];
  if (DefaultIs(console, @[ @"snes", @"nds", @"3ds", @"psx", @"psp" ])) {
    double top = 0;
    if ([console isEqualToString:@"3ds"] && map.hasRightStick) {
      // New 3DS C-stick above the face buttons.
      [right addIdentifier:@"rightStick"
                      kind:LibretroSkinItemKindThumbstick
                     shape:LibretroSkinItemShapeStick
                    inputs:DefaultRightStickInputs()
                     frame:LibretroRectMake(116, 0, 54, 54)];
      top = 40;
    }
    // Diamond: X / triangle top, A / circle right, B / cross bottom, Y / square left.
    const double diameter = 54, offset = 56;
    const double x = offset + diameter / 2, y = top + offset + diameter / 2;
    [right addButton:@"x" map:map diameter:diameter x:x y:y - offset];
    [right addButton:@"a" map:map diameter:diameter x:x + offset y:y];
    [right addButton:@"b" map:map diameter:diameter x:x y:y + offset];
    [right addButton:@"y" map:map diameter:diameter x:x - offset y:y];
  } else if (DefaultIs(console, @[ @"md", @"mcd", @"32x" ])) {
    // Six-button pad: A B C, and the smaller X Y Z above them.
    [right addButton:@"a" map:map diameter:56 x:30 y:116];
    [right addButton:@"b" map:map diameter:56 x:94 y:104];
    [right addButton:@"c" map:map diameter:56 x:158 y:92];
    [right addButton:@"x" map:map diameter:40 x:30 y:50];
    [right addButton:@"y" map:map diameter:40 x:94 y:38];
    [right addButton:@"z" map:map diameter:40 x:158 y:26];
  } else if ([console isEqualToString:@"arcade"]) {
    // Two staggered rows: 3 4 5 above 1 2 6.
    [right addButton:@"y" map:map diameter:52 x:36 y:26];
    [right addButton:@"x" map:map diameter:52 x:98 y:20];
    [right addButton:@"l" map:map diameter:52 x:160 y:20];
    [right addButton:@"b" map:map diameter:52 x:26 y:90];
    [right addButton:@"a" map:map diameter:52 x:88 y:84];
    [right addButton:@"r" map:map diameter:52 x:150 y:84];
  } else if ([console isEqualToString:@"n64"]) {
    // B above-left of A, C buttons in a diamond above them.
    [right addButton:@"b" map:map diameter:50 x:25 y:84];
    [right addButton:@"a" map:map diameter:56 x:68 y:140];
    [right addButton:@"cUp" map:map diameter:38 x:124 y:19];
    [right addButton:@"cDown" map:map diameter:38 x:124 y:99];
    [right addButton:@"cLeft" map:map diameter:38 x:84 y:59];
    [right addButton:@"cRight" map:map diameter:38 x:164 y:59];
  } else if (DefaultIs(console, @[ @"gb", @"gbc", @"gba" ])) {
    // Handhelds: B low left, A high right.
    [right addButton:@"b" map:map diameter:66 x:33 y:73];
    [right addButton:@"a" map:map diameter:66 x:103 y:33];
  } else {
    // NES and Sega 8-bit pads: B / 1 left, A / 2 right.
    [right addButton:@"b" map:map diameter:66 x:33 y:33];
    [right addButton:@"a" map:map diameter:66 x:111 y:33];
  }
  [right normalize];

  NSMutableSet<NSString *> *used = [NSMutableSet set];
  for (LibretroDefaultPart *part in [left.parts arrayByAddingObjectsFromArray:right.parts]) {
    [used addObjectsFromArray:part.inputs];
  }
  NSArray<NSString *> *leftShoulders = @[];
  NSArray<NSString *> *rightShoulders = @[];
  if (DefaultIs(console, @[ @"gba", @"snes", @"nds", @"psp" ])) {
    leftShoulders = @[ @"l" ];
    rightShoulders = @[ @"r" ];
  } else if ([console isEqualToString:@"n64"]) {
    leftShoulders = @[ @"l", @"z" ];
    rightShoulders = @[ @"r" ];
  } else if (DefaultIs(console, @[ @"psx", @"3ds" ])) {
    // L1 / L outside, L2 / ZL inside.
    leftShoulders = @[ @"l", @"l2" ];
    rightShoulders = @[ @"r", @"r2" ];
  }
  LibretroDefaultPlan *plan = [LibretroDefaultPlan new];
  plan.left = left;
  plan.right = right;
  plan.leftShoulders = DefaultAvailable(leftShoulders, map, used);
  plan.rightShoulders = DefaultAvailable(rightShoulders, map, used);

  NSString *leftPill = DefaultIs(console, @[ @"md", @"mcd", @"32x" ]) ? @"mode" : @"select";
  NSMutableArray<NSString *> *leftPills = [DefaultAvailable(@[ leftPill ], map, used) mutableCopy];
  NSMutableArray<NSString *> *rightPills = [DefaultAvailable(@[ @"start" ], map, used) mutableCopy];
  // Any other button of the console (PlayStation L3 / R3...) becomes a pill.
  for (NSString *input in map.buttons) {
    if ([used containsObject:input]) continue;
    [used addObject:input];
    if ([input hasPrefix:@"l"]) {
      [leftPills addObject:input];
    } else if ([input hasPrefix:@"r"]) {
      [rightPills addObject:input];
    } else if (leftPills.count <= rightPills.count) {
      [leftPills addObject:input];
    } else {
      [rightPills addObject:input];
    }
  }
  plan.leftPills = leftPills;
  plan.rightPills = rightPills;
  return plan;
}

#pragma mark - Screens

static double DefaultSingleAspect(NSString *console) {
  if (DefaultIs(console, @[ @"gb", @"gbc", @"gg" ])) return 10.0 / 9.0;
  if ([console isEqualToString:@"gba"]) return 3.0 / 2.0;
  if ([console isEqualToString:@"psp"]) return 480.0 / 272.0;
  return 4.0 / 3.0;
}

/// Normalized region of the "top" or "bottom" screen in the core picture.
static LibretroRect DefaultRegion(NSString *console, NSString *role, NSDictionary *regions) {
  NSArray *values = [regions isKindOfClass:[NSDictionary class]] ? regions[role] : nil;
  if ([values isKindOfClass:[NSArray class]] && values.count == 4) {
    double numbers[4] = {0, 0, 0, 0};
    BOOL valid = YES;
    for (NSUInteger index = 0; index < 4; index++) {
      id value = values[index];
      if (![value isKindOfClass:[NSNumber class]] || !isfinite([(NSNumber *)value doubleValue])) {
        valid = NO;
        break;
      }
      numbers[index] = [(NSNumber *)value doubleValue];
    }
    if (valid && numbers[2] > 0 && numbers[3] > 0) {
      return LibretroRectMake(numbers[0], numbers[1], numbers[2], numbers[3]);
    }
  }
  if ([role isEqualToString:@"bottom"]) {
    return [console isEqualToString:@"3ds"] ? LibretroRectMake(0.1, 0.5, 0.8, 0.5) : LibretroRectMake(0, 0.5, 1, 0.5);
  }
  return LibretroRectMake(0, 0, 1, 0.5);
}

/// Places one or two screens of `sizes` (console pixels) in `area`, as large
/// as possible, centred (top-aligned with `alignTop`). Returns the count.
static NSUInteger DefaultArrange(LibretroRect area, NSString *arrangement, const LibretroSize *sizes, NSUInteger count,
                                 BOOL alignTop, double gap, LibretroRect *out) {
  if (count == 0) return 0;
  LibretroSize first = sizes[0];
  if (count == 1) {
    double scale = MAX(MIN(area.w / first.w, area.h / first.h), 0);
    double width = first.w * scale, height = first.h * scale;
    double y = alignTop ? area.y : area.y + (area.h - height) / 2;
    out[0] = LibretroRectMake(area.x + (area.w - width) / 2, y, width, height);
    return 1;
  }
  LibretroSize second = sizes[1];
  if ([arrangement isEqualToString:LibretroArrangementSideBySide]) {
    double scale = MAX(MIN((area.w - gap) / (first.w + second.w), area.h / MAX(first.h, second.h)), 0);
    double width = (first.w + second.w) * scale + gap, height = MAX(first.h, second.h) * scale;
    double x = area.x + (area.w - width) / 2, y = alignTop ? area.y : area.y + (area.h - height) / 2;
    out[0] = LibretroRectMake(x, y + (height - first.h * scale) / 2, first.w * scale, first.h * scale);
    out[1] = LibretroRectMake(x + first.w * scale + gap, y + (height - second.h * scale) / 2, second.w * scale,
                              second.h * scale);
    return 2;
  }
  // Stacked, or large top: the second screen at half size below the first.
  double factor = [arrangement isEqualToString:LibretroArrangementLargeTop] ? 0.5 : 1.0;
  double scale = MAX(MIN(area.w / MAX(first.w, second.w * factor), (area.h - gap) / (first.h + second.h * factor)), 0);
  double width = MAX(first.w, second.w * factor) * scale, height = (first.h + second.h * factor) * scale + gap;
  double x = area.x + (area.w - width) / 2, y = alignTop ? area.y : area.y + (area.h - height) / 2;
  out[0] = LibretroRectMake(x + (width - first.w * scale) / 2, y, first.w * scale, first.h * scale);
  out[1] = LibretroRectMake(x + (width - second.w * scale * factor) / 2, y + first.h * scale + gap,
                            second.w * scale * factor, second.h * scale * factor);
  return 2;
}

#pragma mark - Builder (view points)

/// Turns the plan into skin items at scale `k`.
@interface LibretroDefaultBuilder : NSObject
@property(nonatomic, copy) NSString *console;
@property(nonatomic, strong) LibretroInputMap *map;
@property(nonatomic, assign) DefaultStyle style;
@property(nonatomic, assign) double scale;
@property(nonatomic, assign) double shoulderWidth;
@property(nonatomic, assign) double shoulderHeight;
@property(nonatomic, strong) NSMutableArray<LibretroSkinItem *> *items;
- (void)addGroup:(LibretroDefaultGroup *)group x:(double)x y:(double)y;
- (void)addShoulders:(NSArray<NSString *> *)inputs x:(double)x y:(double)y fromRight:(BOOL)fromRight;
- (void)addPills:(NSArray<NSString *> *)inputs x:(double)x y:(double)y fromRight:(BOOL)fromRight;
@end

@implementation LibretroDefaultBuilder

- (instancetype)init {
  self = [super init];
  if (self) {
    _items = [NSMutableArray array];
  }
  return self;
}

- (void)addIdentifier:(NSString *)identifier
                 kind:(LibretroSkinItemKind)kind
                shape:(LibretroSkinItemShape)shape
               inputs:(NSArray<NSString *> *)inputs
                frame:(LibretroRect)frame {
  DefaultStyle style = self.style;
  LibretroSkinItem *item = [LibretroSkinItem new];
  item.identifier = identifier;
  item.kind = kind;
  item.shape = shape;
  item.inputs = inputs;
  item.frame = frame;
  item.assetFrame = frame;
  item.movable = YES;
  double edge = (kind == LibretroSkinItemKindDPad || kind == LibretroSkinItemKindThumbstick ? 12 : 6) * self.scale;
  LibretroInsets edges = {edge, edge, edge, edge};
  item.hitFrame = LibretroRectOutset(frame, edges);
  uint32_t fill = 0, label = 0;
  if (kind == LibretroSkinItemKindDPad) {
    fill = style.dpad;
  } else if (kind == LibretroSkinItemKindThumbstick) {
    fill = [identifier isEqualToString:@"rightStick"] ? 0xFF8A8F99 : style.stick;
    item.thumbstickSize = (LibretroSize){frame.w * 0.5, frame.h * 0.5};
  } else {
    NSString *input = inputs.firstObject ?: identifier;
    item.label = [self.map glyphForInput:input] ?: input.uppercaseString;
    if (!DefaultInputColors(self.console, input, &fill, &label)) {
      if (shape == LibretroSkinItemShapePill) {
        fill = style.pill;
        label = style.pillLabel;
      } else if (shape == LibretroSkinItemShapeRounded) {
        fill = style.shoulder;
        label = style.shoulderLabel;
      } else {
        fill = style.face;
        label = style.faceLabel;
      }
    }
  }
  item.fillColor = fill;
  item.labelColor = label;
  [self.items addObject:item];
}

- (void)addGroup:(LibretroDefaultGroup *)group x:(double)x y:(double)y {
  double k = self.scale;
  for (LibretroDefaultPart *part in group.parts) {
    LibretroRect frame = part.frame;
    [self addIdentifier:part.identifier
                   kind:part.kind
                  shape:part.shape
                 inputs:part.inputs
                  frame:LibretroRectMake(x + frame.x * k, y + frame.y * k, frame.w * k, frame.h * k)];
  }
}

/// A row of shoulders or pills from `x`, outer first: rightward, or leftward
/// when `fromRight` (then `x` is the right edge).
- (void)addRow:(NSArray<NSString *> *)inputs
         shape:(LibretroSkinItemShape)shape
         width:(double)width
        height:(double)height
           gap:(double)gap
             x:(double)x
             y:(double)y
     fromRight:(BOOL)fromRight {
  double k = self.scale;
  double cursor = x;
  for (NSString *input in inputs) {
    double itemX = fromRight ? cursor - width * k : cursor;
    [self addIdentifier:input
                   kind:LibretroSkinItemKindButton
                  shape:shape
                 inputs:@[ input ]
                  frame:LibretroRectMake(itemX, y, width * k, height * k)];
    cursor = fromRight ? itemX - gap * k : itemX + (width + gap) * k;
  }
}

- (void)addShoulders:(NSArray<NSString *> *)inputs x:(double)x y:(double)y fromRight:(BOOL)fromRight {
  [self addRow:inputs
          shape:LibretroSkinItemShapeRounded
          width:self.shoulderWidth
         height:self.shoulderHeight
            gap:DefaultShoulderGap
              x:x
              y:y
      fromRight:fromRight];
}

- (void)addPills:(NSArray<NSString *> *)inputs x:(double)x y:(double)y fromRight:(BOOL)fromRight {
  [self addRow:inputs
          shape:LibretroSkinItemShapePill
          width:DefaultPillWidth
         height:DefaultPillHeight
            gap:DefaultPillGap
              x:x
              y:y
      fromRight:fromRight];
}

@end

static double DefaultRowWidth(NSUInteger count, double width, double gap) {
  return count == 0 ? 0 : count * width + (count - 1) * gap;
}

static double DefaultInset(double value) {
  return isfinite(value) && value > 0 ? value : 0;
}

#pragma mark - Default skins

@implementation LibretroDefaultSkins

+ (NSArray<NSString *> *)consoles {
  return [LibretroInputMap consoles];
}

+ (BOOL)isDualScreenConsole:(NSString *)console {
  return [console isEqualToString:@"nds"] || [console isEqualToString:@"3ds"];
}

+ (NSArray<NSString *> *)arrangementsForConsole:(NSString *)console orientation:(LibretroSkinOrientation)orientation {
  if (![self isDualScreenConsole:console]) return @[];
  if (orientation == LibretroSkinOrientationPortrait) {
    return @[ LibretroArrangementStacked, LibretroArrangementLargeTop, LibretroArrangementTopOnly,
              LibretroArrangementBottomOnly ];
  }
  return @[ LibretroArrangementSideBySide, LibretroArrangementLargeTop, LibretroArrangementStacked,
            LibretroArrangementTopOnly, LibretroArrangementBottomOnly ];
}

+ (NSString *)defaultArrangementForConsole:(NSString *)console orientation:(LibretroSkinOrientation)orientation {
  // Landscape 3DS: the main top screen large; DS games use both screens.
  if (orientation == LibretroSkinOrientationLandscape && [console isEqualToString:@"3ds"]) {
    return LibretroArrangementLargeTop;
  }
  return LibretroArrangementStacked;
}

+ (LibretroSkin *)skinForConsole:(NSString *)console {
  LibretroSkin *skin = [LibretroSkin new];
  skin.installedIdentifier = LibretroDefaultSkinIdentifier;
  skin.identifier = LibretroDefaultSkinIdentifier;
  skin.name = @"";
  skin.consoles = @[ console ];
  skin.gameTypeIdentifier = console;
  return skin;
}

+ (LibretroSkinRepresentation *)representationForConsole:(NSString *)console
                                             orientation:(LibretroSkinOrientation)orientation
                                                viewSize:(LibretroSize)viewSize
                                              safeInsets:(LibretroInsets)safeInsets
                                                    iPad:(BOOL)iPad
                                             arrangement:(NSString *)arrangement
                                                 swapped:(BOOL)swapped
                                                 regions:(NSDictionary<NSString *, NSArray<NSNumber *> *> *)regions {
  LibretroInputMap *map = [LibretroInputMap mapForConsole:console];
  LibretroDefaultPlan *plan = DefaultPlanForConsole(console, map);
  double viewWidth = isfinite(viewSize.w) && viewSize.w > 1 ? viewSize.w : 1;
  double viewHeight = isfinite(viewSize.h) && viewSize.h > 1 ? viewSize.h : 1;
  double safeTop = DefaultInset(safeInsets.top), safeLeft = DefaultInset(safeInsets.left);
  double safeBottom = DefaultInset(safeInsets.bottom), safeRight = DefaultInset(safeInsets.right);
  if (safeLeft + safeRight > viewWidth / 2) safeLeft = safeRight = 0;
  if (safeTop + safeBottom > viewHeight / 2) safeTop = safeBottom = 0;
  double shorter = MIN(viewWidth, viewHeight);
  double preferredScale = MIN(MAX(shorter / DefaultDesignSide, 0.8), iPad ? 1.5 : 1.25);

  // Screens: one for the whole picture, or the DS / 3DS top and bottom
  // screens in the chosen arrangement.
  BOOL dual = [self isDualScreenConsole:console];
  NSArray<NSString *> *roles = @[ @"full" ];
  LibretroSize screenSizes[2] = {{1, 1}, {1, 1}};
  if (dual) {
    NSArray<NSString *> *known = @[ LibretroArrangementStacked, LibretroArrangementSideBySide, LibretroArrangementLargeTop,
                                    LibretroArrangementTopOnly, LibretroArrangementBottomOnly ];
    if (arrangement == nil || ![known containsObject:arrangement]) {
      arrangement = [self defaultArrangementForConsole:console orientation:orientation];
    }
    if ([arrangement isEqualToString:LibretroArrangementTopOnly]) {
      roles = @[ swapped ? @"bottom" : @"top" ];
    } else if ([arrangement isEqualToString:LibretroArrangementBottomOnly]) {
      roles = @[ swapped ? @"top" : @"bottom" ];
    } else {
      roles = swapped ? @[ @"bottom", @"top" ] : @[ @"top", @"bottom" ];
    }
    LibretroSize nominal = [console isEqualToString:@"3ds"] ? (LibretroSize){400, 480} : (LibretroSize){256, 384};
    for (NSUInteger index = 0; index < roles.count; index++) {
      LibretroRect region = DefaultRegion(console, roles[index], regions);
      screenSizes[index] = (LibretroSize){region.w * nominal.w, region.h * nominal.h};
    }
  }

  NSUInteger shoulderCount = MAX(plan.leftShoulders.count, plan.rightShoulders.count);
  double shoulderWidth = shoulderCount > 1 ? 76 : 96;
  double shoulderHeight = shoulderCount > 1 ? 36 : 38;
  double shoulderRow = shoulderCount > 0 ? shoulderHeight : 0;
  double leftShoulderWidth = DefaultRowWidth(plan.leftShoulders.count, shoulderWidth, DefaultShoulderGap);
  double rightShoulderWidth = DefaultRowWidth(plan.rightShoulders.count, shoulderWidth, DefaultShoulderGap);
  LibretroDefaultGroup *left = plan.left, *right = plan.right;

  LibretroDefaultBuilder *builder = [LibretroDefaultBuilder new];
  builder.console = console;
  builder.map = map;
  builder.style = DefaultStyleForConsole(console);
  builder.shoulderWidth = shoulderWidth;
  builder.shoulderHeight = shoulderHeight;

  LibretroRect slots[2] = {{0, 0, 0, 0}, {0, 0, 0, 0}};
  NSUInteger slotCount = 0;
  LibretroRect panelFrame = {0, 0, 0, 0};
  double k = preferredScale;

  if (orientation == LibretroSkinOrientationPortrait) {
    // Game at the top below the safe area, controls on a panel below it:
    //   shoulders / D-pad and face buttons / pills.
    NSMutableArray<NSString *> *pills = [[plan.leftPills reverseObjectEnumerator].allObjects mutableCopy];
    [pills addObjectsFromArray:plan.rightPills];
    double mainRow = MAX(left.height, right.height);
    double pillRow = pills.count > 0 ? DefaultPillHeight : 0;
    double blockHeight = shoulderRow + (shoulderRow > 0 ? 14 : 0) + mainRow + (pillRow > 0 ? 16 + pillRow : 0);
    double blockWidth = MAX(MAX(left.width + right.width + 20, leftShoulderWidth + rightShoulderWidth + 20),
                            DefaultRowWidth(pills.count, DefaultPillWidth, DefaultPillGap));
    double contentWidth = MAX(viewWidth - safeLeft - safeRight, 1);
    double available = MAX(viewHeight - safeTop - safeBottom, 1);
    double natural;
    if (dual) {
      LibretroRect tall = LibretroRectMake(0, 0, contentWidth, 1e6);
      LibretroRect rects[2];
      NSUInteger count = DefaultArrange(tall, arrangement, screenSizes, roles.count, YES, 0, rects);
      natural = 0;
      for (NSUInteger index = 0; index < count; index++) natural = MAX(natural, rects[index].y + rects[index].h);
    } else {
      natural = contentWidth / DefaultSingleAspect(console);
    }
    double gameMinimum = MIN(natural, 0.42 * available);
    double bottomPadding = safeBottom > 0 ? 6 : 14;
    double scaleForWidth = contentWidth / (blockWidth + 28);
    double scaleForHeight = (available - gameMinimum) / (blockHeight + 14 + bottomPadding + 6);
    k = MIN(MAX(MIN(MIN(preferredScale, scaleForWidth), scaleForHeight), DefaultMinimumScale), preferredScale);
    builder.scale = k;

    double gap = 6 * k, topPadding = 14 * k, bottomInset = bottomPadding * k;
    double gameMaximum = MAX(viewHeight - safeTop - gap - topPadding - blockHeight * k - bottomInset - safeBottom, 1);
    double gameBottom = safeTop;
    if (dual) {
      slotCount = DefaultArrange(LibretroRectMake(safeLeft, safeTop, contentWidth, gameMaximum), arrangement,
                                 screenSizes, roles.count, YES, 4 * k, slots);
      for (NSUInteger index = 0; index < slotCount; index++) {
        gameBottom = MAX(gameBottom, slots[index].y + slots[index].h);
      }
    } else {
      double gameHeight = MIN(natural, gameMaximum);
      slots[0] = LibretroRectMake(safeLeft, safeTop, contentWidth, gameHeight);
      slotCount = 1;
      gameBottom = safeTop + gameHeight;
    }
    double panelTop = gameBottom + gap;
    panelFrame = LibretroRectMake(0, panelTop, viewWidth, MAX(viewHeight - panelTop, 0));
    double contentTop = panelTop + topPadding, contentBottom = viewHeight - safeBottom - bottomInset;
    // Slightly below the middle of the panel, closer to the thumbs.
    double blockY = contentTop + MAX(0, contentBottom - contentTop - blockHeight * k) * 0.6;
    double x0 = safeLeft + 14 * k, x1 = viewWidth - safeRight - 14 * k;
    [builder addShoulders:plan.leftShoulders x:x0 y:blockY fromRight:NO];
    [builder addShoulders:plan.rightShoulders x:x1 y:blockY fromRight:YES];
    double mainY = blockY + (shoulderRow + (shoulderRow > 0 ? 14 : 0)) * k;
    [builder addGroup:left x:x0 y:mainY + (mainRow - left.height) * k / 2];
    [builder addGroup:right x:x1 - right.width * k y:mainY + (mainRow - right.height) * k / 2];
    if (pills.count > 0) {
      double rowWidth = DefaultRowWidth(pills.count, DefaultPillWidth, DefaultPillGap) * k;
      [builder addPills:pills x:(x0 + x1) / 2 - rowWidth / 2 y:mainY + (mainRow + 16) * k fromRight:NO];
    }
  } else {
    // Game over the whole safe area, translucent controls on both sides:
    //   shoulders and pills at the top, D-pad / face buttons at the bottom.
    LibretroRect safeArea = LibretroRectMake(safeLeft, safeTop, MAX(viewWidth - safeLeft - safeRight, 1),
                                             MAX(viewHeight - safeTop - safeBottom, 1));
    double leftWidth = MAX(MAX(left.width, leftShoulderWidth),
                           DefaultRowWidth(plan.leftPills.count, DefaultPillWidth, DefaultPillGap));
    double rightWidth = MAX(MAX(right.width, rightShoulderWidth),
                            DefaultRowWidth(plan.rightPills.count, DefaultPillWidth, DefaultPillGap));
    double topRows = shoulderRow > 0 ? shoulderRow + 12 : 0;
    double leftHeight = topRows + (plan.leftPills.count > 0 ? DefaultPillHeight + 12 : 0) + left.height;
    double rightHeight = topRows + (plan.rightPills.count > 0 ? DefaultPillHeight + 12 : 0) + right.height;
    double scaleForHeight = safeArea.h / (MAX(leftHeight, rightHeight) + 20);
    // DS / 3DS keep at least a third of the width for the screens.
    double scaleForWidth = dual ? (safeArea.w * 0.64) / (leftWidth + rightWidth + 32 + 28)
                                : safeArea.w / (leftWidth + rightWidth + 32 + 24);
    k = MIN(MAX(MIN(MIN(preferredScale, scaleForHeight), scaleForWidth), DefaultMinimumScale), preferredScale);
    builder.scale = k;

    double x0 = safeArea.x + 16 * k, x1 = safeArea.x + safeArea.w - 16 * k;
    double top = safeArea.y + 10 * k, bottom = safeArea.y + safeArea.h - 10 * k;
    [builder addShoulders:plan.leftShoulders x:x0 y:top fromRight:NO];
    [builder addShoulders:plan.rightShoulders x:x1 y:top fromRight:YES];
    double pillY = top + topRows * k;
    [builder addPills:plan.leftPills x:x0 y:pillY fromRight:NO];
    [builder addPills:plan.rightPills x:x1 y:pillY fromRight:YES];
    [builder addGroup:left x:x0 + (leftWidth - left.width) * k / 2 y:bottom - left.height * k];
    [builder addGroup:right x:x1 - rightWidth * k + (rightWidth - right.width) * k / 2 y:bottom - right.height * k];
    if (dual) {
      // Screens between the two control columns, never under a control.
      double areaLeft = x0 + (leftWidth + 14) * k, areaRight = x1 - (rightWidth + 14) * k;
      LibretroRect area = LibretroRectMake(areaLeft, safeArea.y, MAX(areaRight - areaLeft, 1), safeArea.h);
      slotCount = DefaultArrange(area, arrangement, screenSizes, roles.count, NO, 4 * k, slots);
    } else {
      slots[0] = safeArea;
      slotCount = 1;
    }
  }

  NSMutableArray<LibretroSkinScreen *> *screens = [NSMutableArray array];
  for (NSUInteger index = 0; index < slotCount && index < roles.count; index++) {
    LibretroSkinScreen *screen = [LibretroSkinScreen new];
    NSString *role = roles[index];
    screen.role = role;
    screen.source = dual ? DefaultRegion(console, role, regions) : LibretroRectMake(0, 0, 1, 1);
    screen.outputFrame = slots[index];
    screen.hasOutputFrame = YES;
    screen.touchScreen = [role isEqualToString:@"bottom"] && map.hasTouchScreen;
    [screens addObject:screen];
    if (screen.touchScreen) {
      // Exactly over the bottom screen; extended edges never apply.
      LibretroSkinItem *touch = [LibretroSkinItem new];
      touch.identifier = @"touchScreen";
      touch.kind = LibretroSkinItemKindTouchScreen;
      touch.shape = LibretroSkinItemShapeNone;
      touch.inputs = @[ @"touchScreen" ];
      touch.frame = slots[index];
      touch.hitFrame = slots[index];
      touch.assetFrame = slots[index];
      touch.movable = NO;
      [builder.items addObject:touch];
    }
  }

  LibretroSkinRepresentation *representation = [LibretroSkinRepresentation new];
  representation.orientation = orientation;
  representation.device = iPad ? @"ipad" : @"iphone";
  representation.displayType = !iPad && safeBottom > 0 ? @"edgeToEdge" : @"standard";
  representation.mappingSize = (LibretroSize){viewWidth, viewHeight};
  representation.items = builder.items;
  representation.screens = screens;
  representation.translucent = orientation == LibretroSkinOrientationLandscape;
  representation.generated = YES;
  representation.extendedEdges = (LibretroInsets){6 * k, 6 * k, 6 * k, 6 * k};
  if (orientation == LibretroSkinOrientationPortrait) {
    representation.panelColor = builder.style.panel;
    representation.panelFrame = panelFrame;
  }
  return representation;
}

@end
