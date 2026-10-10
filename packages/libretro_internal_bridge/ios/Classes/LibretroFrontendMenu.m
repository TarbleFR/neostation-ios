#import "LibretroFrontendMenu.h"

#include <math.h>

#import "LibretroChromeLayout.h"
#import "LibretroDefaultSkins.h"
#import "LibretroGeometry.h"
#import "LibretroShaderLibrary.h"

/// "Commandes › Opacité": range and step of the slider, and the values used
/// while nothing is stored, as LibretroSession draws the controls:
/// NeoStation's default skins 75 %, imported skins 70 % (Delta's default).
static const float kOpacityMinimum = 0.15f;
static const float kOpacityMaximum = 1.0f;
static const float kOpacityStep = 0.05f;
static const float kOpacityDefaultSkin = 0.75f;
static const float kOpacityImportedSkin = 0.7f;

/// Every controls.* key: gamepad, touch remaps, layouts and opacity.
static NSString *const kControlsPrefix = @"controls.";

/// Longest side of a skin preview, in points.
static const CGFloat kPreviewLength = 100.0;

typedef NSArray<LibretroMenuSection *> * (^LibretroFrontendSections)(LibretroFrontendMenu *menu,
                                                                     id<LibretroFrontendMenuHost> host);
typedef void (^LibretroPreviewDelivery)(UIImage *_Nullable image);

#pragma mark - Helpers

static LibretroSettingScope MaxScope(LibretroSettingScope first, LibretroSettingScope second) {
  return first > second ? first : second;
}

static NSString *SkinKey(LibretroSkinOrientation orientation) {
  return orientation == LibretroSkinOrientationPortrait ? LibretroSettingSkinPortrait : LibretroSettingSkinLandscape;
}

static NSString *ArrangementKey(LibretroSkinOrientation orientation) {
  return orientation == LibretroSkinOrientationPortrait ? LibretroSettingArrangementPortrait
                                                        : LibretroSettingArrangementLandscape;
}

static void AppendText(NSMutableArray<NSString *> *parts, NSString *text) {
  if ([text isKindOfClass:[NSString class]] && text.length > 0) [parts addObject:text];
}

/// Non-empty texts separated by a blank line (section footers); nil when
/// every part is empty.
static NSString *JoinedText(NSString *first, NSString *second, NSString *third, NSString *fourth) {
  NSMutableArray<NSString *> *parts = [NSMutableArray arrayWithCapacity:4];
  AppendText(parts, first);
  AppendText(parts, second);
  AppendText(parts, third);
  AppendText(parts, fourth);
  return parts.count > 0 ? [parts componentsJoinedByString:@"\n\n"] : nil;
}

/// Product glyphs VoiceOver cannot read as a name: the PlayStation symbols
/// and the arrows of the N64 C buttons.
static BOOL GlyphNeedsSpokenLabel(NSString *glyph) {
  static NSCharacterSet *symbols;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    // Circle, cross, triangle, square, up, down, left, right.
    symbols = [NSCharacterSet characterSetWithCharactersInString:@"○✕△□▲▼◀▶"];
  });
  return [glyph isKindOfClass:[NSString class]] && glyph.length > 0 &&
         [glyph rangeOfCharacterFromSet:symbols].location != NSNotFound;
}

/// Shader parameter values with four decimals (steps are at least 0.01), so
/// the JSON file holds 0.02 rather than the float 0.0199999996.
static NSDictionary<NSString *, NSNumber *> *RoundedParameters(NSDictionary<NSString *, NSNumber *> *values) {
  NSMutableDictionary<NSString *, NSNumber *> *rounded = [NSMutableDictionary dictionaryWithCapacity:values.count];
  for (NSString *identifier in values) {
    rounded[identifier] = @(round(values[identifier].doubleValue * 10000.0) / 10000.0);
  }
  return rounded;
}

/// Size of a skin preview with the proportions of the game view
/// (`reference`): 100 points high in portrait, 100 points wide in landscape.
static CGSize PreviewSize(LibretroSize reference, LibretroSkinOrientation orientation) {
  BOOL valid = isfinite(reference.w) && isfinite(reference.h) && reference.w > 0 && reference.h > 0;
  if (orientation == LibretroSkinOrientationPortrait) {
    double width = valid ? kPreviewLength * reference.w / reference.h : 46.0;
    return CGSizeMake(round(fmin(fmax(width, 30.0), kPreviewLength)), kPreviewLength);
  }
  double height = valid ? kPreviewLength * reference.h / reference.w : 46.0;
  return CGSizeMake(kPreviewLength, round(fmin(fmax(height, 30.0), kPreviewLength)));
}

#pragma mark - Page state

/// What belongs to one page while it exists: the scope it writes to and the
/// shader measurement shown on the Shaders page. Main thread only.
@interface LibretroFrontendPageState : NSObject
/// YES: changes are saved for this game only; NO: for every game of the console.
@property(nonatomic, assign) BOOL gameScope;
/// A shader compilation requested from this page has not answered yet.
@property(nonatomic, assign) BOOL busy;
/// A slider of this page is being dragged: no table reload until it ends.
@property(nonatomic, assign) BOOL dragging;
@property(nonatomic, assign) BOOL measuring;
@property(nonatomic, assign) double gpuMilliseconds;
/// Increases at every measurement or shader change; late answers are dropped.
@property(nonatomic, assign) NSUInteger measurement;
/// Last opacity written while the slider moves.
@property(nonatomic, assign) double writtenOpacity;
@end

@implementation LibretroFrontendPageState
@end

#pragma mark - Menu

@implementation LibretroFrontendMenu {
  __weak id<LibretroFrontendMenuHost> _host;
  /// Skin previews rendered during this menu's life (key: skin,
  /// orientation, view size, image size and DS / 3DS screen places).
  NSMutableDictionary<NSString *, UIImage *> *_previews;
  /// Rows waiting for a preview that is being rendered.
  NSMutableDictionary<NSString *, NSMutableArray<LibretroPreviewDelivery> *> *_previewWaiters;
}

- (instancetype)initWithHost:(id<LibretroFrontendMenuHost>)host {
  self = [super init];
  if (self) {
    _host = host;
    _previews = [NSMutableDictionary dictionary];
    _previewWaiters = [NSMutableDictionary dictionary];
  }
  return self;
}

#pragma mark Text

/// Every label comes from the host (uiText sent by Dart).
- (NSString *)text:(NSString *)key {
  id<LibretroFrontendMenuHost> host = _host;
  return host != nil ? [host text:key] : key;
}

- (NSString *)text:(NSString *)key replacing:(NSString *)placeholder with:(NSString *)value {
  return [[self text:key] stringByReplacingOccurrencesOfString:placeholder withString:value ?: @""];
}

/// Number formatter in NeoStation's language (never the device language).
- (NSNumberFormatter *)formatterWithStyle:(NSNumberFormatterStyle)style
                    minimumFractionDigits:(NSUInteger)minimum
                    maximumFractionDigits:(NSUInteger)maximum {
  NSNumberFormatter *formatter = [NSNumberFormatter new];
  NSString *identifier = _host.uiLocale;
  formatter.locale = [NSLocale localeWithLocaleIdentifier:identifier.length > 0 ? identifier : @"en"];
  formatter.numberStyle = style;
  formatter.minimumFractionDigits = minimum;
  formatter.maximumFractionDigits = maximum;
  return formatter;
}

- (NSString *)consoleScopeTitle {
  return [self text:@"scopeConsole" replacing:@"{console}" with:_host.consoleName];
}

- (NSString *)scopeTitleForState:(LibretroFrontendPageState *)state {
  if (state.gameScope && [self currentGameKey] != nil) return [self text:@"scopeGame"];
  return [self consoleScopeTitle];
}

/// "Set for this game", "Set for <console>" or "NeoStation default".
- (NSString *)sourceTextForScope:(LibretroSettingScope)scope {
  switch (scope) {
    case LibretroSettingScopeGame:
      return [self text:@"valueFromGame"];
    case LibretroSettingScopeConsole:
      return [self text:@"valueFromConsole" replacing:@"{console}" with:_host.consoleName];
    case LibretroSettingScopeDefault:
      break;
  }
  return [self text:@"valueDefault"];
}

#pragma mark Input labels

/// Visible label of a logical input: the console's glyph ("A", "○",
/// "C▲"), else its translated name ("Up", "Quick save"...).
- (NSString *)labelForInput:(NSString *)input map:(LibretroInputMap *)map {
  NSString *glyph = [map glyphForInput:input];
  if (glyph.length > 0) return glyph;
  NSString *key = [map labelKeyForInput:input];
  return key != nil ? [self text:key] : input;
}

/// VoiceOver label when the visible one is a symbol; nil when the visible
/// label already reads well.
- (NSString *)spokenLabelForInput:(NSString *)input map:(LibretroInputMap *)map {
  NSString *glyph = [map glyphForInput:input];
  if (!GlyphNeedsSpokenLabel(glyph)) return nil;
  NSString *key = [map labelKeyForInput:input];
  if (key != nil) return [self text:key];
  // N64 C buttons: "C" followed by the translated direction.
  NSString *spoken = glyph;
  spoken = [spoken stringByReplacingOccurrencesOfString:@"▲"
                                             withString:[@" " stringByAppendingString:[self text:@"inputUp"]]];
  spoken = [spoken stringByReplacingOccurrencesOfString:@"▼"
                                             withString:[@" " stringByAppendingString:[self text:@"inputDown"]]];
  spoken = [spoken stringByReplacingOccurrencesOfString:@"◀"
                                             withString:[@" " stringByAppendingString:[self text:@"inputLeft"]]];
  spoken = [spoken stringByReplacingOccurrencesOfString:@"▶"
                                             withString:[@" " stringByAppendingString:[self text:@"inputRight"]]];
  return spoken;
}

- (NSString *)labelForInputs:(NSArray<NSString *> *)inputs map:(LibretroInputMap *)map {
  NSMutableArray<NSString *> *labels = [NSMutableArray arrayWithCapacity:inputs.count];
  for (NSString *input in inputs) [labels addObject:[self labelForInput:input map:map]];
  return [labels componentsJoinedByString:@" + "];
}

- (NSString *)spokenLabelForInputs:(NSArray<NSString *> *)inputs map:(LibretroInputMap *)map {
  BOOL needed = NO;
  NSMutableArray<NSString *> *labels = [NSMutableArray arrayWithCapacity:inputs.count];
  for (NSString *input in inputs) {
    NSString *spoken = [self spokenLabelForInput:input map:map];
    if (spoken != nil) needed = YES;
    [labels addObject:spoken ?: [self labelForInput:input map:map]];
  }
  return needed ? [labels componentsJoinedByString:@" + "] : nil;
}

