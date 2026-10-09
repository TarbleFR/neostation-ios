#import "LibretroSkin.h"

#import "LibretroInputMap.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

NSString *const LibretroDefaultSkinIdentifier = @"default";

NSString *const LibretroSkinErrorInfoMissing = @"SKIN_INFO_MISSING";
NSString *const LibretroSkinErrorInfoInvalid = @"SKIN_INFO_INVALID";
NSString *const LibretroSkinErrorFieldMissing = @"SKIN_FIELD_MISSING";
NSString *const LibretroSkinErrorConsoleUnsupported = @"SKIN_CONSOLE_UNSUPPORTED";
NSString *const LibretroSkinErrorNoRepresentation = @"SKIN_NO_REPRESENTATION";
NSString *const LibretroSkinErrorNoPhoneOrTablet = @"SKIN_NO_DEVICE";
NSString *const LibretroSkinWarningOrientationMissing = @"SKIN_WARN_ORIENTATION_MISSING";
NSString *const LibretroSkinWarningAssetMissing = @"SKIN_WARN_ASSET_MISSING";
NSString *const LibretroSkinWarningUnknownInputs = @"SKIN_WARN_UNKNOWN_INPUTS";
NSString *const LibretroSkinWarningFiltersIgnored = @"SKIN_WARN_FILTERS_IGNORED";
NSString *const LibretroSkinWarningInputFrameIgnored = @"SKIN_WARN_INPUT_FRAME_IGNORED";
NSString *const LibretroSkinWarningItemsDropped = @"SKIN_WARN_ITEMS_DROPPED";
NSString *const LibretroSkinWarningDebugMissing = @"SKIN_WARN_DEBUG_MISSING";
NSString *const LibretroSkinWarningNoTouchScreen = @"SKIN_WARN_TOUCHSCREEN_UNSUPPORTED";

static NSString *const SkinRoleFull = @"full";
static NSString *const SkinRoleTop = @"top";
static NSString *const SkinRoleBottom = @"bottom";

/// Share of a screen's output frame a touch-screen item must cover for the
/// screen to count as the touch screen (Delta: the item contains it).
static const double SkinTouchCoverage = 0.5;

NSString *LibretroSkinOrientationName(LibretroSkinOrientation orientation) {
  return orientation == LibretroSkinOrientationLandscape ? @"landscape" : @"portrait";
}

BOOL LibretroSkinIdentifierIsValid(NSString *identifier) {
  if (![identifier isKindOfClass:[NSString class]] || identifier.length == 0 || identifier.length > 64) return NO;
  for (NSUInteger index = 0; index < identifier.length; index++) {
    unichar character = [identifier characterAtIndex:index];
    BOOL allowed = (character >= 'a' && character <= 'z') || (character >= '0' && character <= '9') || character == '-';
    if (!allowed) return NO;
  }
  return YES;
}

#pragma mark - JSON helpers

static NSDictionary *SkinDictionary(id object) {
  return [object isKindOfClass:[NSDictionary class]] ? object : nil;
}

