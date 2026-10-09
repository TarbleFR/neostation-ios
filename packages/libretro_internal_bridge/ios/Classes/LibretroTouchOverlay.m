#import "LibretroTouchOverlay.h"

#import "LibretroInputState.h"

#include <math.h>
#include <string.h>

/// What one finger is doing.
typedef NS_ENUM(NSInteger, LibretroTouchMode) {
  /// Buttons and D-pads under the finger, hit-tested again on every move
  /// (Delta: a finger slides between buttons).
  LibretroTouchModeFree = 0,
  /// Started on a D-pad alone: stays bound to it, directions follow the
  /// finger even past its edge.
  LibretroTouchModeDPad,
  /// Started on a thumbstick: bound to it until released.
  LibretroTouchModeStick,
  /// RETRO_DEVICE_POINTER on the DS / 3DS touch screen.
  LibretroTouchModePointer,
  /// Controls disabled and outside the touch screen.
  LibretroTouchModeIgnored,
};

@interface LibretroTouchTrack : NSObject
@property(nonatomic, assign) LibretroTouchMode mode;
@property(nonatomic, copy) NSArray<LibretroLaidOutItem *> *items;
@property(nonatomic, strong, nullable) LibretroLaidOutItem *bound;
@property(nonatomic, assign) CGPoint location;
@property(nonatomic, assign) LibretroScreenMapping mapping;
@property(nonatomic, assign) int16_t pointerX;
@property(nonatomic, assign) int16_t pointerY;
@end

@implementation LibretroTouchTrack

- (instancetype)init {
  self = [super init];
  if (self) {
    _items = @[];
  }
  return self;
}

@end

static BOOL LibretroOverlayContains(LibretroRect rect, CGPoint point) {
  if (!(rect.w > 0) || !(rect.h > 0)) return NO;
  return point.x >= rect.x && point.y >= rect.y && point.x <= rect.x + rect.w && point.y <= rect.y + rect.h;
}

static double LibretroOverlayDistance(LibretroRect rect, CGPoint point) {
  double dx = MAX(MAX(rect.x - point.x, 0.0), point.x - (rect.x + rect.w));
  double dy = MAX(MAX(rect.y - point.y, 0.0), point.y - (rect.y + rect.h));
  return hypot(dx, dy);
}

static double LibretroOverlayNumber(id value, double fallback) {
  if (![value isKindOfClass:[NSNumber class]]) return fallback;
  double number = [(NSNumber *)value doubleValue];
  return isfinite(number) ? number : fallback;
}

@implementation LibretroTouchOverlay {
  LibretroInputState *_input;
  LibretroSkinLayoutResult *_layout;
  LibretroInputMap *_inputMap;
  NSDictionary<NSString *, NSArray<NSString *> *> *_touchRemap;
  NSMapTable<UITouch *, LibretroTouchTrack *> *_tracks;
  NSSet<NSNumber *> *_activeActions;
  NSSet<NSString *> *_pressedItems;
  // Layout editing.
  NSMutableArray<UITouch *> *_editTouches;
  NSString *_selectedItem;
  NSString *_editItem;
  LibretroSkinItem *_editBaseItem;
  LibretroSkinRepresentation *_editRepresentation;
  double _editStartDX;
  double _editStartDY;
  double _editStartScale;
  BOOL _dragging;
  CGPoint _dragStart;
  BOOL _pinching;
  double _pinchStartDistance;
  NSMutableDictionary<NSString *, LibretroSkinItem *> *_editBases;
  NSArray<LibretroSkinItem *> *_editObstacleItems;
  NSArray<LibretroSkinScreen *> *_editScreens;
  CGSize _editCacheSize;
}