/// Translated name of a physical controller element.
- (NSString *)titleForGamepadElement:(NSString *)element {
  if ([element isEqualToString:@"buttonA"]) return [self text:@"padButtonNamed" replacing:@"{name}" with:@"A"];
  if ([element isEqualToString:@"buttonB"]) return [self text:@"padButtonNamed" replacing:@"{name}" with:@"B"];
  if ([element isEqualToString:@"buttonX"]) return [self text:@"padButtonNamed" replacing:@"{name}" with:@"X"];
  if ([element isEqualToString:@"buttonY"]) return [self text:@"padButtonNamed" replacing:@"{name}" with:@"Y"];
  if ([element isEqualToString:@"leftShoulder"]) return [self text:@"padLeftShoulder"];
  if ([element isEqualToString:@"rightShoulder"]) return [self text:@"padRightShoulder"];
  if ([element isEqualToString:@"leftTrigger"]) return [self text:@"padLeftTrigger"];
  if ([element isEqualToString:@"rightTrigger"]) return [self text:@"padRightTrigger"];
  if ([element isEqualToString:@"leftThumbstickButton"]) return [self text:@"padLeftStickButton"];
  if ([element isEqualToString:@"rightThumbstickButton"]) return [self text:@"padRightStickButton"];
  if ([element isEqualToString:@"buttonOptions"]) return [self text:@"padOptionsButton"];
  if ([element isEqualToString:@"buttonMenu"]) return [self text:@"padMenuButton"];
  if ([element isEqualToString:@"dpadUp"]) return [self text:@"padDpadUp"];
  if ([element isEqualToString:@"dpadDown"]) return [self text:@"padDpadDown"];
  if ([element isEqualToString:@"dpadLeft"]) return [self text:@"padDpadLeft"];
  if ([element isEqualToString:@"dpadRight"]) return [self text:@"padDpadRight"];
  return element;
}

#pragma mark Value labels

- (NSString *)nameForSkin:(LibretroSkin *)skin {
  if (skin == nil) return nil;
  if ([skin.installedIdentifier isEqualToString:LibretroDefaultSkinIdentifier]) return [self text:@"skinDefaultName"];
  return skin.name.length > 0 ? skin.name : skin.installedIdentifier;
}

- (NSString *)labelForFormat:(LibretroScreenFormat)format {
  switch (format) {
    case LibretroScreenFormat4x3:
      return @"4:3";
    case LibretroScreenFormat16x9:
      return @"16:9";
    case LibretroScreenFormat16x10:
      return @"16:10";
    case LibretroScreenFormatStretch:
      return [self text:@"formatStretch"];
    case LibretroScreenFormatOriginal:
      break;
  }
  return [self text:@"formatOriginal"];
}

/// The existing DS / 3DS layout labels name NeoStation's arrangements.
- (NSString *)labelForArrangement:(NSString *)arrangement {
  if ([arrangement isEqualToString:LibretroArrangementSideBySide]) return [self text:@"layoutLeftRight"];
  if ([arrangement isEqualToString:LibretroArrangementLargeTop]) return [self text:@"layoutHybridTop"];
  if ([arrangement isEqualToString:LibretroArrangementTopOnly]) return [self text:@"layoutTopOnly"];
  if ([arrangement isEqualToString:LibretroArrangementBottomOnly]) return [self text:@"layoutBottomOnly"];
  return [self text:@"layoutTopBottom"];
}

- (NSString *)labelForOrientation:(LibretroSkinOrientation)orientation {
  return orientation == LibretroSkinOrientationPortrait ? [self text:@"orientationPortrait"]
                                                        : [self text:@"orientationLandscape"];
}

/// "Core ratio 1,33" in NeoStation's language; nil when the core gave none.
- (NSString *)coreRatioText {
  double ratio = _host.coreAspectRatio;
  if (!(ratio > 0.0) || !isfinite(ratio)) return nil;
  NSNumberFormatter *formatter = [self formatterWithStyle:NSNumberFormatterDecimalStyle
                                    minimumFractionDigits:2
                                    maximumFractionDigits:2];
  NSString *formatted = [formatter stringFromNumber:@(ratio)];
  return formatted != nil ? [self text:@"formatCoreRatio" replacing:@"{ratio}" with:formatted] : nil;
}

#pragma mark Settings

/// The session's game key, nil when it has none (console scope only).
- (NSString *)currentGameKey {
  NSString *game = _host.gameKey;
  return game.length > 0 ? game : nil;
}

- (NSString *)gameKeyForState:(LibretroFrontendPageState *)state {
  return state.gameScope ? [self currentGameKey] : nil;
}

/// Resolved value (game, else console, else nil) when it has the expected
/// class; `scope` receives where it came from.
- (id)settingForKey:(NSString *)key ofClass:(Class)expected scope:(LibretroSettingScope *)scope {
  if (scope != NULL) *scope = LibretroSettingScopeDefault;
  id<LibretroFrontendMenuHost> host = _host;
  if (host == nil) return nil;
  LibretroSettingScope found = LibretroSettingScopeDefault;
  id value = [host.frontendStore valueForKey:key console:host.console game:[self currentGameKey] scope:&found];
  if (![value isKindOfClass:expected]) return nil;
  if (scope != NULL) *scope = found;
  return value;
}

/// YES when the game has its own value for a key starting with one of
/// `prefixes`: the page then writes for this game by default.
- (BOOL)gameHasValueForPrefixes:(NSArray<NSString *> *)prefixes {
  id<LibretroFrontendMenuHost> host = _host;
  NSString *game = [self currentGameKey];
  if (host == nil || game == nil) return NO;
  id games = [host.frontendStore snapshotForConsole:host.console][@"games"];
  id values = [games isKindOfClass:[NSDictionary class]] ? ((NSDictionary *)games)[game] : nil;
  if (![values isKindOfClass:[NSDictionary class]]) return NO;
  for (id key in (NSDictionary *)values) {
    if (![key isKindOfClass:[NSString class]]) continue;
    for (NSString *prefix in prefixes) {
      if ([(NSString *)key hasPrefix:prefix]) return YES;
    }
  }
  return NO;
}

- (LibretroFrontendPageState *)stateForPrefixes:(NSArray<NSString *> *)prefixes {
  LibretroFrontendPageState *state = [LibretroFrontendPageState new];
  state.gameScope = [self gameHasValueForPrefixes:prefixes];
  state.writtenOpacity = -1;
  return state;
}

/// Writes one key at the page's scope (nil removes it at that scope).
- (BOOL)storeValue:(id)value forKey:(NSString *)key state:(LibretroFrontendPageState *)state {
  id<LibretroFrontendMenuHost> host = _host;
  if (host == nil) return NO;
  BOOL saved = [host.frontendStore setValue:value forKey:key console:host.console game:[self gameKeyForState:state]];
  if (!saved) NSLog(@"[Libretro] frontend setting %@ was not saved", key);
  return saved;
}

/// Writes one key, then lets the session apply every frontend setting.
- (void)applyValue:(id)value forKey:(NSString *)key state:(LibretroFrontendPageState *)state {
  [self storeValue:value forKey:key state:state];
  [_host frontendSettingsDidChange];
}

/// Dictionary a change starts from: at game scope what is in effect (the
/// game's, else the console's, so the console's other entries are kept);
/// at console scope the console's own value.
- (NSDictionary *)dictionaryToEditForKey:(NSString *)key state:(LibretroFrontendPageState *)state {
  id<LibretroFrontendMenuHost> host = _host;
  if (host == nil) return @{};
  NSString *game = [self gameKeyForState:state];
  id value = game != nil ? [host.frontendStore valueForKey:key console:host.console game:game scope:NULL]
                         : [host.frontendStore storedValueForKey:key console:host.console game:nil];
  return [value isKindOfClass:[NSDictionary class]] ? value : @{};
}

/// An empty dictionary is kept for a game (it hides the console's entries)
/// and removed for the console.
- (void)applyDictionary:(NSDictionary *)dictionary forKey:(NSString *)key state:(LibretroFrontendPageState *)state {
  BOOL game = [self gameKeyForState:state] != nil;
  id value = (dictionary.count > 0 || game) ? [dictionary copy] : nil;
  [self applyValue:value forKey:key state:state];
}

- (void)resetPrefixes:(NSArray<NSString *> *)prefixes state:(LibretroFrontendPageState *)state {
  id<LibretroFrontendMenuHost> host = _host;
  if (host == nil) return;
  [host.frontendStore resetConsole:host.console game:[self gameKeyForState:state] prefixes:prefixes];
  [host frontendSettingsDidChange];
}

- (LibretroScreenFormat)currentFormatWithScope:(LibretroSettingScope *)scope {
  NSString *identifier = [self settingForKey:LibretroSettingScreenFormat ofClass:[NSString class] scope:scope];
  return LibretroScreenFormatFromIdentifier(identifier);
}

/// Arrangement in effect for an orientation; the default one when nothing
/// valid is stored.
- (NSString *)arrangementForOrientation:(LibretroSkinOrientation)orientation scope:(LibretroSettingScope *)scope {
  NSString *console = _host.console ?: @"";
  NSArray<NSString *> *allowed = [LibretroDefaultSkins arrangementsForConsole:console orientation:orientation];
  NSString *stored = [self settingForKey:ArrangementKey(orientation) ofClass:[NSString class] scope:scope];
  if (stored != nil && [allowed containsObject:stored]) return stored;
  if (scope != NULL) *scope = LibretroSettingScopeDefault;
  return [LibretroDefaultSkins defaultArrangementForConsole:console orientation:orientation];
}

- (BOOL)screensSwappedWithScope:(LibretroSettingScope *)scope {
  NSNumber *swapped = [self settingForKey:LibretroSettingScreensSwapped ofClass:[NSNumber class] scope:scope];
  return swapped.boolValue;
}

- (float)opacityWithScope:(LibretroSettingScope *)scope {
  NSNumber *number = [self settingForKey:LibretroSettingOpacity ofClass:[NSNumber class] scope:scope];
  float fallback = _host.currentRepresentation.generated ? kOpacityDefaultSkin : kOpacityImportedSkin;
  float value = number != nil ? number.floatValue : fallback;
  if (!isfinite(value)) value = fallback;
  return fminf(fmaxf(value, kOpacityMinimum), kOpacityMaximum);
}

/// Preset in effect: shader.enabled and a known shader.preset (game value,
/// else console value); nil for the standard picture.
- (LibretroShaderPreset *)activeShaderPresetWithScope:(LibretroSettingScope *)scope {
  LibretroSettingScope enabledScope = LibretroSettingScopeDefault;
  LibretroSettingScope presetScope = LibretroSettingScopeDefault;
  NSNumber *enabled = [self settingForKey:LibretroSettingShaderEnabled ofClass:[NSNumber class] scope:&enabledScope];
  NSString *identifier = [self settingForKey:LibretroSettingShaderPreset ofClass:[NSString class] scope:&presetScope];
  if (scope != NULL) *scope = MaxScope(enabledScope, presetScope);
  if (!enabled.boolValue || identifier == nil) return nil;
  return [LibretroShaderLibrary presetWithIdentifier:identifier];
}

- (BOOL)usesDefaultSkin:(id<LibretroFrontendMenuHost>)host {
  return [host.currentSkin.installedIdentifier isEqualToString:LibretroDefaultSkinIdentifier];
}