static NSString *SkinNonEmptyString(id object) {
  if (![object isKindOfClass:[NSString class]]) return nil;
  NSString *string = object;
  NSString *trimmed = [string stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
  return trimmed.length > 0 ? string : nil;
}

/// JSON number, or a string holding one (Provenance accepts both).
static BOOL SkinNumber(id value, double *out) {
  double number = 0;
  if ([value isKindOfClass:[NSNumber class]]) {
    number = [(NSNumber *)value doubleValue];
  } else if ([value isKindOfClass:[NSString class]]) {
    const char *text = [(NSString *)value UTF8String];
    if (text == NULL || text[0] == '\0') return NO;
    char *end = NULL;
    number = strtod(text, &end);
    if (end == text || *end != '\0') return NO;
  } else {
    return NO;
  }
  if (!isfinite(number)) return NO;
  if (out != NULL) *out = number;
  return YES;
}

static BOOL SkinBool(id value, BOOL *out) {
  if ([value isKindOfClass:[NSNumber class]]) {
    *out = [(NSNumber *)value boolValue];
    return YES;
  }
  if ([value isKindOfClass:[NSString class]]) {
    NSString *text = [(NSString *)value lowercaseString];
    if ([text isEqualToString:@"true"] || [text isEqualToString:@"1"]) {
      *out = YES;
      return YES;
    }
    if ([text isEqualToString:@"false"] || [text isEqualToString:@"0"]) {
      *out = NO;
      return YES;
    }
  }
  return NO;
}

/// {x, y, width, height} with a positive size.
static BOOL SkinRect(id object, LibretroRect *out) {
  NSDictionary *dictionary = SkinDictionary(object);
  if (dictionary == nil) return NO;
  double x = 0, y = 0, width = 0, height = 0;
  if (!SkinNumber(dictionary[@"x"], &x) || !SkinNumber(dictionary[@"y"], &y)) return NO;
  if (!SkinNumber(dictionary[@"width"], &width) && !SkinNumber(dictionary[@"w"], &width)) return NO;
  if (!SkinNumber(dictionary[@"height"], &height) && !SkinNumber(dictionary[@"h"], &height)) return NO;
  if (width <= 0 || height <= 0) return NO;
  *out = LibretroRectMake(x, y, width, height);
  return YES;
}

/// {width, height} with a positive size.
static BOOL SkinSize(id object, LibretroSize *out) {
  NSDictionary *dictionary = SkinDictionary(object);
  if (dictionary == nil) return NO;
  double width = 0, height = 0;
  if (!SkinNumber(dictionary[@"width"], &width) || !SkinNumber(dictionary[@"height"], &height)) return NO;
  if (width <= 0 || height <= 0) return NO;
  out->w = width;
  out->h = height;
  return YES;
}

/// [w, h] from the console geometry sent by Dart.
static BOOL SkinPair(id object, LibretroSize *out) {
  if (![object isKindOfClass:[NSArray class]]) return NO;
  NSArray *values = object;
  if (values.count != 2) return NO;
  double width = 0, height = 0;
  if (!SkinNumber(values[0], &width) || !SkinNumber(values[1], &height) || width <= 0 || height <= 0) return NO;
  out->w = width;
  out->h = height;
  return YES;
}

/// [x, y, w, h] normalized region from the console geometry sent by Dart.
static BOOL SkinRegion(id object, LibretroRect *out) {
  if (![object isKindOfClass:[NSArray class]]) return NO;
  NSArray *values = object;
  if (values.count != 4) return NO;
  double numbers[4] = {0, 0, 0, 0};
  for (NSUInteger index = 0; index < 4; index++) {
    if (!SkinNumber(values[index], &numbers[index])) return NO;
  }
  if (numbers[2] <= 0 || numbers[3] <= 0) return NO;
  *out = LibretroRectMake(numbers[0], numbers[1], numbers[2], numbers[3]);
  return YES;
}

/// Edges listed in `object` replace those of `base`; missing ones are kept.
static LibretroInsets SkinEdges(id object, LibretroInsets base) {
  NSDictionary *dictionary = SkinDictionary(object);
  if (dictionary == nil) return base;
  double value = 0;
  if (SkinNumber(dictionary[@"top"], &value)) base.top = value;
  if (SkinNumber(dictionary[@"bottom"], &value)) base.bottom = value;
  if (SkinNumber(dictionary[@"left"], &value)) base.left = value;
  if (SkinNumber(dictionary[@"right"], &value)) base.right = value;
  return base;
}

#pragma mark - Geometry helpers

static double SkinArea(LibretroRect rect) {
  return rect.w > 0 && rect.h > 0 ? rect.w * rect.h : 0;
}

static double SkinOverlapArea(LibretroRect a, LibretroRect b) {
  double width = MIN(a.x + a.w, b.x + b.w) - MAX(a.x, b.x);
  double height = MIN(a.y + a.h, b.y + b.h) - MAX(a.y, b.y);
  return width > 0 && height > 0 ? width * height : 0;
}

static BOOL SkinRectInside(LibretroRect inner, LibretroRect outer, double tolerance) {
  return inner.x >= outer.x - tolerance && inner.y >= outer.y - tolerance &&
         inner.x + inner.w <= outer.x + outer.w + tolerance && inner.y + inner.h <= outer.y + outer.h + tolerance;
}

static BOOL SkinRectClose(LibretroRect a, LibretroRect b, double tolerance) {
  return fabs(a.x - b.x) <= tolerance && fabs(a.y - b.y) <= tolerance && fabs(a.w - b.w) <= tolerance &&
         fabs(a.h - b.h) <= tolerance;
}

/// `rect` (pixels of a picture of `size`) as a fraction of that picture.
static LibretroRect SkinNormalized(LibretroRect rect, LibretroSize size) {
  return LibretroRectMake(rect.x / size.w, rect.y / size.h, rect.w / size.w, rect.h / size.h);
}

/// Clamps a normalized rectangle to {0, 0, 1, 1}.
static LibretroRect SkinClampedToUnit(LibretroRect rect) {
  double left = MAX(rect.x, 0), top = MAX(rect.y, 0);
  double right = MIN(rect.x + rect.w, 1), bottom = MIN(rect.y + rect.h, 1);
  if (right <= left || bottom <= top) return LibretroRectMake(0, 0, 1, 1);
  return LibretroRectMake(left, top, right - left, bottom - top);
}

#pragma mark - Files

typedef NS_ENUM(NSInteger, SkinImageType) {
  SkinImageTypeNone = 0,
  SkinImageTypePNG,
  SkinImageTypeJPEG,
  SkinImageTypePDF,
};

/// Image type from the first bytes of the file (never from its name or key).
static SkinImageType SkinImageTypeAtPath(NSString *path) {
  NSData *data = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];
  if (data.length < 4) return SkinImageTypeNone;
  const uint8_t *bytes = data.bytes;
  static const uint8_t png[8] = {0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A};
  if (data.length >= 8 && memcmp(bytes, png, 8) == 0) return SkinImageTypePNG;
  if (bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF) return SkinImageTypeJPEG;
  // The PDF header may follow a few bytes of junk (PDF 1.7, 7.5.2).
  NSUInteger limit = MIN(data.length, (NSUInteger)1024);
  for (NSUInteger offset = 0; offset + 5 <= limit; offset++) {
    if (memcmp(bytes + offset, "%PDF-", 5) == 0) return SkinImageTypePDF;
  }
  return SkinImageTypeNone;
}