- (instancetype)initWithInput:(LibretroInputState *)input {
  self = [super initWithFrame:CGRectZero];
  if (self) {
    _input = input;
    _inputMap = [LibretroInputMap mapForConsole:@"nes"];
    _tracks = [NSMapTable strongToStrongObjectsMapTable];
    _activeActions = [NSSet set];
    _pressedItems = [NSSet set];
    _editTouches = [NSMutableArray array];
    _editBases = [NSMutableDictionary dictionary];
    _touchScreenMappings = @[];
    self.multipleTouchEnabled = YES;
    self.backgroundColor = UIColor.clearColor;
    self.opaque = NO;
    // The game itself cannot be played with VoiceOver: the laid-out items
    // are not accessibility elements, only the overlay is identified.
    self.accessibilityIdentifier = @"libretro-touch-overlay";
  }
  return self;
}

#pragma mark - Configuration

- (void)applyLayout:(LibretroSkinLayoutResult *)layout
           inputMap:(LibretroInputMap *)inputMap
         touchRemap:(NSDictionary<NSString *, NSArray<NSString *> *> *)touchRemap {
  _layout = layout;
  if ([inputMap isKindOfClass:[LibretroInputMap class]]) _inputMap = inputMap;
  _touchRemap = [touchRemap isKindOfClass:[NSDictionary class]] ? [touchRemap copy] : nil;
  // Fingers already down follow their items to the new places.
  NSMutableDictionary<NSString *, LibretroLaidOutItem *> *byIdentifier = [NSMutableDictionary dictionary];
  for (LibretroLaidOutItem *laidOut in layout.items) {
    NSString *identifier = laidOut.item.identifier;
    if (identifier.length > 0 && byIdentifier[identifier] == nil) byIdentifier[identifier] = laidOut;
  }
  for (UITouch *touch in _tracks) {
    LibretroTouchTrack *track = [_tracks objectForKey:touch];
    if (track.mode == LibretroTouchModeDPad || track.mode == LibretroTouchModeStick) {
      LibretroLaidOutItem *replacement = byIdentifier[track.bound.item.identifier ?: @""];
      track.bound = replacement;
      if (replacement == nil) track.mode = LibretroTouchModeIgnored;
    } else if (track.mode == LibretroTouchModeFree) {
      NSMutableArray<LibretroLaidOutItem *> *items = [NSMutableArray array];
      for (LibretroLaidOutItem *laidOut in track.items) {
        LibretroLaidOutItem *replacement = byIdentifier[laidOut.item.identifier ?: @""];
        if (replacement != nil) [items addObject:replacement];
      }
      track.items = items;
    }
  }
  [self publish];
}

- (void)setControlsDisabled:(BOOL)controlsDisabled {
  if (_controlsDisabled == controlsDisabled) return;
  _controlsDisabled = controlsDisabled;
  [self publish];
}

- (void)setEditing:(BOOL)editing {
  if (_editing == editing) return;
  _editing = editing;
  // Game input stops while the layout is edited, and editing gestures end
  // with the mode.
  [self clearTracks];
  [self resetEditingGestures];
  [_editBases removeAllObjects];
  _editObstacleItems = nil;
  _editScreens = nil;
  _editCacheSize = CGSizeZero;
  [self publish];
}

- (void)setEditOverrides:(NSDictionary<NSString *, NSDictionary *> *)editOverrides {
  _editOverrides = [editOverrides isKindOfClass:[NSDictionary class]] ? [editOverrides copy] : nil;
}

- (void)setTouchScreenMappings:(NSArray<NSValue *> *)touchScreenMappings {
  _touchScreenMappings = [touchScreenMappings isKindOfClass:[NSArray class]] ? [touchScreenMappings copy] : @[];
}

#pragma mark - Inputs