#pragma mark Pages

/// Re-reads the page once the current UIKit event is over (toggles,
/// slider releases).
- (void)rebuildSoon:(LibretroMenuPage *)page {
  __weak LibretroMenuPage *weakPage = page;
  dispatch_async(dispatch_get_main_queue(), ^{
    [weakPage rebuild];
  });
}

- (LibretroMenuPage *)pageWithTitle:(NSString *)title
                           previews:(BOOL)previews
                           sections:(LibretroFrontendSections)sections {
  __weak LibretroFrontendMenu *weakSelf = self;
  LibretroMenuPage *page =
      [[LibretroMenuPage alloc] initWithTitle:title
                                      builder:^NSArray<LibretroMenuSection *> * {
                                        LibretroFrontendMenu *menu = weakSelf;
                                        id<LibretroFrontendMenuHost> host = menu != nil ? menu->_host : nil;
                                        if (host == nil) return @[];
                                        return sections(menu, host);
                                      }];
  page.previewsGame = previews;
  return page;
}

/// "Save for": this console's games or this game only (page-local choice).
- (LibretroMenuSection *)scopeSectionWithState:(LibretroFrontendPageState *)state {
  BOOL hasGame = [self currentGameKey] != nil;
  LibretroMenuRow *console = [LibretroMenuRow rowWithTitle:[self consoleScopeTitle]
                                                    action:^(LibretroMenuPage *page) {
                                                      state.gameScope = NO;
                                                      [page rebuild];
                                                    }];
  console.checked = !state.gameScope || !hasGame;
  console.identifier = @"libretro-frontend-scope-console";
  NSMutableArray<LibretroMenuRow *> *rows = [NSMutableArray arrayWithObject:console];
  if (hasGame) {
    LibretroMenuRow *game = [LibretroMenuRow rowWithTitle:[self text:@"scopeGame"]
                                                   action:^(LibretroMenuPage *page) {
                                                     state.gameScope = YES;
                                                     [page rebuild];
                                                   }];
    game.checked = state.gameScope;
    game.identifier = @"libretro-frontend-scope-game";
    [rows addObject:game];
  }
  LibretroMenuSection *section = [LibretroMenuSection sectionWithTitle:[self text:@"scopeSection"] rows:rows];
  section.footer = [self text:@"scopeFooter"];
  return section;
}

/// "Restore defaults": removes the page's keys at the chosen scope, then
/// the session re-applies everything; `after` runs once that is done.
- (LibretroMenuSection *)resetSectionWithTitle:(NSString *)title
                                         state:(LibretroFrontendPageState *)state
                                      prefixes:(NSArray<NSString *> *)prefixes
                                         after:(void (^)(LibretroMenuPage *page))after {
  __weak LibretroFrontendMenu *weakSelf = self;
  LibretroMenuRow *row = [LibretroMenuRow
      rowWithTitle:title
            action:^(LibretroMenuPage *page) {
              LibretroFrontendMenu *menu = weakSelf;
              if (menu == nil) return;
              NSString *message = [menu text:@"resetSettingsConfirm"
                                   replacing:@"{scope}"
                                        with:[menu scopeTitleForState:state]];
              __weak LibretroMenuPage *weakPage = page;
              [page confirmWithTitle:title
                             message:message
                              action:title
                         cancelTitle:[menu text:@"cancel"]
                         destructive:YES
                             handler:^{
                               LibretroFrontendMenu *owner = weakSelf;
                               LibretroMenuPage *target = weakPage;
                               if (owner == nil) return;
                               [owner resetPrefixes:prefixes state:state];
                               if (after != nil && target != nil) after(target);
                               [target rebuild];
                             }];
            }];
  row.destructive = YES;
  row.identifier = @"libretro-frontend-reset";
  return [LibretroMenuSection sectionWithTitle:nil rows:@[ row ]];
}

#pragma mark Root rows

- (NSArray<LibretroMenuRow *> *)rootRows {
  id<LibretroFrontendMenuHost> host = _host;
  if (host == nil) return @[];
  __weak LibretroFrontendMenu *weakSelf = self;
  NSMutableArray<LibretroMenuRow *> *rows = [NSMutableArray array];

  LibretroMenuRow *skins = [LibretroMenuRow rowWithTitle:[self text:@"skins"]
                                                  action:^(LibretroMenuPage *page) {
                                                    LibretroMenuPage *next = [weakSelf skinsPage];
                                                    if (next != nil) [page push:next];
                                                  }];
  skins.detail = [self nameForSkin:host.currentSkin];
  skins.disclosure = YES;
  skins.identifier = @"libretro-menu-skins";
  [rows addObject:skins];

  LibretroMenuRow *format = [LibretroMenuRow rowWithTitle:[self text:@"screenFormat"]
                                                   action:^(LibretroMenuPage *page) {
                                                     LibretroMenuPage *next = [weakSelf formatPage];
                                                     if (next != nil) [page push:next];
                                                   }];
  format.detail = [self labelForFormat:[self currentFormatWithScope:NULL]];
  format.disclosure = YES;
  format.identifier = @"libretro-menu-screen-format";
  [rows addObject:format];

  if ([LibretroDefaultSkins isDualScreenConsole:host.console]) {
    LibretroMenuRow *layout = [LibretroMenuRow rowWithTitle:[self text:@"settingScreenLayout"]
                                                     action:^(LibretroMenuPage *page) {
                                                       LibretroMenuPage *next = [weakSelf arrangementPage];
                                                       if (next != nil) [page push:next];
                                                     }];
    // An imported skin places the screens itself: no arrangement to show.
    if ([self usesDefaultSkin:host] && host.screensAndShadersAvailable) {
      layout.detail = [self labelForArrangement:[self arrangementForOrientation:host.currentOrientation scope:NULL]];
    }
    layout.disclosure = YES;
    layout.identifier = @"libretro-menu-screen-layout";
    [rows addObject:layout];
  }

  LibretroMenuRow *shaders = [LibretroMenuRow rowWithTitle:[self text:@"shaders"]
                                                    action:^(LibretroMenuPage *page) {
                                                      LibretroMenuPage *next = [weakSelf shadersPage];
                                                      if (next != nil) [page push:next];
                                                    }];
  if (host.screensAndShadersAvailable) {
    LibretroShaderPreset *preset = [self activeShaderPresetWithScope:NULL];
    if (preset != nil) shaders.detail = [self text:preset.nameKey];
  }
  shaders.disclosure = YES;
  shaders.identifier = @"libretro-menu-shaders";
  [rows addObject:shaders];

  LibretroMenuRow *controls = [LibretroMenuRow rowWithTitle:[self text:@"controls"]
                                                     action:^(LibretroMenuPage *page) {
                                                       LibretroMenuPage *next = [weakSelf controlsPage];
                                                       if (next != nil) [page push:next];
                                                     }];
  controls.disclosure = YES;
  controls.identifier = @"libretro-menu-controls";
  [rows addObject:controls];
  return [rows copy];
}

#pragma mark Skins

- (LibretroMenuPage *)skinsPage {
  LibretroFrontendPageState *state =
      [self stateForPrefixes:@[ LibretroSettingSkinPortrait, LibretroSettingSkinLandscape ]];
  return [self pageWithTitle:[self text:@"skins"]
                    previews:YES
                    sections:^(LibretroFrontendMenu *menu, id<LibretroFrontendMenuHost> host) {
                      return [menu skinSectionsWithHost:host state:state];
                    }];
}

/// Default skin first, then the other skins once each.
- (NSArray<LibretroSkin *> *)orderedSkinsForHost:(id<LibretroFrontendMenuHost>)host {
  NSMutableArray<LibretroSkin *> *ordered = [NSMutableArray array];
  NSMutableSet<NSString *> *seen = [NSMutableSet set];
  LibretroSkin *defaultSkin = nil;
  for (id candidate in host.availableSkins) {
    if (![candidate isKindOfClass:[LibretroSkin class]]) continue;
    LibretroSkin *skin = candidate;
    NSString *identifier = skin.installedIdentifier;
    if (identifier.length == 0 || [seen containsObject:identifier]) continue;
    [seen addObject:identifier];
    if ([identifier isEqualToString:LibretroDefaultSkinIdentifier]) {
      defaultSkin = skin;
    } else {
      [ordered addObject:skin];
    }
  }
  if (defaultSkin == nil) defaultSkin = [LibretroDefaultSkins skinForConsole:host.console ?: @""];
  [ordered insertObject:defaultSkin atIndex:0];
  return ordered;
}

/// "By <author> · Portrait only".
- (NSString *)detailForSkin:(LibretroSkin *)skin iPad:(BOOL)iPad {
  NSArray<NSString *> *orientations = [skin orientationsForIPad:iPad];
  BOOL portrait = [orientations containsObject:LibretroSkinOrientationName(LibretroSkinOrientationPortrait)];
  BOOL landscape = [orientations containsObject:LibretroSkinOrientationName(LibretroSkinOrientationLandscape)];
  NSString *summary = nil;
  if (portrait && landscape) {
    summary = [self text:@"skinBothOrientations"];
  } else if (portrait) {
    summary = [self text:@"skinPortraitOnly"];
  } else if (landscape) {
    summary = [self text:@"skinLandscapeOnly"];
  }
  NSString *author = skin.author.length > 0 ? [self text:@"skinAuthor" replacing:@"{author}" with:skin.author] : nil;
  if (author != nil && summary != nil) return [NSString stringWithFormat:@"%@ · %@", author, summary];
  return author ?: summary;
}

- (NSString *)previewKeyForSkin:(LibretroSkin *)skin
                 representation:(LibretroSkinRepresentation *)representation
                    orientation:(LibretroSkinOrientation)orientation
                           size:(CGSize)size {
  NSString *screens = @"";
  NSString *console = _host.console ?: @"";
  // The DS / 3DS default skin is generated for the current screen places.
  if ([skin.installedIdentifier isEqualToString:LibretroDefaultSkinIdentifier] &&
      [LibretroDefaultSkins isDualScreenConsole:console]) {
    screens = [NSString stringWithFormat:@"%@-%d", [self arrangementForOrientation:orientation scope:NULL],
                                         [self screensSwappedWithScope:NULL] ? 1 : 0];
  }
  return [NSString stringWithFormat:@"%@|%@|%.0fx%.0f|%.0fx%.0f|%@", skin.installedIdentifier,
                                    LibretroSkinOrientationName(orientation), representation.mappingSize.w,
                                    representation.mappingSize.h, (double)size.width, (double)size.height, screens];
}