/// Absolute path of an image named in info.json, or nil when the name is
/// unsafe (absolute, "..", "\", __MACOSX), leaves the skin directory, is
/// missing or is not a PNG, JPEG or PDF.
static NSString *SkinImagePath(NSString *root, id name) {
  if (![name isKindOfClass:[NSString class]]) return nil;
  NSString *relative = name;
  if (relative.length == 0 || relative.length > 1024) return nil;
  if ([relative hasPrefix:@"/"] || [relative hasPrefix:@"~"] || [relative rangeOfString:@"\\"].location != NSNotFound) {
    return nil;
  }
  for (NSString *component in [relative componentsSeparatedByString:@"/"]) {
    if ([component isEqualToString:@".."] || [component isEqualToString:@"__MACOSX"]) return nil;
  }
  NSString *path = [root stringByAppendingPathComponent:relative].stringByStandardizingPath;
  NSString *resolvedRoot = root.stringByResolvingSymlinksInPath;
  NSString *resolvedPath = path.stringByResolvingSymlinksInPath;
  if (![resolvedPath hasPrefix:[resolvedRoot stringByAppendingString:@"/"]]) return nil;
  BOOL isDirectory = NO;
  if (![[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&isDirectory] || isDirectory) return nil;
  if (SkinImageTypeAtPath(path) == SkinImageTypeNone) return nil;
  return path;
}

#pragma mark - Model

@implementation LibretroSkinItem

- (instancetype)init {
  self = [super init];
  if (self) {
    _identifier = @"";
    _inputs = @[];
    _unsupportedInputs = @[];
  }
  return self;
}

- (id)copyWithZone:(NSZone *)zone {
  LibretroSkinItem *copy = [[[self class] allocWithZone:zone] init];
  copy.identifier = _identifier;
  copy.kind = _kind;
  copy.frame = _frame;
  copy.hitFrame = _hitFrame;
  copy.inputs = _inputs;
  copy.unsupportedInputs = _unsupportedInputs;
  copy.assetPath = _assetPath;
  copy.assetFrame = _assetFrame;
  copy.thumbstickAssetPath = _thumbstickAssetPath;
  copy.thumbstickSize = _thumbstickSize;
  copy.shape = _shape;
  copy.label = _label;
  copy.fillColor = _fillColor;
  copy.labelColor = _labelColor;
  copy.movable = _movable;
  return copy;
}

@end

@implementation LibretroSkinScreen

- (instancetype)init {
  self = [super init];
  if (self) {
    _source = LibretroRectMake(0, 0, 1, 1);
    _role = SkinRoleFull;
  }
  return self;
}

- (id)copyWithZone:(NSZone *)zone {
  LibretroSkinScreen *copy = [[[self class] allocWithZone:zone] init];
  copy.outputFrame = _outputFrame;
  copy.hasOutputFrame = _hasOutputFrame;
  copy.appPlacement = _appPlacement;
  copy.source = _source;
  copy.role = _role;
  copy.touchScreen = _touchScreen;
  return copy;
}

@end

@implementation LibretroSkinRepresentation

- (instancetype)init {
  self = [super init];
  if (self) {
    _device = @"iphone";
    _displayType = @"standard";
    _items = @[];
    _screens = @[];
  }
  return self;
}

@end

#pragma mark - Parser

/// One screen being parsed, with the inputFrame NeoStation may ignore.
@interface LibretroSkinScreenDraft : NSObject
@property(nonatomic, strong) LibretroSkinScreen *screen;
@property(nonatomic, assign) BOOL hasInputFrame;
@property(nonatomic, assign) LibretroRect inputFrame;
@property(nonatomic, assign) double touchCoverage;
@end

@implementation LibretroSkinScreenDraft

- (instancetype)init {
  self = [super init];
  if (self) {
    _screen = [LibretroSkinScreen new];
  }
  return self;
}

@end

/// State of one info.json parse: skin directory, console, its input map
/// and geometry, and the import report.
@interface LibretroSkinParser : NSObject
@property(nonatomic, copy) NSString *root;
@property(nonatomic, copy) NSString *console;
@property(nonatomic, strong) LibretroInputMap *inputMap;
@property(nonatomic, strong) NSMutableOrderedSet<NSString *> *warnings;
@property(nonatomic, assign) BOOL hasNominalSize;
@property(nonatomic, assign) LibretroSize nominalSize;
@property(nonatomic, assign) LibretroRect topRegion;
@property(nonatomic, assign) LibretroRect bottomRegion;
- (instancetype)initWithRoot:(NSString *)root
                    consoles:(NSArray<NSString *> *)consoles
                    geometry:(NSDictionary<NSString *, NSDictionary *> *)geometry;
/// nil when the representation has no usable mappingSize.
- (LibretroSkinRepresentation *)representationFromObject:(NSDictionary *)object
                                                   device:(NSString *)device
                                              displayType:(NSString *)displayType
                                              orientation:(LibretroSkinOrientation)orientation;
@end

@implementation LibretroSkinParser

- (instancetype)initWithRoot:(NSString *)root
                    consoles:(NSArray<NSString *> *)consoles
                    geometry:(NSDictionary<NSString *, NSDictionary *> *)geometry {
  self = [super init];
  if (self) {
    _root = [root copy];
    _console = [consoles.firstObject copy] ?: @"";
    _inputMap = [LibretroInputMap mapForConsole:_console];
    _warnings = [NSMutableOrderedSet orderedSet];
    BOOL threeDS = [_console isEqualToString:@"3ds"];
    _topRegion = LibretroRectMake(0, 0, 1, 0.5);
    _bottomRegion = threeDS ? LibretroRectMake(0.1, 0.5, 0.8, 0.5) : LibretroRectMake(0, 0.5, 1, 0.5);
    if (threeDS || [_console isEqualToString:@"nds"]) {
      _hasNominalSize = YES;
      _nominalSize = threeDS ? (LibretroSize){400, 480} : (LibretroSize){256, 384};
    }
    NSDictionary *entries = SkinDictionary(geometry);
    for (NSString *candidate in consoles) {
      NSDictionary *entry = SkinDictionary(entries[candidate]);
      if (entry == nil) continue;
      LibretroSize size = {0, 0};
      if (SkinPair(entry[@"size"], &size)) {
        _hasNominalSize = YES;
        _nominalSize = size;
      }
      NSDictionary *regions = SkinDictionary(entry[@"regions"]);
      LibretroRect region = {0, 0, 0, 0};
      if (SkinRegion(regions[SkinRoleTop], &region)) _topRegion = region;
      if (SkinRegion(regions[SkinRoleBottom], &region)) _bottomRegion = region;
      break;
    }
  }
  return self;
}

/// Canonical input of a button or D-pad direction; the touch screen only
/// comes from an {x, y} object.
- (NSString *)buttonInput:(NSString *)name {
  NSString *input = [self.inputMap canonicalInput:name];
  if (input.length == 0 || [input isEqualToString:@"touchScreen"]) return nil;
  return input;
}

- (NSString *)backgroundPathFromAssets:(id)object {
  NSDictionary *assets = SkinDictionary(object);
  if (assets == nil) return nil;
  NSString *chosen = nil;
  BOOL missing = NO;
  // Best first: the PDF scales to any size, then the largest bitmap.
  for (NSString *key in @[ @"resizable", @"large", @"medium", @"small" ]) {
    id name = assets[key];
    if (name == nil) continue;
    NSString *path = SkinImagePath(self.root, name);
    if (path == nil) {
      missing = YES;
    } else if (chosen == nil) {
      chosen = path;
    }
  }
  if (missing) [self.warnings addObject:LibretroSkinWarningAssetMissing];
  return chosen;
}

- (LibretroSkinItem *)itemFromObject:(id)entry
                               index:(NSUInteger)index
                              bounds:(LibretroRect)bounds
                               edges:(LibretroInsets)edges {
  NSDictionary *object = SkinDictionary(entry);
  LibretroRect frame = {0, 0, 0, 0};
  if (object == nil || !SkinRect(object[@"frame"], &frame) || [object[@"placement"] isEqual:@"app"] ||
      SkinOverlapArea(frame, bounds) <= 0) {
    [self.warnings addObject:LibretroSkinWarningItemsDropped];
    return nil;
  }
  LibretroSkinItem *item = [LibretroSkinItem new];
  item.identifier = [NSString stringWithFormat:@"item%lu", (unsigned long)index];
  item.frame = frame;
  NSMutableArray<NSString *> *unsupported = [NSMutableArray array];
  id inputs = object[@"inputs"];
  if ([inputs isKindOfClass:[NSString class]] || [inputs isKindOfClass:[NSArray class]]) {
    // Array of inputs pressed together, or a single string (Manic).
    NSArray *names = [inputs isKindOfClass:[NSString class]] ? @[ inputs ] : inputs;
    NSMutableArray<NSString *> *canonical = [NSMutableArray array];
    for (id name in names) {
      if (![name isKindOfClass:[NSString class]]) continue;
      NSString *input = [self buttonInput:name];
      if (input == nil) {
        [unsupported addObject:name];
      } else if (![canonical containsObject:input]) {
        [canonical addObject:input];
      }
    }
    item.kind = LibretroSkinItemKindButton;
    item.inputs = canonical;
  } else if ([inputs isKindOfClass:[NSDictionary class]]) {
    NSDictionary *directions = inputs;
    if (directions[@"up"] != nil || directions[@"down"] != nil || directions[@"left"] != nil ||
        directions[@"right"] != nil) {
      // D-pad or thumbstick: targets of up, down, left, right ("" = inert).
      NSMutableArray<NSString *> *targets = [NSMutableArray array];
      for (NSString *key in @[ @"up", @"down", @"left", @"right" ]) {
        id name = directions[key];
        NSString *input = [name isKindOfClass:[NSString class]] ? [self buttonInput:name] : nil;
        if (input == nil && [name isKindOfClass:[NSString class]]) [unsupported addObject:name];
        [targets addObject:input ?: @""];
      }
      item.inputs = targets;
      NSDictionary *thumbstick = SkinDictionary(object[@"thumbstick"]);
      id knobName = thumbstick[@"name"];
      LibretroSize knob = {0, 0};
      if ([knobName isKindOfClass:[NSString class]] && SkinNumber(thumbstick[@"width"], &knob.w) &&
          SkinNumber(thumbstick[@"height"], &knob.h)) {
        item.kind = LibretroSkinItemKindThumbstick;
        item.thumbstickSize = knob;
        item.thumbstickAssetPath = SkinImagePath(self.root, knobName);
        if (item.thumbstickAssetPath == nil) [self.warnings addObject:LibretroSkinWarningAssetMissing];
      } else {
        item.kind = LibretroSkinItemKindDPad;
      }
    } else if (directions[@"x"] != nil || directions[@"y"] != nil) {
      if (!self.inputMap.hasTouchScreen) {
        [self.warnings addObject:LibretroSkinWarningNoTouchScreen];
        return nil;
      }
      item.kind = LibretroSkinItemKindTouchScreen;
      item.inputs = @[ @"touchScreen" ];
    } else {
      [self.warnings addObject:LibretroSkinWarningItemsDropped];
      return nil;
    }
  } else {
    [self.warnings addObject:LibretroSkinWarningItemsDropped];
    return nil;
  }
  if (unsupported.count > 0) {
    item.unsupportedInputs = unsupported;
    [self.warnings addObject:LibretroSkinWarningUnknownInputs];
  }
  // The touch screen ignores extended edges (Delta).
  LibretroInsets itemEdges = SkinEdges(object[@"extendedEdges"], edges);
  item.hitFrame = item.kind == LibretroSkinItemKindTouchScreen ? frame : LibretroRectOutset(frame, itemEdges);
  item.assetFrame = frame;
  NSDictionary *asset = SkinDictionary(object[@"asset"]);
  if (asset != nil) {
    id assetName = asset[@"normal"] ?: asset[@"name"];
    if (assetName != nil) {
      item.assetPath = SkinImagePath(self.root, assetName);
      if (item.assetPath == nil) [self.warnings addObject:LibretroSkinWarningAssetMissing];
    }
    LibretroSize size = {0, 0};
    if (SkinNumber(asset[@"width"], &size.w) && SkinNumber(asset[@"height"], &size.h) && size.w > 0 && size.h > 0) {
      item.assetFrame =
          LibretroRectMake(frame.x + (frame.w - size.w) / 2, frame.y + (frame.h - size.h) / 2, size.w, size.h);
    }
  }
  item.shape = LibretroSkinItemShapeNone;
  // Only controls drawn with their own image can move; painted ones stay.
  item.movable = item.assetPath != nil && item.kind != LibretroSkinItemKindTouchScreen;
  return item;
}

- (NSArray<LibretroSkinItem *> *)itemsFromObject:(id)object mapping:(LibretroSize)mapping edges:(LibretroInsets)edges {
  NSMutableArray<LibretroSkinItem *> *items = [NSMutableArray array];
  if (![object isKindOfClass:[NSArray class]]) return items;
  NSArray *entries = object;
  LibretroRect bounds = LibretroRectMake(0, 0, mapping.w, mapping.h);
  for (NSUInteger index = 0; index < entries.count; index++) {
    LibretroSkinItem *item = [self itemFromObject:entries[index] index:index bounds:bounds edges:edges];
    if (item != nil) [items addObject:item];
  }
  return items;
}

- (NSArray<LibretroSkinScreen *> *)screensFromObject:(NSDictionary *)object items:(NSArray<LibretroSkinItem *> *)items {
  NSMutableArray<LibretroSkinScreenDraft *> *drafts = [NSMutableArray array];
  LibretroRect gameScreenFrame = {0, 0, 0, 0};
  if (SkinRect(object[@"gameScreenFrame"], &gameScreenFrame)) {
    // Legacy key: wins over `screens` (Delta), whole picture.
    LibretroSkinScreenDraft *draft = [LibretroSkinScreenDraft new];
    draft.screen.outputFrame = gameScreenFrame;
    draft.screen.hasOutputFrame = YES;
    [drafts addObject:draft];
  } else if ([object[@"screens"] isKindOfClass:[NSArray class]]) {
    NSArray *entries = object[@"screens"];
    for (id entry in entries) {
      NSDictionary *screenObject = SkinDictionary(entry);
      if (screenObject == nil) continue;
      NSArray *filters = screenObject[@"filters"];
      if ([filters isKindOfClass:[NSArray class]] && filters.count > 0) {
        [self.warnings addObject:LibretroSkinWarningFiltersIgnored];
      }
      LibretroSkinScreenDraft *draft = [LibretroSkinScreenDraft new];
      LibretroRect frame = {0, 0, 0, 0};
      if (SkinRect(screenObject[@"outputFrame"], &frame)) {
        draft.screen.outputFrame = frame;
        draft.screen.hasOutputFrame = YES;
        draft.screen.appPlacement = [screenObject[@"placement"] isEqual:@"app"];
      }
      if (SkinRect(screenObject[@"inputFrame"], &frame)) {
        draft.hasInputFrame = YES;
        draft.inputFrame = frame;
      }
      [drafts addObject:draft];
    }
  }

  for (LibretroSkinScreenDraft *draft in drafts) {
    LibretroSkinScreen *screen = draft.screen;
    if (!screen.hasOutputFrame || screen.appPlacement) continue;
    double area = SkinArea(screen.outputFrame);
    for (LibretroSkinItem *item in items) {
      if (item.kind != LibretroSkinItemKindTouchScreen || area <= 0) continue;
      draft.touchCoverage = MAX(draft.touchCoverage, SkinOverlapArea(item.frame, screen.outputFrame) / area);
    }
  }

  if ([self.console isEqualToString:@"3ds"]) {
    [self assignThreeDSScreens:drafts];
  } else if ([self.console isEqualToString:@"nds"]) {
    [self assignDSScreens:drafts];
  } else {
    [self assignSingleScreens:drafts];
  }

  BOOL touchConsole = self.inputMap.hasTouchScreen;
  NSMutableArray<LibretroSkinScreen *> *screens = [NSMutableArray array];
  for (LibretroSkinScreenDraft *draft in drafts) {
    LibretroSkinScreen *screen = draft.screen;
    screen.touchScreen = touchConsole && ([screen.role isEqualToString:SkinRoleBottom] ||
                                          draft.touchCoverage >= SkinTouchCoverage);
    [screens addObject:screen];
  }
  if (screens.count == 0 && touchConsole) {
    // No screen declared: the whole picture, touchable, in the game area.
    LibretroSkinScreen *screen = [LibretroSkinScreen new];
    screen.touchScreen = YES;
    [screens addObject:screen];
  }
  return screens;
}

/// DS: the Delta inputFrames (256x384, top above bottom) are reliable.
- (void)assignDSScreens:(NSArray<LibretroSkinScreenDraft *> *)drafts {
  LibretroSize size = self.nominalSize;
  LibretroRect picture = LibretroRectMake(0, 0, size.w, size.h);
  for (LibretroSkinScreenDraft *draft in drafts) {
    LibretroSkinScreen *screen = draft.screen;
    screen.source = LibretroRectMake(0, 0, 1, 1);
    screen.role = SkinRoleFull;
    if (!draft.hasInputFrame) continue;
    if (!SkinRectInside(draft.inputFrame, picture, 0.5)) {
      [self.warnings addObject:LibretroSkinWarningInputFrameIgnored];
      continue;
    }
    LibretroRect source = SkinClampedToUnit(SkinNormalized(draft.inputFrame, size));
    screen.source = source;
    if (SkinRectInside(source, self.topRegion, 0.01)) {
      screen.role = SkinRoleTop;
    } else if (SkinRectInside(source, self.bottomRegion, 0.01)) {
      screen.role = SkinRoleBottom;
    }
  }
}

/// 3DS: inputFrames are ignored (inconsistent in Manic skins); the screen
/// covered by the touch-screen item shows the bottom screen, the others the
/// top screen.
- (void)assignThreeDSScreens:(NSArray<LibretroSkinScreenDraft *> *)drafts {
  NSUInteger bottomIndex = NSNotFound;
  double best = 0;
  for (NSUInteger index = 0; index < drafts.count; index++) {
    double coverage = drafts[index].touchCoverage;
    if (coverage >= SkinTouchCoverage && coverage > best) {
      best = coverage;
      bottomIndex = index;
    }
  }
  if (bottomIndex == NSNotFound && drafts.count >= 2) bottomIndex = 1;
  LibretroSize size = self.nominalSize;
  for (NSUInteger index = 0; index < drafts.count; index++) {
    LibretroSkinScreenDraft *draft = drafts[index];
    LibretroSkinScreen *screen = draft.screen;
    if (index == bottomIndex) {
      screen.role = SkinRoleBottom;
      screen.source = self.bottomRegion;
    } else if (drafts.count == 1) {
      screen.role = SkinRoleFull;
      screen.source = LibretroRectMake(0, 0, 1, 1);
    } else {
      screen.role = SkinRoleTop;
      screen.source = self.topRegion;
    }
    if (draft.hasInputFrame) {
      LibretroRect given = SkinNormalized(draft.inputFrame, size);
      double tolerance = 1.5 / MAX(size.w, size.h);
      if (!SkinRectClose(given, screen.source, tolerance)) {
        [self.warnings addObject:LibretroSkinWarningInputFrameIgnored];
      }
    }
  }
}

/// Other consoles: an inputFrame is used only when it lies inside the
/// console's nominal picture (PSP skins carry impossible values).
- (void)assignSingleScreens:(NSArray<LibretroSkinScreenDraft *> *)drafts {
  LibretroSize size = self.nominalSize;
  LibretroRect picture = LibretroRectMake(0, 0, size.w, size.h);
  for (LibretroSkinScreenDraft *draft in drafts) {
    LibretroSkinScreen *screen = draft.screen;
    screen.role = SkinRoleFull;
    screen.source = LibretroRectMake(0, 0, 1, 1);
    if (!draft.hasInputFrame) continue;
    if (!self.hasNominalSize || !SkinRectInside(draft.inputFrame, picture, 0.5)) {
      [self.warnings addObject:LibretroSkinWarningInputFrameIgnored];
      continue;
    }
    screen.source = SkinClampedToUnit(SkinNormalized(draft.inputFrame, size));
  }
}

- (LibretroSkinRepresentation *)representationFromObject:(NSDictionary *)object
                                                   device:(NSString *)device
                                              displayType:(NSString *)displayType
                                              orientation:(LibretroSkinOrientation)orientation {
  LibretroSize mapping = {0, 0};
  if (!SkinSize(object[@"mappingSize"], &mapping)) return nil;
  LibretroSkinRepresentation *representation = [LibretroSkinRepresentation new];
  representation.orientation = orientation;
  representation.device = device;
  representation.displayType = displayType;
  representation.mappingSize = mapping;
  LibretroInsets noEdges = {0, 0, 0, 0};
  representation.extendedEdges = SkinEdges(object[@"extendedEdges"], noEdges);
  BOOL translucent = NO;
  if (SkinBool(object[@"translucent"], &translucent)) representation.translucent = translucent;
  representation.backgroundPath = [self backgroundPathFromAssets:object[@"assets"]];
  NSArray<LibretroSkinItem *> *items = [self itemsFromObject:object[@"items"]
                                                     mapping:mapping
                                                       edges:representation.extendedEdges];
  representation.items = items;
  representation.screens = [self screensFromObject:object items:items];
  return representation;
}

@end

#pragma mark - Skin

@implementation LibretroSkin

- (instancetype)init {
  self = [super init];
  if (self) {
    _installedIdentifier = @"";
    _identifier = @"";
    _name = @"";
    _consoles = @[];
    _gameTypeIdentifier = @"";
    _representations = @[];
    _warnings = @[];
  }
  return self;
}

+ (instancetype)skinWithDirectory:(NSString *)directory
                  consoleGeometry:(NSDictionary<NSString *, NSDictionary *> *)consoleGeometry
                        errorCode:(NSString **)errorCode {
  if (errorCode != NULL) *errorCode = nil;
  NSString *root = directory.stringByStandardizingPath;
  NSString *infoPath = [root stringByAppendingPathComponent:@"info.json"];
  BOOL isDirectory = NO;
  if (root.length == 0 || ![[NSFileManager defaultManager] fileExistsAtPath:infoPath isDirectory:&isDirectory] ||
      isDirectory) {
    if (errorCode != NULL) *errorCode = LibretroSkinErrorInfoMissing;
    return nil;
  }
  NSData *data = [NSData dataWithContentsOfFile:infoPath];
  if (data.length >= 3) {
    const uint8_t *bytes = data.bytes;
    if (bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF) {
      data = [data subdataWithRange:NSMakeRange(3, data.length - 3)];
    }
  }
  id json = data.length > 0 ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
  NSString *installedIdentifier = root.lastPathComponent;
  // The directory name keys selections and settings: [a-z0-9-] only, and
  // never the default skin's identifier.
  if (![json isKindOfClass:[NSDictionary class]] || !LibretroSkinIdentifierIsValid(installedIdentifier) ||
      [installedIdentifier isEqualToString:LibretroDefaultSkinIdentifier]) {
    if (errorCode != NULL) *errorCode = LibretroSkinErrorInfoInvalid;
    return nil;
  }
  NSDictionary *info = json;
  NSString *name = SkinNonEmptyString(info[@"name"]);
  NSString *identifier = SkinNonEmptyString(info[@"identifier"]);
  NSString *gameTypeIdentifier = SkinNonEmptyString(info[@"gameTypeIdentifier"]);
  NSDictionary *representations = SkinDictionary(info[@"representations"]);
  if (name == nil || identifier == nil || gameTypeIdentifier == nil || representations == nil) {
    if (errorCode != NULL) *errorCode = LibretroSkinErrorFieldMissing;
    return nil;
  }
  NSArray<NSString *> *consoles = [self consolesForGameTypeIdentifier:gameTypeIdentifier];
  if (consoles.count == 0) {
    if (errorCode != NULL) *errorCode = LibretroSkinErrorConsoleUnsupported;
    return nil;
  }

  LibretroSkinParser *parser = [[LibretroSkinParser alloc] initWithRoot:root
                                                                consoles:consoles
                                                                geometry:consoleGeometry];
  BOOL debug = NO;
  if (!SkinBool(info[@"debug"], &debug)) [parser.warnings addObject:LibretroSkinWarningDebugMissing];

  NSMutableArray<LibretroSkinRepresentation *> *parsed = [NSMutableArray array];
  BOOL phoneOrTablet = NO;
  for (NSString *device in @[ @"iphone", @"ipad" ]) {
    NSDictionary *displayTypes = SkinDictionary(representations[device]);
    if (displayTypes == nil) continue;
    phoneOrTablet = YES;
    // iPad: only ipad.standard is ever chosen (DeltaCore).
    NSArray<NSString *> *types =
        [device isEqualToString:@"ipad"] ? @[ @"standard" ] : @[ @"standard", @"edgeToEdge" ];
    for (NSString *displayType in types) {
      NSDictionary *orientations = SkinDictionary(displayTypes[displayType]);
      // A device without display-type level means "standard".
      if (orientations == nil && [displayType isEqualToString:@"standard"] && displayTypes[@"standard"] == nil &&
          (displayTypes[@"portrait"] != nil || displayTypes[@"landscape"] != nil)) {
        orientations = displayTypes;
      }
      if (orientations == nil) continue;
      for (NSNumber *value in @[ @(LibretroSkinOrientationPortrait), @(LibretroSkinOrientationLandscape) ]) {
        LibretroSkinOrientation orientation = (LibretroSkinOrientation)value.integerValue;
        NSDictionary *object = SkinDictionary(orientations[LibretroSkinOrientationName(orientation)]);
        if (object == nil) continue;
        LibretroSkinRepresentation *representation = [parser representationFromObject:object
                                                                                device:device
                                                                           displayType:displayType
                                                                           orientation:orientation];
        if (representation != nil) [parsed addObject:representation];
      }
    }
  }
  if (parsed.count == 0) {
    BOOL otherDevice = NO;
    for (id key in representations) {
      if ([representations[key] isKindOfClass:[NSDictionary class]]) otherDevice = YES;
    }
    if (errorCode != NULL) {
      *errorCode = !phoneOrTablet && otherDevice ? LibretroSkinErrorNoPhoneOrTablet : LibretroSkinErrorNoRepresentation;
    }
    return nil;
  }

  LibretroSkin *skin = [[self alloc] init];
  skin.installedIdentifier = installedIdentifier;
  skin.identifier = identifier;
  skin.name = name;
  skin.author = [self authorForInfo:info root:root];
  skin.consoles = consoles;
  skin.gameTypeIdentifier = gameTypeIdentifier;
  skin.directory = root;
  skin.debug = debug;
  skin.representations = parsed;
  for (NSNumber *iPad in @[ @NO, @YES ]) {
    if ([skin orientationsForIPad:iPad.boolValue].count == 1) {
      [parser.warnings addObject:LibretroSkinWarningOrientationMissing];
    }
  }
  skin.warnings = parser.warnings.array;
  return skin;
}

/// Delta has no author field: a Provenance-style `author`, else the one
/// NeoStation recorded at import (neostation-skin.json).
+ (NSString *)authorForInfo:(NSDictionary *)info root:(NSString *)root {
  NSString *author = SkinNonEmptyString(info[@"author"]);
  if (author != nil) return author;
  NSData *data = [NSData dataWithContentsOfFile:[root stringByAppendingPathComponent:@"neostation-skin.json"]];
  id metadata = data.length > 0 ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
  return SkinNonEmptyString(SkinDictionary(metadata)[@"author"]);
}

+ (NSArray<NSString *> *)consolesForGameTypeIdentifier:(NSString *)gameTypeIdentifier {
  if (![gameTypeIdentifier isKindOfClass:[NSString class]]) return @[];
  NSString *key = [gameTypeIdentifier componentsSeparatedByString:@"."].lastObject.lowercaseString ?: @"";
  for (NSString *separator in @[ @"-", @"_", @" " ]) {
    key = [key stringByReplacingOccurrencesOfString:separator withString:@""];
  }
  static NSDictionary<NSString *, NSArray<NSString *> *> *aliases;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    NSArray<NSString *> *gameBoy = @[ @"gb", @"gbc" ];
    NSArray<NSString *> *megaDrive = @[ @"md", @"mcd", @"32x" ];
    aliases = @{
      @"nds" : @[ @"nds" ],
      @"ds" : @[ @"nds" ],
      @"gbc" : gameBoy,
      @"gb" : gameBoy,
      @"gba" : @[ @"gba" ],
      @"nes" : @[ @"nes" ],
      @"snes" : @[ @"snes" ],
      @"n64" : @[ @"n64" ],
      @"md" : megaDrive,
      @"genesis" : megaDrive,
      @"megadrive" : megaDrive,
      @"mcd" : megaDrive,
      @"32x" : megaDrive,
      @"ms" : @[ @"sms" ],
      @"sms" : @[ @"sms" ],
      @"mastersystem" : @[ @"sms" ],
      @"gg" : @[ @"gg" ],
      @"sg1000" : @[ @"sg1000" ],
      @"psx" : @[ @"psx" ],
      @"ps1" : @[ @"psx" ],
      @"psp" : @[ @"psp" ],
      @"3ds" : @[ @"3ds" ],
      @"threeds" : @[ @"3ds" ],
      @"arcade" : @[ @"arcade" ],
      @"fbneo" : @[ @"arcade" ],
      @"mame" : @[ @"arcade" ],
    };
  });
  return aliases[key] ?: @[];
}