- (NSArray<NSString *> *)inputsForItem:(LibretroSkinItem *)item {
  id remap = item.identifier.length > 0 ? _touchRemap[item.identifier] : nil;
  if ([remap isKindOfClass:[NSArray class]]) {
    NSMutableArray<NSString *> *inputs = [NSMutableArray array];
    for (id input in (NSArray *)remap) {
      [inputs addObject:[input isKindOfClass:[NSString class]] ? input : @""];
    }
    BOOL directional = item.kind == LibretroSkinItemKindDPad || item.kind == LibretroSkinItemKindThumbstick;
    // A D-pad or stick remap names its four directions; anything else keeps
    // the skin's inputs.
    if (!directional || inputs.count == 4) return inputs;
  }
  return item.inputs ?: @[];
}

/// Adds one logical input. Digital targets (buttons, actions) need at
/// least half a deflection; analog targets take the magnitude.
- (void)applyInput:(NSString *)input
         magnitude:(double)magnitude
             state:(LibretroCoreInput *)state
           actions:(NSMutableSet<NSNumber *> *)actions {
  if (![input isKindOfClass:[NSString class]] || input.length == 0) return;
  LibretroInputTarget target = [_inputMap targetForInput:input];
  switch (target.kind) {
    case LibretroInputTargetButton:
      if (magnitude >= 0.5) [_inputMap applyInput:input magnitude:1.0 toState:state];
      break;
    case LibretroInputTargetAnalog:
      if (magnitude > 0.001) [_inputMap applyInput:input magnitude:MIN(magnitude, 1.0) toState:state];
      break;
    case LibretroInputTargetAction:
      if (magnitude >= 0.5 && target.action != LibretroFrontendActionNone) [actions addObject:@(target.action)];
      break;
    case LibretroInputTargetPointer:
    case LibretroInputTargetNone:
      break;
  }
}

/// D-pad directions of `point` on `laidOut`, mapped to its four inputs.
/// Returns NO in the dead zone.
- (BOOL)applyDPad:(LibretroLaidOutItem *)laidOut
            point:(CGPoint)point
            state:(LibretroCoreInput *)state
          actions:(NSMutableSet<NSNumber *> *)actions {
  LibretroDirection directions = LibretroDPadDirections(laidOut.frame, point.x, point.y);
  if (directions == 0) return NO;
  NSArray<NSString *> *inputs = [self inputsForItem:laidOut.item];
  const LibretroDirection bits[4] = {LibretroDirectionUp, LibretroDirectionDown, LibretroDirectionLeft,
                                     LibretroDirectionRight};
  for (NSUInteger index = 0; index < 4 && index < inputs.count; index++) {
    if ((directions & bits[index]) != 0) [self applyInput:inputs[index] magnitude:1.0 state:state actions:actions];
  }
  return YES;
}

/// Stick deflection mapped to its up / down / left / right inputs with
/// their magnitudes (libretro y: positive downward).
- (void)applyStick:(LibretroLaidOutItem *)laidOut
             point:(CGPoint)point
             state:(LibretroCoreInput *)state
           actions:(NSMutableSet<NSNumber *> *)actions {
  double x = 0, y = 0;
  LibretroStickVector(laidOut.frame, point.x, point.y, &x, &y);
  NSArray<NSString *> *inputs = [self inputsForItem:laidOut.item];
  if (inputs.count < 4) return;
  if (y < 0) {
    [self applyInput:inputs[0] magnitude:-y state:state actions:actions];
  } else if (y > 0) {
    [self applyInput:inputs[1] magnitude:y state:state actions:actions];
  }
  if (x < 0) {
    [self applyInput:inputs[2] magnitude:-x state:state actions:actions];
  } else if (x > 0) {
    [self applyInput:inputs[3] magnitude:x state:state actions:actions];
  }
}