/// Renders a preview once (off the main thread, by the host) and hands it
/// to every row waiting for it.
- (void)loadPreviewForKey:(NSString *)cacheKey
           representation:(LibretroSkinRepresentation *)representation
                     size:(CGSize)size
                  deliver:(LibretroPreviewDelivery)deliver {
  if (deliver == nil) return;
  UIImage *cached = _previews[cacheKey];
  if (cached != nil) {
    deliver(cached);
    return;
  }
  NSMutableArray<LibretroPreviewDelivery> *pending = _previewWaiters[cacheKey];
  if (pending != nil) {
    [pending addObject:[deliver copy]];
    return;
  }
  id<LibretroFrontendMenuHost> host = _host;
  if (host == nil) {
    deliver(nil);
    return;
  }
  NSMutableArray<LibretroPreviewDelivery> *waiters = [NSMutableArray arrayWithObject:[deliver copy]];
  _previewWaiters[cacheKey] = waiters;
  __weak LibretroFrontendMenu *weakSelf = self;
  [host renderPreviewForRepresentation:representation
                                  size:size
                            completion:^(UIImage *_Nullable image) {
                              LibretroFrontendMenu *menu = weakSelf;
                              if (menu != nil) {
                                [menu->_previewWaiters removeObjectForKey:cacheKey];
                                if (image != nil) menu->_previews[cacheKey] = image;
                              }
                              for (NSUInteger index = 0; index < waiters.count; index++) {
                                LibretroPreviewDelivery waiter = waiters[index];
                                waiter(image);
                              }
                            }];
}

- (NSArray<LibretroMenuSection *> *)skinSectionsWithHost:(id<LibretroFrontendMenuHost>)host
                                                   state:(LibretroFrontendPageState *)state {
  __weak LibretroFrontendMenu *weakSelf = self;
  NSMutableArray<LibretroMenuSection *> *sections = [NSMutableArray arrayWithObject:[self scopeSectionWithState:state]];
  NSArray<LibretroSkin *> *skins = [self orderedSkinsForHost:host];
  BOOL iPad = UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad;
  NSArray<NSNumber *> *orientations = @[ @(LibretroSkinOrientationPortrait), @(LibretroSkinOrientationLandscape) ];
  for (NSNumber *value in orientations) {
    LibretroSkinOrientation orientation = (LibretroSkinOrientation)value.integerValue;
    NSString *key = SkinKey(orientation);
    LibretroSettingScope scope = LibretroSettingScopeDefault;
    NSString *stored = [self settingForKey:key ofClass:[NSString class] scope:&scope];

    // Only skins with this orientation are listed; a selection naming
    // another skin falls back to the default skin, as the game does.
    NSMutableArray<LibretroSkin *> *listed = [NSMutableArray array];
    NSMutableArray<LibretroSkinRepresentation *> *representations = [NSMutableArray array];
    BOOL storedInstalled = stored == nil || [stored isEqualToString:LibretroDefaultSkinIdentifier];
    BOOL storedListed = NO;
    LibretroSize reference = {0, 0};
    for (LibretroSkin *skin in skins) {
      if ([skin.installedIdentifier isEqualToString:stored]) storedInstalled = YES;
      LibretroSkinRepresentation *representation = [host previewRepresentationForSkin:skin orientation:orientation];
      if (representation == nil) continue;
      if ([skin.installedIdentifier isEqualToString:stored]) storedListed = YES;
      // The default skin is generated at the game view's size.
      if (listed.count == 0) reference = representation.mappingSize;
      [listed addObject:skin];
      [representations addObject:representation];
    }
    NSString *selected = storedListed ? stored : LibretroDefaultSkinIdentifier;
    CGSize imageSize = PreviewSize(reference, orientation);

    NSMutableArray<LibretroMenuRow *> *rows = [NSMutableArray arrayWithCapacity:listed.count];
    for (NSUInteger index = 0; index < listed.count; index++) {
      LibretroSkin *skin = listed[index];
      LibretroSkinRepresentation *representation = representations[index];
      NSString *identifier = skin.installedIdentifier;
      LibretroMenuRow *row = [LibretroMenuRow rowWithTitle:[self nameForSkin:skin] ?: identifier
                                                    action:^(LibretroMenuPage *page) {
                                                      [weakSelf applyValue:identifier forKey:key state:state];
                                                      [page rebuild];
                                                    }];
      row.checked = [identifier isEqualToString:selected];
      row.detail = [self detailForSkin:skin iPad:iPad];
      row.identifier = [NSString
          stringWithFormat:@"libretro-skin-%@-%@", LibretroSkinOrientationName(orientation), identifier];
      row.imageSize = imageSize;
      NSString *cacheKey = [self previewKeyForSkin:skin
                                    representation:representation
                                       orientation:orientation
                                              size:imageSize];
      UIImage *cached = _previews[cacheKey];
      if (cached != nil) {
        row.image = cached;
      } else {
        row.imageLoader = ^(void (^deliver)(UIImage *_Nullable image)) {
          LibretroFrontendMenu *menu = weakSelf;
          if (menu == nil) {
            if (deliver != nil) deliver(nil);
            return;
          }
          [menu loadPreviewForKey:cacheKey representation:representation size:imageSize deliver:deliver];
        };
      }
      [rows addObject:row];
    }

    BOOL last = orientation == LibretroSkinOrientationLandscape;
    LibretroMenuSection *section = [LibretroMenuSection sectionWithTitle:[self labelForOrientation:orientation]
                                                                    rows:rows];
    section.footer = JoinedText([self sourceTextForScope:scope], storedInstalled ? nil : [self text:@"skinLoadFailed"],
                                last ? [self text:@"skinFallbackFooter"] : nil,
                                last ? [self text:@"skinManageFooter"] : nil);
    [sections addObject:section];
  }
  [sections addObject:[self resetSectionWithTitle:[self text:@"resetSettings"]
                                            state:state
                                         prefixes:@[ LibretroSettingSkinPortrait, LibretroSettingSkinLandscape ]
                                            after:nil]];
  return sections;
}

#pragma mark Screen format

- (LibretroMenuPage *)formatPage {
  LibretroFrontendPageState *state = [self stateForPrefixes:@[ LibretroSettingScreenFormat ]];
  return [self pageWithTitle:[self text:@"screenFormat"]
                    previews:YES
                    sections:^(LibretroFrontendMenu *menu, id<LibretroFrontendMenuHost> host) {
                      return [menu formatSectionsWithHost:host state:state];
                    }];
}

- (NSArray<LibretroMenuSection *> *)formatSectionsWithHost:(id<LibretroFrontendMenuHost>)host
                                                     state:(LibretroFrontendPageState *)state {
  __weak LibretroFrontendMenu *weakSelf = self;
  LibretroSettingScope scope = LibretroSettingScopeDefault;
  LibretroScreenFormat current = [self currentFormatWithScope:&scope];
  NSMutableArray<LibretroMenuRow *> *rows = [NSMutableArray array];
  for (NSString *identifier in LibretroScreenFormatIdentifiers()) {
    LibretroScreenFormat format = LibretroScreenFormatFromIdentifier(identifier);
    LibretroMenuRow *row = [LibretroMenuRow rowWithTitle:[self labelForFormat:format]
                                                  action:^(LibretroMenuPage *page) {
                                                    [weakSelf applyValue:identifier
                                                                  forKey:LibretroSettingScreenFormat
                                                                   state:state];
                                                    [page rebuild];
                                                  }];
    row.checked = format == current;
    if (format == LibretroScreenFormatOriginal) row.detail = [self coreRatioText];
    row.identifier = [@"libretro-format-" stringByAppendingString:identifier];
    [rows addObject:row];
  }
  LibretroMenuSection *formats = [LibretroMenuSection sectionWithTitle:nil rows:rows];
  BOOL dual = [LibretroDefaultSkins isDualScreenConsole:host.console];
  formats.footer = JoinedText([self sourceTextForScope:scope], [self text:@"formatFooter"],
                              dual ? [self text:@"formatDualFooter"] : nil, nil);
  return @[
    [self scopeSectionWithState:state], formats,
    [self resetSectionWithTitle:[self text:@"resetSettings"]
                          state:state
                       prefixes:@[ LibretroSettingScreenFormat ]
                          after:nil]
  ];
}

#pragma mark Screen layout (DS / 3DS)

- (LibretroMenuPage *)arrangementPage {
  NSArray<NSString *> *keys =
      @[ LibretroSettingArrangementPortrait, LibretroSettingArrangementLandscape, LibretroSettingScreensSwapped ];
  LibretroFrontendPageState *state = [self stateForPrefixes:keys];
  return [self pageWithTitle:[self text:@"settingScreenLayout"]
                    previews:YES
                    sections:^(LibretroFrontendMenu *menu, id<LibretroFrontendMenuHost> host) {
                      return [menu arrangementSectionsWithHost:host state:state keys:keys];
                    }];
}

- (NSArray<LibretroMenuSection *> *)arrangementSectionsWithHost:(id<LibretroFrontendMenuHost>)host
                                                          state:(LibretroFrontendPageState *)state
                                                           keys:(NSArray<NSString *> *)keys {
  __weak LibretroFrontendMenu *weakSelf = self;
  LibretroSkinOrientation orientation = host.currentOrientation;
  NSString *key = ArrangementKey(orientation);
  BOOL defaultSkin = [self usesDefaultSkin:host];
  BOOL available = host.screensAndShadersAvailable;
  // Arrangements belong to NeoStation's default skin; an imported skin
  // places the screens itself.
  BOOL editable = defaultSkin && available;
  LibretroSettingScope arrangementScope = LibretroSettingScopeDefault;
  LibretroSettingScope swapScope = LibretroSettingScopeDefault;
  NSString *current = [self arrangementForOrientation:orientation scope:&arrangementScope];
  BOOL swapped = [self screensSwappedWithScope:&swapScope];

  NSMutableArray<LibretroMenuRow *> *rows = [NSMutableArray array];
  for (NSString *arrangement in [LibretroDefaultSkins arrangementsForConsole:host.console orientation:orientation]) {
    LibretroMenuRow *row = [LibretroMenuRow rowWithTitle:[self labelForArrangement:arrangement]
                                                  action:^(LibretroMenuPage *page) {
                                                    [weakSelf applyValue:arrangement forKey:key state:state];
                                                    [page rebuild];
                                                  }];
    row.checked = [arrangement isEqualToString:current];
    row.enabled = editable;
    row.identifier = [@"libretro-arrangement-" stringByAppendingString:arrangement];
    [rows addObject:row];
  }
  LibretroMenuSection *arrangements = [LibretroMenuSection sectionWithTitle:[self labelForOrientation:orientation]
                                                                       rows:rows];
  NSString *limit = nil;
  if (!available) {
    limit = [self text:@"shaderUnavailable"];
  } else if (!defaultSkin) {
    limit = [self text:@"arrangementSkinFooter"];
  }
  arrangements.footer = JoinedText([self sourceTextForScope:MaxScope(arrangementScope, swapScope)], limit, nil, nil);

  LibretroMenuRow *swap = [LibretroMenuRow toggleWithTitle:[self text:@"swapScreens"]
                                                        on:swapped
                                                    toggle:^(LibretroMenuPage *page, BOOL on) {
                                                      LibretroFrontendMenu *menu = weakSelf;
                                                      [menu applyValue:@(on)
                                                                forKey:LibretroSettingScreensSwapped
                                                                 state:state];
                                                      [menu rebuildSoon:page];
                                                    }];
  swap.enabled = editable;
  swap.identifier = @"libretro-arrangement-swap";
  LibretroMenuSection *swapSection = [LibretroMenuSection sectionWithTitle:nil rows:@[ swap ]];
  swapSection.footer = [self text:@"arrangementFooter"];

  return @[
    [self scopeSectionWithState:state], arrangements, swapSection,
    [self resetSectionWithTitle:[self text:@"resetSettings"] state:state prefixes:keys after:nil]
  ];
}