- (LibretroSkinRepresentation *)representationForOrientation:(LibretroSkinOrientation)orientation
                                                         iPad:(BOOL)iPad
                                                   edgeToEdge:(BOOL)edgeToEdge {
  NSArray<NSArray<NSString *> *> *chain;
  if (iPad) {
    chain = @[ @[ @"ipad", @"standard" ], @[ @"iphone", @"edgeToEdge" ], @[ @"iphone", @"standard" ] ];
  } else if (edgeToEdge) {
    chain = @[ @[ @"iphone", @"edgeToEdge" ], @[ @"iphone", @"standard" ] ];
  } else {
    chain = @[ @[ @"iphone", @"standard" ], @[ @"iphone", @"edgeToEdge" ] ];
  }
  for (NSArray<NSString *> *step in chain) {
    for (LibretroSkinRepresentation *representation in self.representations) {
      if (representation.orientation == orientation && [representation.device isEqualToString:step[0]] &&
          [representation.displayType isEqualToString:step[1]]) {
        return representation;
      }
    }
  }
  return nil;
}

- (NSArray<NSString *> *)orientationsForIPad:(BOOL)iPad {
  NSMutableArray<NSString *> *names = [NSMutableArray array];
  BOOL builtIn = [self.installedIdentifier isEqualToString:LibretroDefaultSkinIdentifier] &&
                 self.representations.count == 0;
  for (NSNumber *value in @[ @(LibretroSkinOrientationPortrait), @(LibretroSkinOrientationLandscape) ]) {
    LibretroSkinOrientation orientation = (LibretroSkinOrientation)value.integerValue;
    // The default skin is generated for any orientation.
    if (builtIn || [self representationForOrientation:orientation iPad:iPad edgeToEdge:YES] != nil) {
      [names addObject:LibretroSkinOrientationName(orientation)];
    }
  }
  return names;
}

- (NSDictionary<NSString *, id> *)summary {
  NSMutableDictionary<NSString *, id> *summary = [@{
    @"identifier" : self.identifier,
    @"installedIdentifier" : self.installedIdentifier,
    @"name" : self.name,
    @"consoles" : self.consoles,
    @"gameTypeIdentifier" : self.gameTypeIdentifier,
    @"orientations" : @{@"iphone" : [self orientationsForIPad:NO], @"ipad" : [self orientationsForIPad:YES]},
    @"warnings" : self.warnings,
    @"debug" : @(self.debug),
  } mutableCopy];
  if (self.author.length > 0) summary[@"author"] = self.author;
  return summary;
}

@end