/// Rebuilds the touch input of port 0 from every finger, then reports
/// pressed items and frontend action edges.
- (void)publish {
  LibretroCoreInput state;
  memset(&state, 0, sizeof(state));
  NSMutableSet<NSNumber *> *actions = [NSMutableSet set];
  NSMutableSet<NSString *> *pressed = [NSMutableSet set];
  BOOL controls = !self.editing && !self.controlsDisabled;
  if (controls) {
    for (UITouch *touch in _tracks) {
      LibretroTouchTrack *track = [_tracks objectForKey:touch];
      CGPoint point = track.location;
      switch (track.mode) {
        case LibretroTouchModeFree:
          for (LibretroLaidOutItem *laidOut in track.items) {
            LibretroSkinItem *item = laidOut.item;
            if (item.kind == LibretroSkinItemKindDPad) {
              if ([self applyDPad:laidOut point:point state:&state actions:actions] && item.identifier.length > 0) {
                [pressed addObject:item.identifier];
              }
            } else if (item.kind == LibretroSkinItemKindButton) {
              for (NSString *input in [self inputsForItem:item]) {
                [self applyInput:input magnitude:1.0 state:&state actions:actions];
              }
              if (item.identifier.length > 0) [pressed addObject:item.identifier];
            }
          }
          break;
        case LibretroTouchModeDPad:
          if (track.bound != nil && [self applyDPad:track.bound point:point state:&state actions:actions] &&
              track.bound.item.identifier.length > 0) {
            [pressed addObject:track.bound.item.identifier];
          }
          break;
        case LibretroTouchModeStick:
          if (track.bound != nil) {
            [self applyStick:track.bound point:point state:&state actions:actions];
            if (track.bound.item.identifier.length > 0) [pressed addObject:track.bound.item.identifier];
          }
          break;
        case LibretroTouchModePointer:
        case LibretroTouchModeIgnored:
          break;
      }
    }
  }
  [_input setTouchInput:state];

  if (![pressed isEqualToSet:_pressedItems]) {
    _pressedItems = [pressed copy];
    if (self.pressedItemsChanged != nil) self.pressedItemsChanged(_pressedItems);
  }

  NSSet<NSNumber *> *previous = _activeActions;
  NSSet<NSNumber *> *current = [actions copy];
  _activeActions = current;
  void (^handler)(LibretroFrontendAction, BOOL) = self.actionHandler;
  if (handler == nil) return;
  // A handler may release every touch (the menu opens): each edge is
  // checked against the latest state before it is reported.
  for (NSNumber *action in previous) {
    if ([current containsObject:action] || [_activeActions containsObject:action]) continue;
    handler((LibretroFrontendAction)action.integerValue, NO);
  }
  for (NSNumber *action in current) {
    if ([previous containsObject:action] || ![_activeActions containsObject:action]) continue;
    handler((LibretroFrontendAction)action.integerValue, YES);
  }
}

#pragma mark - Pointer

- (BOOL)pointerInUse {
  for (UITouch *touch in _tracks) {
    if ([_tracks objectForKey:touch].mode == LibretroTouchModePointer) return YES;
  }
  return NO;
}

- (NSArray<NSValue *> *)pointerMappings {
  NSMutableArray<NSValue *> *mappings = [NSMutableArray array];
  for (NSValue *value in _touchScreenMappings) {
    if (![value isKindOfClass:[NSValue class]]) continue;
    NSUInteger size = 0;
    NSGetSizeAndAlignment(value.objCType, &size, NULL);
    if (size != sizeof(LibretroScreenMapping)) continue;
    [mappings addObject:value];
  }
  if (mappings.count > 0) return mappings;
  // No picture published yet: the laid-out touch-screen containers.
  for (LibretroLaidOutScreen *screen in _layout.screens) {
    if (!screen.touchScreen) continue;
    LibretroScreenMapping mapping;
    memset(&mapping, 0, sizeof(mapping));
    mapping.output = screen.container;
    mapping.source = screen.source;
    mapping.rotation = 0;
    [mappings addObject:[NSValue valueWithBytes:&mapping objCType:@encode(LibretroScreenMapping)]];
  }
  return mappings;
}