#pragma mark Shaders

- (LibretroMenuPage *)shadersPage {
  LibretroFrontendPageState *state = [self stateForPrefixes:@[
    LibretroSettingShaderEnabled, LibretroSettingShaderPreset, LibretroSettingShaderParameters
  ]];
  LibretroMenuPage *page = [self pageWithTitle:[self text:@"shaders"]
                                      previews:YES
                                      sections:^(LibretroFrontendMenu *menu, id<LibretroFrontendMenuHost> host) {
                                        return [menu shaderSectionsWithHost:host state:state];
                                      }];
  // GPU time of the preset in effect, shown as soon as it is known.
  id<LibretroFrontendMenuHost> host = _host;
  if (host.screensAndShadersAvailable && [self activeShaderPresetWithScope:NULL] != nil) {
    [self measureShaderWithState:state page:page];
  }
  return page;
}

- (NSArray<LibretroMenuSection *> *)shaderSectionsWithHost:(id<LibretroFrontendMenuHost>)host
                                                     state:(LibretroFrontendPageState *)state {
  __weak LibretroFrontendMenu *weakSelf = self;
  if (!host.screensAndShadersAvailable) {
    // Vulkan frames do not reach Metal (legacy presentation).
    LibretroMenuRow *row = [LibretroMenuRow toggleWithTitle:[self text:@"shadersEnabled"]
                                                         on:NO
                                                     toggle:^(__unused LibretroMenuPage *page, __unused BOOL on){
                                                     }];
    row.enabled = NO;
    row.identifier = @"libretro-shader-enabled";
    LibretroMenuSection *section = [LibretroMenuSection sectionWithTitle:nil rows:@[ row ]];
    section.footer = [self text:@"shaderUnavailable"];
    return @[ section ];
  }

  LibretroSettingScope activeScope = LibretroSettingScopeDefault;
  LibretroSettingScope parametersScope = LibretroSettingScopeDefault;
  LibretroShaderPreset *active = [self activeShaderPresetWithScope:&activeScope];
  NSDictionary *stored = [self settingForKey:LibretroSettingShaderParameters
                                     ofClass:[NSDictionary class]
                                       scope:&parametersScope];
  NSMutableArray<LibretroMenuSection *> *sections = [NSMutableArray arrayWithObject:[self scopeSectionWithState:state]];

  LibretroMenuRow *toggle = [LibretroMenuRow toggleWithTitle:[self text:@"shadersEnabled"]
                                                          on:active != nil
                                                      toggle:^(LibretroMenuPage *page, BOOL on) {
                                                        [weakSelf setShadersEnabled:on state:state page:page];
                                                      }];
  toggle.enabled = !state.busy;
  toggle.identifier = @"libretro-shader-enabled";
  LibretroMenuSection *toggleSection = [LibretroMenuSection sectionWithTitle:nil rows:@[ toggle ]];
  toggleSection.footer = [self sourceTextForScope:MaxScope(activeScope, parametersScope)];
  [sections addObject:toggleSection];

  NSMutableArray<LibretroMenuRow *> *presetRows = [NSMutableArray array];
  for (LibretroShaderPreset *preset in [LibretroShaderLibrary presets]) {
    LibretroMenuRow *row = [LibretroMenuRow rowWithTitle:[self text:preset.nameKey]
                                                  action:^(LibretroMenuPage *page) {
                                                    [weakSelf choosePreset:preset state:state page:page];
                                                  }];
    row.checked = active != nil && [active.identifier isEqualToString:preset.identifier];
    row.enabled = !state.busy;
    row.identifier = [@"libretro-shader-" stringByAppendingString:preset.identifier];
    [presetRows addObject:row];
  }
  LibretroMenuSection *presets = [LibretroMenuSection sectionWithTitle:[self text:@"shaderPreset"] rows:presetRows];
  presets.footer = [self text:@"shaderFooter"];
  [sections addObject:presets];

  if (active != nil) {
    NSDictionary<NSString *, NSNumber *> *values = [active resolvedParameters:stored];
    NSNumberFormatter *formatter = [self formatterWithStyle:NSNumberFormatterDecimalStyle
                                      minimumFractionDigits:0
                                      maximumFractionDigits:2];
    NSMutableArray<LibretroMenuRow *> *parameterRows = [NSMutableArray array];
    for (LibretroShaderParameter *parameter in active.parameters) {
      NSString *identifier = parameter.identifier;
      NSNumber *current = values[identifier];
      LibretroMenuRow *slider = [LibretroMenuRow
          sliderWithTitle:[self text:parameter.labelKey]
                    value:current != nil ? current.floatValue : parameter.defaultValue
                  minimum:parameter.minimum
                  maximum:parameter.maximum
                     step:parameter.step
                formatter:^NSString *(float amount) {
                  return [formatter stringFromNumber:@(amount)] ?: @"";
                }
                  changed:^(LibretroMenuPage *page, float amount, BOOL finished) {
                    [weakSelf shaderParameter:identifier
                                       preset:active
                                        value:amount
                                     finished:finished
                                        state:state
                                         page:page];
                  }];
      slider.enabled = YES;
      slider.identifier = [@"libretro-shader-parameter-" stringByAppendingString:identifier];
      [parameterRows addObject:slider];
    }
    LibretroMenuRow *resetParameters = [LibretroMenuRow rowWithTitle:[self text:@"shaderResetParameters"]
                                                              action:^(LibretroMenuPage *page) {
                                                                [weakSelf resetParametersOfPreset:active
                                                                                            state:state
                                                                                             page:page];
                                                              }];
    resetParameters.enabled = active.parameters.count > 0;
    resetParameters.identifier = @"libretro-shader-reset-parameters";
    [parameterRows addObject:resetParameters];
    [sections addObject:[LibretroMenuSection sectionWithTitle:[self text:@"shaderParameters"] rows:parameterRows]];

    NSMutableArray<LibretroMenuRow *> *infoRows = [NSMutableArray array];
    if (state.measuring || state.gpuMilliseconds > 0) {
      NSString *title = nil;
      if (state.measuring) {
        title = [self text:@"shaderMeasuring"];
      } else {
        NSNumberFormatter *milliseconds = [self formatterWithStyle:NSNumberFormatterDecimalStyle
                                             minimumFractionDigits:2
                                             maximumFractionDigits:2];
        title = [self text:@"shaderGpuTime"
                 replacing:@"{ms}"
                      with:[milliseconds stringFromNumber:@(state.gpuMilliseconds)]];
      }
      LibretroMenuRow *gpu = [LibretroMenuRow rowWithTitle:title action:nil];
      gpu.identifier = @"libretro-shader-gpu-time";
      [infoRows addObject:gpu];
    }
    // Authors and licence stay as the upstream files give them.
    NSString *credits = [[self text:@"shaderCredits" replacing:@"{authors}" with:active.authors]
        stringByReplacingOccurrencesOfString:@"{license}"
                                  withString:active.license ?: @""];
    LibretroMenuRow *creditsRow = [LibretroMenuRow rowWithTitle:credits action:nil];
    creditsRow.identifier = @"libretro-shader-credits";
    [infoRows addObject:creditsRow];
    [sections addObject:[LibretroMenuSection sectionWithTitle:nil rows:infoRows]];
  }

  [sections addObject:[self resetSectionWithTitle:[self text:@"resetSettings"]
                                            state:state
                                         prefixes:@[
                                           LibretroSettingShaderEnabled, LibretroSettingShaderPreset,
                                           LibretroSettingShaderParameters
                                         ]
                                            after:^(LibretroMenuPage *page) {
                                              [weakSelf applyResolvedShaderWithState:state page:page];
                                            }]];
  return sections;
}

/// Asks the host for the GPU time of the preset in effect; the answer
/// replaces "Measuring…" unless a newer change started another measurement.
- (void)measureShaderWithState:(LibretroFrontendPageState *)state page:(LibretroMenuPage *)page {
  id<LibretroFrontendMenuHost> host = _host;
  if (host == nil) return;
  NSUInteger measurement = state.measurement + 1;
  state.measurement = measurement;
  state.measuring = YES;
  state.gpuMilliseconds = 0;
  __weak LibretroMenuPage *weakPage = page;
  [host measureShaderWithCompletion:^(double milliseconds) {
    if (state.measurement != measurement) return;
    state.measuring = NO;
    state.gpuMilliseconds = isfinite(milliseconds) && milliseconds > 0 ? milliseconds : 0;
    // Never during a drag: the slider would lose its touch.
    if (!state.dragging) [weakPage rebuild];
  }];
}

/// Forgets any measurement in progress (the preset is about to change).
- (void)clearMeasurementOfState:(LibretroFrontendPageState *)state {
  state.measurement += 1;
  state.measuring = NO;
  state.gpuMilliseconds = 0;
}

- (void)setShadersEnabled:(BOOL)on state:(LibretroFrontendPageState *)state page:(LibretroMenuPage *)page {
  id<LibretroFrontendMenuHost> host = _host;
  if (host == nil) return;
  if (state.busy) {
    // A compilation is pending: the switch goes back to the stored state.
    [self rebuildSoon:page];
    return;
  }
  if (!on) {
    [self storeValue:@NO forKey:LibretroSettingShaderEnabled state:state];
    // Standard picture, unless this game keeps its own shader over a
    // console-wide change: the picture always shows what is in effect.
    [self applyResolvedShaderWithState:state page:page];
    [self rebuildSoon:page];
    return;
  }
  NSString *storedIdentifier = [self settingForKey:LibretroSettingShaderPreset ofClass:[NSString class] scope:NULL];
  LibretroShaderPreset *preset = storedIdentifier != nil ? [LibretroShaderLibrary presetWithIdentifier:storedIdentifier]
                                                         : nil;
  BOOL samePreset = preset != nil;
  if (preset == nil) preset = [LibretroShaderLibrary presets].firstObject;
  if (preset == nil) {
    [self rebuildSoon:page];
    return;
  }
  NSDictionary *stored = [self settingForKey:LibretroSettingShaderParameters ofClass:[NSDictionary class] scope:NULL];
  NSDictionary<NSString *, NSNumber *> *parameters = [preset resolvedParameters:samePreset ? stored : nil];
  [self activatePreset:preset parameters:parameters storeParameters:!samePreset state:state page:page];
}