/// Starts the pointer for `track` when `point` is on a drawn touch screen,
/// or anywhere on a touch-screen item (`onTouchItem`: the nearest screen,
/// clamped). One pointer at a time.
- (BOOL)beginPointer:(LibretroTouchTrack *)track point:(CGPoint)point onTouchItem:(BOOL)onTouchItem {
  if ([self pointerInUse]) return NO;
  BOOL found = NO;
  double nearest = INFINITY;
  LibretroScreenMapping chosen;
  memset(&chosen, 0, sizeof(chosen));
  for (NSValue *value in [self pointerMappings]) {
    LibretroScreenMapping mapping;
    [value getValue:&mapping size:sizeof(mapping)];
    if (LibretroOverlayContains(mapping.output, point)) {
      chosen = mapping;
      found = YES;
      break;
    }
    if (onTouchItem) {
      double distance = LibretroOverlayDistance(mapping.output, point);
      if (distance < nearest) {
        nearest = distance;
        chosen = mapping;
      }
    }
  }
  if (!found && !(onTouchItem && isfinite(nearest))) return NO;
  int16_t x = 0, y = 0;
  if (!LibretroPointerFromPoint(chosen, point.x, point.y, YES, &x, &y)) return NO;
  track.mode = LibretroTouchModePointer;
  track.mapping = chosen;
  track.pointerX = x;
  track.pointerY = y;
  [_input setPointerX:x y:y pressed:YES];
  return YES;
}

- (void)movePointer:(LibretroTouchTrack *)track point:(CGPoint)point {
  int16_t x = track.pointerX, y = track.pointerY;
  // Clamped while held: a finger leaving the screen keeps touching its edge.
  if (!LibretroPointerFromPoint(track.mapping, point.x, point.y, YES, &x, &y)) return;
  track.pointerX = x;
  track.pointerY = y;
  [_input setPointerX:x y:y pressed:YES];
}

#pragma mark - Game touches

/// Items a sliding finger may press: buttons and D-pads (sticks and the
/// touch screen are only taken when a finger lands on them).
static NSArray<LibretroLaidOutItem *> *LibretroOverlaySlidable(NSArray<LibretroLaidOutItem *> *hits) {
  NSMutableArray<LibretroLaidOutItem *> *items = [NSMutableArray array];
  for (LibretroLaidOutItem *laidOut in hits) {
    LibretroSkinItemKind kind = laidOut.item.kind;
    if (kind == LibretroSkinItemKindButton || kind == LibretroSkinItemKindDPad) [items addObject:laidOut];
  }
  return items;
}

- (LibretroTouchTrack *)trackForPoint:(CGPoint)point {
  LibretroTouchTrack *track = [LibretroTouchTrack new];
  track.location = point;
  NSArray<LibretroLaidOutItem *> *hits =
      _layout != nil ? [LibretroSkinLayout itemsAtX:point.x y:point.y inLayout:_layout] : @[];
  BOOL touchItemOnly = hits.count > 0;
  for (LibretroLaidOutItem *laidOut in hits) {
    if (laidOut.item.kind != LibretroSkinItemKindTouchScreen) touchItemOnly = NO;
  }
  if (!self.controlsDisabled && !touchItemOnly && hits.count > 0) {
    LibretroLaidOutItem *first = hits.firstObject;
    if (hits.count == 1 && first.item.kind == LibretroSkinItemKindThumbstick) {
      track.mode = LibretroTouchModeStick;
      track.bound = first;
      return track;
    }
    if (hits.count == 1 && first.item.kind == LibretroSkinItemKindDPad) {
      track.mode = LibretroTouchModeDPad;
      track.bound = first;
      return track;
    }
    track.mode = LibretroTouchModeFree;
    track.items = LibretroOverlaySlidable(hits);
    return track;
  }
  // A touch-screen item alone, or nothing but a drawn touch screen.
  if ([self beginPointer:track point:point onTouchItem:touchItemOnly]) return track;
  // Controls stay off with a controller or the setting; elsewhere an empty
  // finger may still slide onto a button.
  track.mode = self.controlsDisabled ? LibretroTouchModeIgnored : LibretroTouchModeFree;
  return track;
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
  if (self.editing) {
    [self editTouchesBegan:touches];
    return;
  }
  for (UITouch *touch in touches) {
    [_tracks setObject:[self trackForPoint:[touch locationInView:self]] forKey:touch];
  }
  [self publish];
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
  if (self.editing) {
    [self editTouchesMoved];
    return;
  }
  BOOL changed = NO;
  for (UITouch *touch in touches) {
    LibretroTouchTrack *track = [_tracks objectForKey:touch];
    if (track == nil) continue;
    CGPoint point = [touch locationInView:self];
    track.location = point;
    switch (track.mode) {
      case LibretroTouchModePointer:
        [self movePointer:track point:point];
        break;
      case LibretroTouchModeFree:
        track.items = _layout != nil
                          ? LibretroOverlaySlidable([LibretroSkinLayout itemsAtX:point.x y:point.y inLayout:_layout])
                          : @[];
        changed = YES;
        break;
      case LibretroTouchModeDPad:
      case LibretroTouchModeStick:
        changed = YES;
        break;
      case LibretroTouchModeIgnored:
        break;
    }
  }
  if (changed) [self publish];
}