- (void)choosePreset:(LibretroShaderPreset *)preset
               state:(LibretroFrontendPageState *)state
                page:(LibretroMenuPage *)page {
  if (state.busy || preset == nil) return;
  LibretroShaderPreset *active = [self activeShaderPresetWithScope:NULL];
  if ([active.identifier isEqualToString:preset.identifier]) return;
  NSString *storedIdentifier = [self settingForKey:LibretroSettingShaderPreset ofClass:[NSString class] scope:NULL];
  BOOL samePreset = [storedIdentifier isEqualToString:preset.identifier];
  // Another preset starts from its own defaults.
  NSDictionary *stored = [self settingForKey:LibretroSettingShaderParameters ofClass:[NSDictionary class] scope:NULL];
  NSDictionary<NSString *, NSNumber *> *parameters = [preset resolvedParameters:samePreset ? stored : nil];
  [self activatePreset:preset parameters:parameters storeParameters:!samePreset state:state page:page];
}

/// Compiles and activates a preset; it is saved (enabled, preset and, for a
/// new preset, its default parameters) only when the host reports success.
/// On failure the standard picture is active: the preset in effect before
/// is brought back, and nothing is saved.
- (void)activatePreset:(LibretroShaderPreset *)preset
            parameters:(NSDictionary<NSString *, NSNumber *> *)parameters
       storeParameters:(BOOL)storeParameters
                 state:(LibretroFrontendPageState *)state
                  page:(LibretroMenuPage *)page {
  id<LibretroFrontendMenuHost> host = _host;
  if (host == nil) return;
  LibretroShaderPreset *previous = [self activeShaderPresetWithScope:NULL];
  NSDictionary *storedParameters = [self settingForKey:LibretroSettingShaderParameters
                                               ofClass:[NSDictionary class]
                                                 scope:NULL];
  NSDictionary<NSString *, NSNumber *> *previousParameters =
      previous != nil ? [previous resolvedParameters:storedParameters] : nil;
  NSString *identifier = preset.identifier;
  state.busy = YES;
  [self clearMeasurementOfState:state];
  // The host calls this completion once and then drops it: holding the menu
  // strongly creates no cycle, and a compilation that ends after the menu
  // was closed is still saved (or, on failure, announced and undone), so the
  // store always matches the picture. Only the page's own updates need the
  // page to still exist.
  LibretroFrontendMenu *menu = self;
  __weak LibretroMenuPage *weakPage = page;
  [host applyShaderPreset:identifier
               parameters:parameters
               completion:^(BOOL success) {
                 state.busy = NO;
                 LibretroMenuPage *target = weakPage;
                 if (success) {
                   [menu storeValue:@YES forKey:LibretroSettingShaderEnabled state:state];
                   [menu storeValue:identifier forKey:LibretroSettingShaderPreset state:state];
                   if (storeParameters) {
                     [menu storeValue:RoundedParameters(parameters) forKey:LibretroSettingShaderParameters state:state];
                   }
                   LibretroShaderPreset *effective = [menu activeShaderPresetWithScope:NULL];
                   if (![effective.identifier isEqualToString:identifier]) {
                     // This game's own values hide the console-wide change.
                     [menu applyResolvedShaderWithState:state page:target];
                   } else if (target != nil) {
                     [menu measureShaderWithState:state page:target];
                   }
                 } else {
                   [menu->_host showStatus:[menu text:@"shaderFailed"]];
                   if (previous != nil) {
                     [menu restorePreset:previous parameters:previousParameters state:state page:target];
                   }
                 }
                 [target rebuild];
               }];
  [self rebuildSoon:page];
}

- (void)restorePreset:(LibretroShaderPreset *)preset
           parameters:(NSDictionary<NSString *, NSNumber *> *)parameters
                state:(LibretroFrontendPageState *)state
                 page:(LibretroMenuPage *)page {
  id<LibretroFrontendMenuHost> host = _host;
  if (host == nil) return;
  state.busy = YES;
  __weak LibretroFrontendMenu *weakSelf = self;
  __weak LibretroMenuPage *weakPage = page;
  [host applyShaderPreset:preset.identifier
               parameters:parameters
               completion:^(BOOL success) {
                 state.busy = NO;
                 // Nothing to save: only the page shows the measurement.
                 LibretroMenuPage *target = weakPage;
                 if (target == nil) return;
                 if (success) [weakSelf measureShaderWithState:state page:target];
                 [target rebuild];
               }];
}

/// After "Restore defaults": the shader settings now in effect (console's
/// or none) are applied again.
- (void)applyResolvedShaderWithState:(LibretroFrontendPageState *)state page:(LibretroMenuPage *)page {
  id<LibretroFrontendMenuHost> host = _host;
  if (host == nil) return;
  LibretroShaderPreset *preset = [self activeShaderPresetWithScope:NULL];
  NSDictionary *stored = [self settingForKey:LibretroSettingShaderParameters ofClass:[NSDictionary class] scope:NULL];
  NSDictionary<NSString *, NSNumber *> *parameters = preset != nil ? [preset resolvedParameters:stored] : nil;
  state.busy = YES;
  [self clearMeasurementOfState:state];
  // One-shot completion holding the menu (see activatePreset...): a failure
  // that ends after the menu was closed is still announced.
  LibretroFrontendMenu *menu = self;
  __weak LibretroMenuPage *weakPage = page;
  [host applyShaderPreset:preset.identifier
               parameters:parameters
               completion:^(BOOL success) {
                 state.busy = NO;
                 LibretroMenuPage *target = weakPage;
                 if (!success) {
                   [menu->_host showStatus:[menu text:@"shaderFailed"]];
                 } else if (preset != nil && target != nil) {
                   [menu measureShaderWithState:state page:target];
                 }
                 [target rebuild];
               }];
}

/// Slider of a shader parameter: live while dragging, saved on release.
- (void)shaderParameter:(NSString *)identifier
                 preset:(LibretroShaderPreset *)preset
                  value:(float)value
               finished:(BOOL)finished
                  state:(LibretroFrontendPageState *)state
                   page:(LibretroMenuPage *)page {
  id<LibretroFrontendMenuHost> host = _host;
  if (host == nil || preset == nil) return;
  state.dragging = !finished;
  [host previewShaderParameter:identifier value:value];
  if (!finished) return;
  NSDictionary *base = [self dictionaryToEditForKey:LibretroSettingShaderParameters state:state];
  NSMutableDictionary<NSString *, NSNumber *> *values = [[preset resolvedParameters:base] mutableCopy];
  values[identifier] = @(value);
  [self storeValue:RoundedParameters(values) forKey:LibretroSettingShaderParameters state:state];
  // A game value can hide a console-wide change: show the value in effect.
  NSDictionary *stored = [self settingForKey:LibretroSettingShaderParameters ofClass:[NSDictionary class] scope:NULL];
  NSNumber *effective = [preset resolvedParameters:stored][identifier];
  if (effective != nil && fabsf(effective.floatValue - value) > 1e-4f) {
    [host previewShaderParameter:identifier value:effective.floatValue];
  }
  [self measureShaderWithState:state page:page];
  [self rebuildSoon:page];
}

- (void)resetParametersOfPreset:(LibretroShaderPreset *)preset
                          state:(LibretroFrontendPageState *)state
                           page:(LibretroMenuPage *)page {
  id<LibretroFrontendMenuHost> host = _host;
  if (host == nil || preset == nil || state.busy) return;
  NSDictionary<NSString *, NSNumber *> *defaults = [preset resolvedParameters:nil];
  [self storeValue:RoundedParameters(defaults) forKey:LibretroSettingShaderParameters state:state];
  // Same preset: the values change live, no new compilation.
  for (LibretroShaderParameter *parameter in preset.parameters) {
    [host previewShaderParameter:parameter.identifier value:parameter.defaultValue];
  }
  [self measureShaderWithState:state page:page];
  [page rebuild];
}

#pragma mark Controls

- (LibretroMenuPage *)controlsPage {
  LibretroFrontendPageState *state = [self stateForPrefixes:@[ kControlsPrefix ]];
  return [self pageWithTitle:[self text:@"controls"]
                    previews:NO
                    sections:^(LibretroFrontendMenu *menu, id<LibretroFrontendMenuHost> host) {
                      return [menu controlsSectionsWithHost:host state:state];
                    }];
}

/// Logical inputs of the skin item (empty names are inert directions).
- (NSArray<NSString *> *)skinInputsOfItem:(LibretroSkinItem *)item {
  NSMutableArray<NSString *> *inputs = [NSMutableArray array];
  for (id input in item.inputs) {
    if ([input isKindOfClass:[NSString class]] && [(NSString *)input length] > 0) [inputs addObject:input];
  }
  return inputs;
}

/// Touch buttons a user may remap: buttons with inputs, except the skin's
/// own menu button, which stays the way back to this menu.
- (NSArray<LibretroSkinItem *> *)remappableItemsOfRepresentation:(LibretroSkinRepresentation *)representation {
  NSMutableArray<LibretroSkinItem *> *items = [NSMutableArray array];
  for (LibretroSkinItem *item in representation.items) {
    if (item.kind != LibretroSkinItemKindButton || item.identifier.length == 0) continue;
    NSArray<NSString *> *inputs = [self skinInputsOfItem:item];
    if (inputs.count == 0 || [inputs containsObject:@"menu"]) continue;
    [items addObject:item];
  }
  return items;
}

- (NSArray<LibretroMenuSection *> *)controlsSectionsWithHost:(id<LibretroFrontendMenuHost>)host
                                                       state:(LibretroFrontendPageState *)state {
  __weak LibretroFrontendMenu *weakSelf = self;
  LibretroSkinRepresentation *representation = host.currentRepresentation;
  BOOL movable = NO;
  for (LibretroSkinItem *item in representation.items) {
    if (item.movable) {
      movable = YES;
      break;
    }
  }
  BOOL remappable = [self remappableItemsOfRepresentation:representation].count > 0;

  LibretroMenuRow *gamepad = [LibretroMenuRow rowWithTitle:[self text:@"controlsGamepad"]
                                                    action:^(LibretroMenuPage *page) {
                                                      LibretroMenuPage *next = [weakSelf gamepadPage];
                                                      if (next != nil) [page push:next];
                                                    }];
  gamepad.disclosure = YES;
  gamepad.identifier = @"libretro-controls-gamepad";

  LibretroMenuRow *touch = [LibretroMenuRow rowWithTitle:[self text:@"controlsTouchRemap"]
                                                  action:^(LibretroMenuPage *page) {
                                                    LibretroMenuPage *next = [weakSelf touchRemapPage];
                                                    if (next != nil) [page push:next];
                                                  }];
  touch.disclosure = YES;
  touch.enabled = remappable;
  touch.identifier = @"libretro-controls-touch";

  LibretroMenuRow *edit = [LibretroMenuRow rowWithTitle:[self text:@"controlsEditLayout"]
                                                 action:^(__unused LibretroMenuPage *page) {
                                                   LibretroFrontendMenu *menu = weakSelf;
                                                   if (menu == nil) return;
                                                   // Saved for this game or for the console, as chosen above.
                                                   NSString *game = [menu gameKeyForState:state];
                                                   [menu->_host beginControlsEditingForGame:game];
                                                 }];
  edit.enabled = movable;
  edit.identifier = @"libretro-controls-edit";
  LibretroMenuSection *entries = [LibretroMenuSection sectionWithTitle:nil rows:@[ gamepad, touch, edit ]];
  // Saving the layout for the console does not change this game when it
  // has its own layout for the skin and orientation on screen.
  NSString *layoutKey = LibretroSettingLayoutKey(host.currentSkin.installedIdentifier ?: LibretroDefaultSkinIdentifier,
                                                 LibretroSkinOrientationName(host.currentOrientation));
  BOOL gameLayoutApplies = movable && !state.gameScope && [LibretroChromeLayout game:[self currentGameKey]
                                                                  hasOwnLayoutForKey:layoutKey
                                                                               store:host.frontendStore
                                                                             console:host.console ?: @""];
  entries.footer = JoinedText(movable ? nil : [self text:@"controlsNotMovable"],
                              gameLayoutApplies ? [self text:@"controlsGameLayoutApplies"] : nil, nil, nil);

  LibretroSettingScope opacityScope = LibretroSettingScopeDefault;
  float opacity = [self opacityWithScope:&opacityScope];
  NSNumberFormatter *percent = [self formatterWithStyle:NSNumberFormatterPercentStyle
                                  minimumFractionDigits:0
                                  maximumFractionDigits:0];
  LibretroMenuRow *slider = [LibretroMenuRow sliderWithTitle:[self text:@"controlsOpacity"]
                                                       value:opacity
                                                     minimum:kOpacityMinimum
                                                     maximum:kOpacityMaximum
                                                        step:kOpacityStep
                                                   formatter:^NSString *(float amount) {
                                                     return [percent stringFromNumber:@(amount)] ?: @"";
                                                   }
                                                     changed:^(LibretroMenuPage *page, float amount, BOOL finished) {
                                                       [weakSelf opacityChanged:amount
                                                                       finished:finished
                                                                          state:state
                                                                           page:page];
                                                     }];
  // An opaque imported skin draws its controls and its picture at full
  // opacity (LibretroSkinRenderer): the slider would change nothing there.
  BOOL opacityApplies = representation == nil || representation.generated || representation.translucent;
  slider.enabled = opacityApplies;
  slider.identifier = @"libretro-controls-opacity";
  LibretroMenuSection *opacitySection = [LibretroMenuSection sectionWithTitle:nil rows:@[ slider ]];
  opacitySection.footer = JoinedText([self sourceTextForScope:opacityScope],
                                     opacityApplies ? nil : [self text:@"controlsOpacityNotApplicable"], nil, nil);

  return @[
    [self scopeSectionWithState:state], entries, opacitySection,
    [self resetSectionWithTitle:[self text:@"controlsReset"] state:state prefixes:@[ kControlsPrefix ] after:nil]
  ];
}

/// The session reads the opacity from the store: each new step is written
/// (at most 18 while dragging) so the controls follow the slider live.
- (void)opacityChanged:(float)value
              finished:(BOOL)finished
                 state:(LibretroFrontendPageState *)state
                  page:(LibretroMenuPage *)page {
  state.dragging = !finished;
  if (!isfinite(value)) return;
  double clamped = fmin(fmax((double)value, (double)kOpacityMinimum), (double)kOpacityMaximum);
  double rounded = round(clamped * 100.0) / 100.0;
  if (finished || fabs(rounded - state.writtenOpacity) > 0.001) {
    state.writtenOpacity = rounded;
    [self applyValue:@(rounded) forKey:LibretroSettingOpacity state:state];
  }
  if (finished) [self rebuildSoon:page];
}

#pragma mark Controller

- (LibretroMenuPage *)gamepadPage {
  LibretroFrontendPageState *state = [self stateForPrefixes:@[ LibretroSettingGamepad ]];
  return [self pageWithTitle:[self text:@"controlsGamepad"]
                    previews:NO
                    sections:^(LibretroFrontendMenu *menu, id<LibretroFrontendMenuHost> host) {
                      return [menu gamepadSectionsWithHost:host state:state];
                    }];
}

/// The user's choice for an element when the input map accepts it (same
/// rule as -[LibretroInputMap gamepadTargetForElement:overrides:]).
- (NSString *)gamepadOverrideForElement:(NSString *)element
                              overrides:(NSDictionary *)overrides
                                    map:(LibretroInputMap *)map {
  id choice = overrides[element];
  if (![choice isKindOfClass:[NSString class]]) return nil;
  NSString *canonical = [map canonicalInput:choice];
  if (canonical == nil) return nil;
  LibretroInputTargetKind kind = [map targetForInput:canonical].kind;
  BOOL usable = kind == LibretroInputTargetButton || kind == LibretroInputTargetAnalog ||
                kind == LibretroInputTargetAction;
  return usable ? canonical : nil;
}

/// Logical input an element sends; nil when it passes its historical
/// RetroPad id through (`passthrough` YES) or sends nothing (blocked id).
- (NSString *)gamepadInputForElement:(NSString *)element
                           overrides:(NSDictionary *)overrides
                                 map:(LibretroInputMap *)map
                         passthrough:(BOOL *)passthrough {
  if (passthrough != NULL) *passthrough = NO;
  NSString *chosen = [self gamepadOverrideForElement:element overrides:overrides map:map];
  if (chosen != nil) return chosen;
  NSString *input = [map defaultInputForGamepadElement:element];
  if (input != nil) return input;
  int identifier = LibretroGamepadPassthroughButton(element);
  if (passthrough != NULL && identifier >= 0 && identifier <= 15) {
    *passthrough = (map.blockedButtons & (uint16_t)(1u << (unsigned)identifier)) == 0;
  }
  return nil;
}

- (NSArray<LibretroMenuSection *> *)gamepadSectionsWithHost:(id<LibretroFrontendMenuHost>)host
                                                      state:(LibretroFrontendPageState *)state {
  __weak LibretroFrontendMenu *weakSelf = self;
  LibretroInputMap *map = host.inputMap;
  LibretroSettingScope scope = LibretroSettingScopeDefault;
  NSDictionary *overrides = [self settingForKey:LibretroSettingGamepad ofClass:[NSDictionary class] scope:&scope];
  NSMutableArray<LibretroMenuRow *> *rows = [NSMutableArray array];
  for (NSString *element in LibretroGamepadElements()) {
    NSString *title = [self titleForGamepadElement:element];
    BOOL passthrough = NO;
    NSString *input = [self gamepadInputForElement:element overrides:overrides map:map passthrough:&passthrough];
    LibretroMenuRow *row =
        [LibretroMenuRow rowWithTitle:title
                               action:^(LibretroMenuPage *page) {
                                 LibretroMenuPage *next = [weakSelf gamepadChoicePageForElement:element state:state];
                                 if (next != nil) [page push:next];
                               }];
    if (input != nil) {
      row.detail = [self labelForInput:input map:map];
      NSString *spoken = [self spokenLabelForInput:input map:map];
      if (spoken != nil) row.spokenLabel = [NSString stringWithFormat:@"%@, %@", title, spoken];
    } else if (passthrough) {
      row.detail = [self text:@"controlsCoreDefault"];
    } else {
      row.detail = [self text:@"controlsUnassigned"];
    }
    row.disclosure = YES;
    row.identifier = [@"libretro-gamepad-" stringByAppendingString:element];
    [rows addObject:row];
  }
  LibretroMenuSection *elements = [LibretroMenuSection sectionWithTitle:nil rows:rows];
  elements.footer = JoinedText([self sourceTextForScope:scope], [self text:@"controlsGamepadFooter"],
                               host.physicalControllerConnected ? nil : [self text:@"controlsNoController"], nil);
  return @[
    [self scopeSectionWithState:state], elements,
    [self resetSectionWithTitle:[self text:@"resetSettings"] state:state prefixes:@[ LibretroSettingGamepad ] after:nil]
  ];
}

/// Console buttons (and directions when `directions`) the map can send.
- (NSArray<NSString *> *)buttonInputsOfMap:(LibretroInputMap *)map directions:(BOOL)directions {
  NSMutableArray<NSString *> *inputs = [NSMutableArray array];
  for (NSString *input in map.buttons) {
    if ([map targetForInput:input].kind != LibretroInputTargetNone) [inputs addObject:input];
  }
  if (directions) {
    for (NSString *input in @[ @"up", @"down", @"left", @"right" ]) {
      if ([map targetForInput:input].kind != LibretroInputTargetNone) [inputs addObject:input];
    }
  }
  return inputs;
}

/// NeoStation actions a button can trigger ("Swap screens" on DS / 3DS).
- (NSArray<NSString *> *)actionInputsOfMap:(LibretroInputMap *)map console:(NSString *)console {
  NSMutableArray<NSString *> *candidates =
      [NSMutableArray arrayWithArray:@[ @"menu", @"quickSave", @"quickLoad", @"fastForward", @"toggleFastForward" ]];
  if ([LibretroDefaultSkins isDualScreenConsole:console]) [candidates addObject:@"swapScreens"];
  NSMutableArray<NSString *> *actions = [NSMutableArray array];
  for (NSString *input in candidates) {
    if ([map targetForInput:input].kind == LibretroInputTargetAction) [actions addObject:input];
  }
  return actions;
}

- (LibretroMenuRow *)choiceRowForInput:(NSString *)input
                                   map:(LibretroInputMap *)map
                               checked:(BOOL)checked
                               handler:(void (^)(LibretroMenuPage *page, NSString *input))handler {
  LibretroMenuRow *row = [LibretroMenuRow rowWithTitle:[self labelForInput:input map:map]
                                                action:^(LibretroMenuPage *page) {
                                                  handler(page, input);
                                                }];
  row.checked = checked;
  row.spokenLabel = [self spokenLabelForInput:input map:map];
  row.identifier = [@"libretro-input-" stringByAppendingString:input];
  return row;
}

- (LibretroMenuPage *)gamepadChoicePageForElement:(NSString *)element state:(LibretroFrontendPageState *)state {
  return [self pageWithTitle:[self titleForGamepadElement:element]
                    previews:NO
                    sections:^(LibretroFrontendMenu *menu, id<LibretroFrontendMenuHost> host) {
                      return [menu gamepadChoiceSectionsForElement:element host:host state:state];
                    }];
}