- (void)endTouches:(NSSet<UITouch *> *)touches {
  if (self.editing) {
    [self editTouchesEnded:touches];
    return;
  }
  for (UITouch *touch in touches) {
    LibretroTouchTrack *track = [_tracks objectForKey:touch];
    if (track == nil) continue;
    if (track.mode == LibretroTouchModePointer) {
      // Released where it was last seen.
      [_input setPointerX:track.pointerX y:track.pointerY pressed:NO];
    }
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

- (void)clearTracks {
  for (UITouch *touch in _tracks) {
    LibretroTouchTrack *track = [_tracks objectForKey:touch];
    if (track.mode == LibretroTouchModePointer) [_input setPointerX:track.pointerX y:track.pointerY pressed:NO];
  }
  [_tracks removeAllObjects];
}

- (void)releaseAllTouches {
  [self clearTracks];
  [self resetEditingGestures];
  [_input reset];
  [self publish];
}

#pragma mark - Layout editing

- (void)resetEditingGestures {
  [_editTouches removeAllObjects];
  _dragging = NO;
  _pinching = NO;
  _editItem = nil;
  _editBaseItem = nil;
  _editRepresentation = nil;
}

- (LibretroLaidOutItem *)laidOutItemWithIdentifier:(NSString *)identifier {
  if (identifier.length == 0) return nil;
  for (LibretroLaidOutItem *laidOut in _layout.items) {
    if ([laidOut.item.identifier isEqualToString:identifier]) return laidOut;
  }
  return nil;
}

/// Topmost movable item under `point` (its frame first, then its touch area).
- (LibretroLaidOutItem *)movableItemAtPoint:(CGPoint)point {
  NSArray<LibretroLaidOutItem *> *items = _layout.items ?: @[];
  for (int pass = 0; pass < 2; pass++) {
    for (LibretroLaidOutItem *laidOut in items.reverseObjectEnumerator) {
      LibretroSkinItem *item = laidOut.item;
      if (!item.movable || item.kind == LibretroSkinItemKindTouchScreen || item.identifier.length == 0) continue;
      if (LibretroOverlayContains(pass == 0 ? laidOut.frame : laidOut.hitFrame, point)) return laidOut;
    }
  }
  return nil;
}

- (void)selectItem:(NSString *)identifier {
  if ((identifier == nil && _selectedItem == nil) || [identifier isEqualToString:_selectedItem]) return;
  _selectedItem = [identifier copy];
  if (self.editSelectionChanged != nil) self.editSelectionChanged(_selectedItem);
}

/// Overrides are clamped by +[LibretroSkinLayout clampOverride:...] against
/// the item's original place. The original frame is the laid-out frame
/// with the stored override undone, placed in a generated representation
/// of the overlay size that also holds the touch screens (screens and
/// touch-screen items), the obstacles a moved control must avoid.
/// Original frames and obstacles do not move while editing: they are
/// computed once per item and overlay size, so a re-layout that arrives
/// after an editChanged report cannot skew them.
- (BOOL)prepareEditingForItem:(NSString *)identifier {
  if (identifier.length == 0) return NO;
  CGSize size = self.bounds.size;
  if (size.width < 1 || size.height < 1) return NO;
  if (!CGSizeEqualToSize(size, _editCacheSize)) {
    [_editBases removeAllObjects];
    _editObstacleItems = nil;
    _editScreens = nil;
    _editCacheSize = size;
  }
  NSDictionary *stored = _editOverrides[identifier];
  if (![stored isKindOfClass:[NSDictionary class]]) stored = nil;
  double dx = LibretroOverlayNumber(stored[@"dx"], 0);
  double dy = LibretroOverlayNumber(stored[@"dy"], 0);
  double scale = MIN(MAX(LibretroOverlayNumber(stored[@"scale"], 1), 0.5), 2.0);

  LibretroSkinItem *base = _editBases[identifier];
  if (base == nil) {
    LibretroLaidOutItem *target = [self laidOutItemWithIdentifier:identifier];
    if (target == nil || !target.item.movable) return NO;
    LibretroRect frame = target.frame;
    double width = frame.w / scale, height = frame.h / scale;
    double centerX = frame.x + frame.w / 2 - dx * size.width;
    double centerY = frame.y + frame.h / 2 - dy * size.height;
    base = [target.item copy];
    base.frame = LibretroRectMake(centerX - width / 2, centerY - height / 2, width, height);
    base.hitFrame = base.frame;
    base.assetFrame = base.frame;
    _editBases[identifier] = base;
  }

  if (_editObstacleItems == nil || _editScreens == nil) {
    NSMutableArray<LibretroSkinItem *> *obstacles = [NSMutableArray array];
    for (LibretroLaidOutItem *laidOut in _layout.items) {
      if (laidOut.item.kind != LibretroSkinItemKindTouchScreen) continue;
      LibretroSkinItem *touch = [laidOut.item copy];
      touch.frame = laidOut.frame;
      touch.hitFrame = laidOut.hitFrame;
      touch.assetFrame = laidOut.frame;
      [obstacles addObject:touch];
    }
    NSMutableArray<LibretroSkinScreen *> *screens = [NSMutableArray array];
    for (LibretroLaidOutScreen *laidOut in _layout.screens) {
      LibretroSkinScreen *screen = [LibretroSkinScreen new];
      screen.outputFrame = laidOut.container;
      screen.hasOutputFrame = YES;
      screen.source = laidOut.source;
      screen.role = laidOut.role ?: @"full";
      screen.touchScreen = laidOut.touchScreen;
      [screens addObject:screen];
    }
    _editObstacleItems = obstacles;
    _editScreens = screens;
  }
  NSMutableArray<LibretroSkinItem *> *items = [NSMutableArray arrayWithObject:base];
  [items addObjectsFromArray:_editObstacleItems];
  NSArray<LibretroSkinScreen *> *screens = _editScreens;
  LibretroSkinRepresentation *representation = [LibretroSkinRepresentation new];
  representation.generated = YES;
  representation.mappingSize = (LibretroSize){size.width, size.height};
  representation.orientation =
      size.width > size.height ? LibretroSkinOrientationLandscape : LibretroSkinOrientationPortrait;
  representation.items = items;
  representation.screens = screens;

  _editItem = [identifier copy];
  _editBaseItem = base;
  _editRepresentation = representation;
  _editStartDX = dx;
  _editStartDY = dy;
  _editStartScale = scale;
  return YES;
}

- (void)reportEditDX:(double)dx dy:(double)dy scale:(double)scale {
  if (_editItem == nil || _editBaseItem == nil || _editRepresentation == nil) return;
  CGSize size = self.bounds.size;
  UIEdgeInsets safe = self.safeAreaInsets;
  LibretroInsets insets = {safe.top, safe.left, safe.bottom, safe.right};
  NSDictionary<NSString *, NSNumber *> *proposed = @{@"dx" : @(dx), @"dy" : @(dy), @"scale" : @(scale)};
  NSDictionary<NSString *, NSNumber *> *clamped =
      [LibretroSkinLayout clampOverride:proposed
                                forItem:_editBaseItem
                         representation:_editRepresentation
                               viewSize:(LibretroSize){size.width, size.height}
                             safeInsets:insets];
  NSMutableDictionary<NSString *, NSDictionary *> *overrides =
      _editOverrides != nil ? [_editOverrides mutableCopy] : [NSMutableDictionary dictionary];
  NSDictionary *previous = overrides[_editItem];
  if ([previous isEqual:clamped]) return;
  overrides[_editItem] = clamped;
  _editOverrides = [overrides copy];
  if (self.editChanged != nil) self.editChanged(_editItem, clamped);
}

- (double)pinchDistance {
  if (_editTouches.count < 2) return 0;
  CGPoint first = [_editTouches[0] locationInView:self];
  CGPoint second = [_editTouches[1] locationInView:self];
  return hypot(first.x - second.x, first.y - second.y);
}

- (void)editTouchesBegan:(NSSet<UITouch *> *)touches {
  for (UITouch *touch in touches) {
    if (![_editTouches containsObject:touch]) [_editTouches addObject:touch];
  }
  if (_editTouches.count == 1) {
    // One finger: select and drag the movable item under it.
    CGPoint point = [_editTouches[0] locationInView:self];
    LibretroLaidOutItem *laidOut = [self movableItemAtPoint:point];
    _dragging = NO;
    _pinching = NO;
    if (laidOut != nil) {
      [self selectItem:laidOut.item.identifier];
      if ([self prepareEditingForItem:laidOut.item.identifier]) {
        _dragging = YES;
        _dragStart = point;
      }
    }
  } else if (!_pinching) {
    // Two fingers anywhere: pinch the selected item (a 44-point button
    // rarely holds two fingers).
    _dragging = NO;
    double distance = [self pinchDistance];
    if (_selectedItem != nil && distance > 1 && [self prepareEditingForItem:_selectedItem]) {
      _pinching = YES;
      _pinchStartDistance = distance;
    }
  }
}

- (void)editTouchesMoved {
  CGSize size = self.bounds.size;
  if (size.width < 1 || size.height < 1) return;
  if (_pinching) {
    double distance = [self pinchDistance];
    if (distance <= 1 || _pinchStartDistance <= 1) return;
    double scale = MIN(MAX(_editStartScale * distance / _pinchStartDistance, 0.5), 2.0);
    [self reportEditDX:_editStartDX dy:_editStartDY scale:scale];
  } else if (_dragging && _editTouches.count == 1) {
    CGPoint point = [_editTouches[0] locationInView:self];
    double dx = _editStartDX + (point.x - _dragStart.x) / size.width;
    double dy = _editStartDY + (point.y - _dragStart.y) / size.height;
    [self reportEditDX:dx dy:dy scale:_editStartScale];
  }
}

- (void)editTouchesEnded:(NSSet<UITouch *> *)touches {
  for (UITouch *touch in touches) [_editTouches removeObject:touch];
  if (_editTouches.count < 2) _pinching = NO;
  // After a pinch the remaining finger does not start a drag; lifting every
  // finger ends the gesture.
  _dragging = NO;
  if (_editTouches.count == 0) {
    _editItem = nil;
    _editBaseItem = nil;
    _editRepresentation = nil;
  }
}

@end