- (NSArray<LibretroMenuSection *> *)gamepadChoiceSectionsForElement:(NSString *)element
                                                               host:(id<LibretroFrontendMenuHost>)host
                                                              state:(LibretroFrontendPageState *)state {
  __weak LibretroFrontendMenu *weakSelf = self;
  LibretroInputMap *map = host.inputMap;
  NSDictionary *overrides = [self settingForKey:LibretroSettingGamepad ofClass:[NSDictionary class] scope:NULL];
  NSString *chosen = [self gamepadOverrideForElement:element overrides:overrides map:map];
  void (^choose)(LibretroMenuPage *, NSString *) = ^(LibretroMenuPage *page, NSString *input) {
    LibretroFrontendMenu *menu = weakSelf;
    if (menu == nil) return;
    [menu setGamepadElement:element input:input state:state];
    [page rebuild];
    [page.navigationController popViewControllerAnimated:YES];
  };

  // No override: the console's default input, else the historical RetroPad id.
  LibretroMenuRow *coreDefault = [LibretroMenuRow rowWithTitle:[self text:@"controlsCoreDefault"]
                                                        action:^(LibretroMenuPage *page) {
                                                          choose(page, nil);
                                                        }];
  coreDefault.checked = chosen == nil;
  NSString *defaultInput = [map defaultInputForGamepadElement:element];
  if (defaultInput != nil) {
    coreDefault.detail = [self labelForInput:defaultInput map:map];
    NSString *spoken = [self spokenLabelForInput:defaultInput map:map];
    if (spoken != nil) {
      coreDefault.spokenLabel = [NSString stringWithFormat:@"%@, %@", [self text:@"controlsCoreDefault"], spoken];
    }
  }
  coreDefault.identifier = @"libretro-input-core-default";

  NSMutableArray<LibretroMenuRow *> *buttons = [NSMutableArray array];
  for (NSString *input in [self buttonInputsOfMap:map directions:YES]) {
    [buttons addObject:[self choiceRowForInput:input
                                           map:map
                                       checked:[chosen isEqualToString:input]
                                       handler:choose]];
  }
  NSMutableArray<LibretroMenuRow *> *actions = [NSMutableArray array];
  for (NSString *input in [self actionInputsOfMap:map console:host.console]) {
    [actions addObject:[self choiceRowForInput:input
                                           map:map
                                       checked:[chosen isEqualToString:input]
                                       handler:choose]];
  }
  NSMutableArray<LibretroMenuSection *> *sections =
      [NSMutableArray arrayWithObject:[LibretroMenuSection sectionWithTitle:nil rows:@[ coreDefault ]]];
  // The console's product name heads its own buttons.
  if (buttons.count > 0) [sections addObject:[LibretroMenuSection sectionWithTitle:host.consoleName rows:buttons]];
  if (actions.count > 0) [sections addObject:[LibretroMenuSection sectionWithTitle:nil rows:actions]];
  return sections;
}

- (void)setGamepadElement:(NSString *)element input:(NSString *)input state:(LibretroFrontendPageState *)state {
  NSMutableDictionary *overrides = [[self dictionaryToEditForKey:LibretroSettingGamepad state:state] mutableCopy];
  if (input != nil) {
    overrides[element] = input;
  } else {
    [overrides removeObjectForKey:element];
  }
  [self applyDictionary:overrides forKey:LibretroSettingGamepad state:state];
}

#pragma mark Touch buttons

- (LibretroMenuPage *)touchRemapPage {
  id<LibretroFrontendMenuHost> host = _host;
  NSString *skinId = host.currentSkin.installedIdentifier;
  if (host == nil || skinId.length == 0) return nil;
  LibretroFrontendPageState *state = [self stateForPrefixes:@[ LibretroSettingTouchRemapKey(skinId) ]];
  return [self pageWithTitle:[self text:@"controlsTouchRemap"]
                    previews:NO
                    sections:^(LibretroFrontendMenu *menu, id<LibretroFrontendMenuHost> pageHost) {
                      return [menu touchSectionsWithHost:pageHost state:state];
                    }];
}

/// The user's remap of a skin item, kept only when the map accepts it.
- (NSArray<NSString *> *)touchOverrideForItem:(LibretroSkinItem *)item
                                    overrides:(NSDictionary *)overrides
                                          map:(LibretroInputMap *)map {
  id value = overrides[item.identifier];
  if (![value isKindOfClass:[NSArray class]]) return nil;
  NSMutableArray<NSString *> *inputs = [NSMutableArray array];
  for (id raw in (NSArray *)value) {
    NSString *canonical = [raw isKindOfClass:[NSString class]] ? [map canonicalInput:raw] : nil;
    if (canonical == nil) continue;
    LibretroInputTargetKind kind = [map targetForInput:canonical].kind;
    if (kind == LibretroInputTargetButton || kind == LibretroInputTargetAnalog || kind == LibretroInputTargetAction) {
      [inputs addObject:canonical];
    }
  }
  return inputs.count > 0 ? inputs : nil;
}

- (NSArray<LibretroMenuSection *> *)touchSectionsWithHost:(id<LibretroFrontendMenuHost>)host
                                                    state:(LibretroFrontendPageState *)state {
  __weak LibretroFrontendMenu *weakSelf = self;
  LibretroInputMap *map = host.inputMap;
  // The skin on screen now (it may change with the orientation).
  NSString *skinId = host.currentSkin.installedIdentifier ?: LibretroDefaultSkinIdentifier;
  NSString *key = LibretroSettingTouchRemapKey(skinId);
  LibretroSettingScope scope = LibretroSettingScopeDefault;
  NSDictionary *overrides = [self settingForKey:key ofClass:[NSDictionary class] scope:&scope];
  NSMutableArray<LibretroMenuRow *> *rows = [NSMutableArray array];
  for (LibretroSkinItem *item in [self remappableItemsOfRepresentation:host.currentRepresentation]) {
    NSArray<NSString *> *original = [self skinInputsOfItem:item];
    NSArray<NSString *> *current = [self touchOverrideForItem:item overrides:overrides map:map] ?: original;
    // Title: what the button shows; detail: what it sends when remapped.
    NSString *title = [self labelForInputs:original map:map];
    LibretroMenuRow *row = [LibretroMenuRow rowWithTitle:title
                                                  action:^(LibretroMenuPage *page) {
                                                    LibretroMenuPage *next = [weakSelf touchChoicePageForItem:item
                                                                                                          key:key
                                                                                                        state:state];
                                                    if (next != nil) [page push:next];
                                                  }];
    BOOL remapped = ![current isEqualToArray:original];
    if (remapped) row.detail = [self labelForInputs:current map:map];
    NSString *spokenTitle = [self spokenLabelForInputs:original map:map];
    NSString *spokenDetail = remapped ? [self spokenLabelForInputs:current map:map] : nil;
    if (spokenTitle != nil || spokenDetail != nil) {
      NSString *first = spokenTitle ?: title;
      row.spokenLabel = remapped ? [NSString stringWithFormat:@"%@, %@", first, spokenDetail ?: row.detail] : first;
    }
    row.disclosure = YES;
    row.identifier = [@"libretro-touch-" stringByAppendingString:item.identifier];
    [rows addObject:row];
  }
  LibretroMenuSection *items = [LibretroMenuSection sectionWithTitle:nil rows:rows];
  items.footer = JoinedText([self sourceTextForScope:scope], [self text:@"controlsTouchFooter"], nil, nil);
  return @[
    [self scopeSectionWithState:state], items,
    [self resetSectionWithTitle:[self text:@"resetSettings"] state:state prefixes:@[ key ] after:nil]
  ];
}

- (LibretroMenuPage *)touchChoicePageForItem:(LibretroSkinItem *)item
                                         key:(NSString *)key
                                       state:(LibretroFrontendPageState *)state {
  id<LibretroFrontendMenuHost> host = _host;
  if (host == nil) return nil;
  NSString *title = [self labelForInputs:[self skinInputsOfItem:item] map:host.inputMap];
  return [self pageWithTitle:title
                    previews:NO
                    sections:^(LibretroFrontendMenu *menu, id<LibretroFrontendMenuHost> pageHost) {
                      return [menu touchChoiceSectionsForItem:item key:key host:pageHost state:state];
                    }];
}

- (NSArray<LibretroMenuSection *> *)touchChoiceSectionsForItem:(LibretroSkinItem *)item
                                                           key:(NSString *)key
                                                          host:(id<LibretroFrontendMenuHost>)host
                                                         state:(LibretroFrontendPageState *)state {
  __weak LibretroFrontendMenu *weakSelf = self;
  LibretroInputMap *map = host.inputMap;
  NSDictionary *overrides = [self settingForKey:key ofClass:[NSDictionary class] scope:NULL];
  NSArray<NSString *> *original = [self skinInputsOfItem:item];
  NSArray<NSString *> *current = [self touchOverrideForItem:item overrides:overrides map:map] ?: original;
  NSString *itemId = item.identifier;
  void (^choose)(LibretroMenuPage *, NSArray<NSString *> *) = ^(LibretroMenuPage *page, NSArray<NSString *> *inputs) {
    LibretroFrontendMenu *menu = weakSelf;
    if (menu == nil) return;
    [menu setTouchInputs:inputs forItem:itemId original:original key:key state:state];
    [page rebuild];
    [page.navigationController popViewControllerAnimated:YES];
  };
  void (^chooseOne)(LibretroMenuPage *, NSString *) = ^(LibretroMenuPage *page, NSString *input) {
    choose(page, @[ input ]);
  };

  NSMutableArray<LibretroMenuSection *> *sections = [NSMutableArray array];
  if (original.count > 1) {
    // A button pressing several inputs together keeps that choice first.
    LibretroMenuRow *combined = [LibretroMenuRow rowWithTitle:[self labelForInputs:original map:map]
                                                       action:^(LibretroMenuPage *page) {
                                                         choose(page, original);
                                                       }];
    combined.checked = [current isEqualToArray:original];
    combined.spokenLabel = [self spokenLabelForInputs:original map:map];
    combined.identifier = @"libretro-input-skin-default";
    [sections addObject:[LibretroMenuSection sectionWithTitle:nil rows:@[ combined ]]];
  }
  NSString *single = current.count == 1 ? current.firstObject : nil;
  NSMutableArray<LibretroMenuRow *> *buttons = [NSMutableArray array];
  for (NSString *input in [self buttonInputsOfMap:map directions:NO]) {
    [buttons addObject:[self choiceRowForInput:input
                                           map:map
                                       checked:[single isEqualToString:input]
                                       handler:chooseOne]];
  }
  NSMutableArray<LibretroMenuRow *> *actions = [NSMutableArray array];
  for (NSString *input in [self actionInputsOfMap:map console:host.console]) {
    [actions addObject:[self choiceRowForInput:input
                                           map:map
                                       checked:[single isEqualToString:input]
                                       handler:chooseOne]];
  }
  if (buttons.count > 0) [sections addObject:[LibretroMenuSection sectionWithTitle:host.consoleName rows:buttons]];
  if (actions.count > 0) [sections addObject:[LibretroMenuSection sectionWithTitle:nil rows:actions]];
  return sections;
}

/// Choosing the skin's own inputs removes the remap of that item.
- (void)setTouchInputs:(NSArray<NSString *> *)inputs
               forItem:(NSString *)itemId
              original:(NSArray<NSString *> *)original
                   key:(NSString *)key
                 state:(LibretroFrontendPageState *)state {
  NSMutableDictionary *overrides = [[self dictionaryToEditForKey:key state:state] mutableCopy];
  if (inputs.count == 0 || [inputs isEqualToArray:original]) {
    [overrides removeObjectForKey:itemId];
  } else {
    overrides[itemId] = [inputs copy];
  }
  [self applyDictionary:overrides forKey:key state:state];
}

@end
