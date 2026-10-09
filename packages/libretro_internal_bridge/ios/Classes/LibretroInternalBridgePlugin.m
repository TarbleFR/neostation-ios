#import "LibretroInternalBridgePlugin.h"

#import "LibretroDefaultSkins.h"
#import "LibretroFrontendStore.h"
#import "LibretroGeometry.h"
#import "LibretroJit.h"
#import "LibretroOrientation.h"
#import "LibretroSession.h"
#import "LibretroSkin.h"
#import "LibretroSkinRenderer.h"

#include <math.h>

static NSString *const kLibretroChannel = @"neostation/libretro_internal";

/// Labels the native session needs; Dart sends them translated. A missing
/// label refuses the launch rather than showing untranslated text.
static NSArray<NSString *> *LibretroRequiredUIText(void) {
  return @[
    @"menu", @"resume", @"reset", @"resetConfirm", @"saveState", @"loadState", @"slot", @"emptySlot",
    @"stateSaved", @"stateLoaded", @"stateFailed", @"changeDisc", @"disc", @"discChanged", @"display",
    @"touchControls", @"smoothing", @"fastForward", @"coreSettings", @"settingsRestartHint", @"cheats",
    @"addCheat", @"cheatName", @"cheatCode", @"cheatsHelp", @"achievements", @"achievementsEnabled",
    @"achievementsLogin", @"achievementsLogout", @"achievementsUser", @"achievementsPassword",
    @"achievementsLoggedIn", @"achievementsUnlocked", @"achievementsLoginFailed", @"achievementsNone",
    @"achievementsHelp", @"quit", @"quitConfirm", @"cancel", @"add",
    @"skins", @"screenFormat", @"shaders", @"controls", @"scopeSection", @"scopeConsole", @"scopeGame",
    @"valueFromGame", @"valueFromConsole", @"valueDefault", @"resetSettings", @"resetSettingsConfirm", @"scopeFooter",
    @"skinDefaultName", @"orientationPortrait", @"orientationLandscape", @"skinBothOrientations", @"skinPortraitOnly",
    @"skinLandscapeOnly", @"skinAuthor", @"skinFallbackFooter", @"skinLoadFailed", @"skinManageFooter",
    @"formatOriginal", @"formatStretch", @"formatCoreRatio", @"formatFooter", @"formatDualFooter", @"swapScreens",
    @"arrangementSkinFooter", @"arrangementFooter", @"shadersEnabled", @"shaderPreset", @"shaderParameters",
    @"shaderResetParameters", @"shaderGpuTime", @"shaderFooter", @"shaderFailed", @"shaderUnavailable",
    @"shaderSharpBilinear", @"shaderCrtLottesFast", @"shaderCrtHyllianFast", @"shaderZfastCrt", @"shaderScanlines",
    @"shaderLcd3x", @"shaderSameBoyLcd", @"shaderDotMatrix", @"shaderZfastLcd", @"paramPrescale", @"paramAutoPrescale",
    @"paramMaskType", @"paramMaskIntensity", @"paramScanlineThinness", @"paramHorizontalBlur", @"paramCurvature",
    @"paramCornerSize", @"paramGamma", @"paramInputGamma", @"paramOutputGamma", @"paramBrightness",
    @"paramScanlineStrength", @"paramSharper", @"paramScanlineDark", @"paramScanlineBright", @"paramMaskDarkness",
    @"paramMaskFade", @"paramAmplitude", @"paramPhase", @"paramLinesBlack", @"paramLinesWhite",
    @"paramScanlineBrightness", @"paramLcdBrightness", @"paramColorLow", @"paramColorHigh", @"paramScanlineDepth",
    @"paramShine", @"paramBlend", @"paramSoftness", @"paramBorderSize", @"paramGbaGamma", @"controlsGamepad",
    @"controlsTouchRemap", @"controlsEditLayout", @"controlsEditHint", @"controlsEditDone", @"controlsOpacity",
    @"controlsReset", @"controlsNotMovable", @"controlsGamepadFooter", @"controlsTouchFooter", @"controlsUnassigned",
    @"controlsNoController", @"inputUp", @"inputDown", @"inputLeft", @"inputRight", @"inputLeftStick",
    @"inputRightStick", @"inputTouchScreen", @"inputMenu", @"inputQuickSave", @"inputQuickLoad", @"inputFastForward",
    @"inputToggleFastForward", @"padDpadUp", @"padDpadDown", @"padDpadLeft", @"padDpadRight", @"padOptionsButton",
    @"padMenuButton", @"quickSaved", @"quickLoaded", @"quickMissing", @"fastForwardOn", @"fastForwardOff",
    @"buttonCircle", @"buttonCross", @"buttonTriangle", @"buttonSquare", @"inputDpad", @"padButtonNamed",
    @"padLeftShoulder", @"padRightShoulder", @"padLeftTrigger", @"padRightTrigger", @"padLeftStickButton",
    @"padRightStickButton", @"controlsCoreDefault", @"shaderCredits", @"shaderMeasuring", @"settingScreenLayout",
    @"layoutTopBottom", @"layoutLeftRight", @"layoutHybridTop", @"layoutTopOnly", @"layoutBottomOnly",
    @"controlsOpacityNotApplicable", @"controlsGameLayoutApplies",
  ];
}

static UIViewController *LibretroRootViewController(void) {
  UIWindow *keyWindow = nil;
  for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
    if (![scene isKindOfClass:UIWindowScene.class] || scene.activationState != UISceneActivationStateForegroundActive) {
      continue;
    }
    for (UIWindow *window in ((UIWindowScene *)scene).windows) {
      if (window.isKeyWindow) {
        keyWindow = window;
        break;
      }
    }
    if (keyWindow != nil) break;
  }
  UIViewController *controller = keyWindow.rootViewController;
  while (controller.presentedViewController != nil) controller = controller.presentedViewController;
  return controller;
}

static NSString *StringArgument(NSDictionary *arguments, NSString *key) {
  id value = arguments[key];
  return [value isKindOfClass:NSString.class] ? value : @"";
}

/// A Dart null arrives as NSNull: absent, like an empty string.
static NSString *OptionalStringArgument(NSDictionary *arguments, NSString *key) {
  NSString *value = StringArgument(arguments, key);
  return value.length > 0 ? value : nil;
}

/// Any JSON value; NSNull (Dart null) becomes nil.
static id OptionalValueArgument(NSDictionary *arguments, NSString *key) {
  id value = arguments[key];
  return value == NSNull.null ? nil : value;
}

static double NumberArgument(NSDictionary *arguments, NSString *key) {
  id value = arguments[key];
  return [value isKindOfClass:NSNumber.class] ? [value doubleValue] : NAN;
}

/// {String: String} entries only (option maps).
static NSDictionary<NSString *, NSString *> *StringDictionaryArgument(NSDictionary *arguments, NSString *key) {
  id value = arguments[key];
  NSMutableDictionary<NSString *, NSString *> *result = [NSMutableDictionary dictionary];
  if (![value isKindOfClass:NSDictionary.class]) return result;
  NSDictionary *source = value;
  for (id entry in source) {
    id text = source[entry];
    if ([entry isKindOfClass:NSString.class] && [text isKindOfClass:NSString.class]) result[entry] = text;
  }
  return result;
}

/// Console geometry of the core catalog: {console: {"size": [w, h], "regions": {...}}}.
static NSDictionary<NSString *, NSDictionary *> *GeometryArgument(NSDictionary *arguments, NSString *key) {
  id value = arguments[key];
  NSMutableDictionary<NSString *, NSDictionary *> *result = [NSMutableDictionary dictionary];
  if (![value isKindOfClass:NSDictionary.class]) return result;
  NSDictionary *source = value;
  for (id console in source) {
    id entry = source[console];
    if ([console isKindOfClass:NSString.class] && [entry isKindOfClass:NSDictionary.class]) result[console] = entry;
  }
  return result;
}

static BOOL IsAbsolutePath(NSString *path) {
  return [path hasPrefix:@"/"];
}

/// Refused channel arguments: the code is the launch error Dart already
/// translates; the message names the argument (technical detail).
static FlutterError *InvalidArgument(NSString *name) {
  return [FlutterError errorWithCode:@"LIBRETRO_INVALID_REQUEST" message:name details:nil];
}

/// Skin parsing, PNG encoding and settings clean-up run here, off the main
/// thread; results return to the main thread.
static dispatch_queue_t LibretroChannelQueue(void) {
  static dispatch_queue_t queue;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    dispatch_queue_attr_t attributes =
        dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0);
    queue = dispatch_queue_create("neostation.libretro.channel", attributes);
  });
  return queue;
}

/// Typical safe areas for previews drawn outside a game (Flutter screens).
static LibretroInsets PreviewSafeInsets(LibretroSkinOrientation orientation, BOOL iPad) {
  if (iPad) return (LibretroInsets){24, 0, 20, 0};
  if (orientation == LibretroSkinOrientationPortrait) return (LibretroInsets){47, 0, 34, 0};
  return (LibretroInsets){0, 47, 21, 47};
}

static NSDictionary<NSString *, id> *Failure(NSString *code, NSString *message) {
  return @{@"success" : @NO, @"code" : code, @"message" : message ?: @"", @"log" : @[]};
}

@interface LibretroInternalBridgePlugin ()
@property(nonatomic, strong) FlutterMethodChannel *channel;
@property(nonatomic, strong) LibretroSession *session;
@property(nonatomic, copy) NSArray<NSString *> *lastLog;
@property(nonatomic, assign) BOOL launching;
@end

@implementation LibretroInternalBridgePlugin

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
  // Portrait for embedded games (normally already installed from +load).
  LibretroOrientationInstall();
  FlutterMethodChannel *channel = [FlutterMethodChannel methodChannelWithName:kLibretroChannel
                                                              binaryMessenger:registrar.messenger];
  LibretroInternalBridgePlugin *instance = [LibretroInternalBridgePlugin new];
  instance.channel = channel;
  instance.lastLog = @[];
  [registrar addMethodCallDelegate:instance channel:channel];
}

+ (NSString *)frameworksDirectory {
  return NSBundle.mainBundle.privateFrameworksPath ?: @"";
}

+ (NSArray<NSString *> *)availableCores {
  NSMutableArray<NSString *> *cores = [NSMutableArray array];
  NSArray<NSString *> *entries = [NSFileManager.defaultManager contentsOfDirectoryAtPath:[self frameworksDirectory]
                                                                                    error:nil];
  for (NSString *entry in entries) {
    if (![entry hasSuffix:@"_libretro.framework"]) continue;
    [cores addObject:[entry substringToIndex:entry.length - @"_libretro.framework".length]];
  }
  [cores sortUsingSelector:@selector(compare:)];
  return cores;
}

/// Copies core system files shipped in Runner.app/LibretroSystem (for
/// instance PPSSPP's fonts and atlas) into the user's System folder, once.
/// Existing user files are never replaced.
+ (void)installBundledSystemFilesInto:(NSString *)systemDirectory {
  NSString *bundled = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"LibretroSystem"];
  NSFileManager *files = NSFileManager.defaultManager;
  NSArray<NSString *> *entries = [files contentsOfDirectoryAtPath:bundled error:nil];
  if (entries.count == 0 || systemDirectory.length == 0) return;
  [files createDirectoryAtPath:systemDirectory withIntermediateDirectories:YES attributes:nil error:nil];
  for (NSString *entry in entries) {
    NSString *target = [systemDirectory stringByAppendingPathComponent:entry];
    if ([files fileExistsAtPath:target]) continue;
    NSError *error = nil;
    if (![files copyItemAtPath:[bundled stringByAppendingPathComponent:entry] toPath:target error:&error]) {
      NSLog(@"[Libretro] could not install %@: %@", entry, error);
    }
  }
}

+ (NSString *)corePathForIdentifier:(NSString *)identifier {
  NSString *name = [identifier stringByAppendingString:@"_libretro"];
  NSString *relative = [NSString stringWithFormat:@"%@.framework/%@", name, name];
  return [[self frameworksDirectory] stringByAppendingPathComponent:relative];
}

- (void)handleMethodCall:(FlutterMethodCall *)call result:(FlutterResult)result {
  if ([call.method isEqualToString:@"isSessionActive"]) {
    result(@(self.session.active || self.launching));
    return;
  }
  if ([call.method isEqualToString:@"availableCores"]) {
    result([LibretroInternalBridgePlugin availableCores]);
    return;
  }
  if ([call.method isEqualToString:@"diagnostics"]) {
    NSString *molten = [[LibretroInternalBridgePlugin frameworksDirectory]
        stringByAppendingPathComponent:@"MoltenVK.framework/MoltenVK"];
    result(@{
      @"availableCores" : [LibretroInternalBridgePlugin availableCores],
      @"moltenVK" : @([NSFileManager.defaultManager isReadableFileAtPath:molten]),
      @"sessionActive" : @(self.session.active),
      @"debugged" : @(LibretroHostIsDebugged()),
      @"jitCapable" : @(LibretroJitUsableByCores()),
      @"log" : self.session != nil ? self.session.recentLog : (self.lastLog ?: @[]),
    });
    return;
  }
  if ([call.method isEqualToString:@"stop"]) {
    LibretroSession *session = self.session;
    if (session == nil) {
      result(@{@"success" : @YES});
      return;
    }
    [session stopWithCompletion:^{
      result(@{@"success" : @YES});
    }];
    return;
  }
  NSDictionary *arguments = [call.arguments isKindOfClass:NSDictionary.class] ? call.arguments : @{};
  if ([call.method isEqualToString:@"frontendSettings"]) {
    [self frontendSettingsWithArguments:arguments result:result];
    return;
  }
  if ([call.method isEqualToString:@"setFrontendSetting"]) {
    [self setFrontendSettingWithArguments:arguments result:result];
    return;
  }
  if ([call.method isEqualToString:@"inspectSkin"]) {
    [self inspectSkinWithArguments:arguments result:result];
    return;
  }
  if ([call.method isEqualToString:@"skinPreview"]) {
    [self skinPreviewWithArguments:arguments result:result];
    return;
  }
  if ([call.method isEqualToString:@"forgetSkin"]) {
    [self forgetSkinWithArguments:arguments result:result];
    return;
  }
  if (![call.method isEqualToString:@"launch"]) {
    result(FlutterMethodNotImplemented);
    return;
  }
  [self launchWithArguments:arguments result:result];
}

#pragma mark - Frontend settings and skins (Flutter screens)

/// {directory, console} -> {"console": {...}, "games": {...}} as stored.
- (void)frontendSettingsWithArguments:(NSDictionary *)arguments result:(FlutterResult)result {
  NSString *directory = StringArgument(arguments, @"directory");
  NSString *console = StringArgument(arguments, @"console");
  if (!IsAbsolutePath(directory)) {
    result(InvalidArgument(@"directory"));
    return;
  }
  if (console.length == 0) {
    result(InvalidArgument(@"console"));
    return;
  }
  result([[LibretroFrontendStore storeWithDirectory:directory] snapshotForConsole:console]);
}

/// {directory, console, game|null, key, value|null} -> stored (a null value
/// removes the key at that scope). The native store is the only writer.
- (void)setFrontendSettingWithArguments:(NSDictionary *)arguments result:(FlutterResult)result {
  NSString *directory = StringArgument(arguments, @"directory");
  NSString *console = StringArgument(arguments, @"console");
  NSString *key = StringArgument(arguments, @"key");
  if (!IsAbsolutePath(directory)) {
    result(InvalidArgument(@"directory"));
    return;
  }
  if (console.length == 0 || key.length == 0) {
    result(InvalidArgument(console.length == 0 ? @"console" : @"key"));
    return;
  }
  LibretroFrontendStore *store = [LibretroFrontendStore storeWithDirectory:directory];
  BOOL stored = [store setValue:OptionalValueArgument(arguments, @"value")
                         forKey:key
                        console:console
                           game:OptionalStringArgument(arguments, @"game")];
  result(@(stored));
}

/// {directory, consoleGeometry} -> {ok: true, summary} or {ok: false,
/// error: SKIN_...}. Parsed off the main thread.
- (void)inspectSkinWithArguments:(NSDictionary *)arguments result:(FlutterResult)result {
  NSString *directory = StringArgument(arguments, @"directory");
  if (!IsAbsolutePath(directory)) {
    result(InvalidArgument(@"directory"));
    return;
  }
  NSDictionary<NSString *, NSDictionary *> *geometry = GeometryArgument(arguments, @"consoleGeometry");
  dispatch_async(LibretroChannelQueue(), ^{
    NSString *code = nil;
    LibretroSkin *skin = [LibretroSkin skinWithDirectory:directory consoleGeometry:geometry errorCode:&code];
    NSDictionary<NSString *, id> *reply = nil;
    if (skin != nil) {
      reply = @{@"ok" : @YES, @"summary" : [skin summary]};
    } else {
      reply = @{@"ok" : @NO, @"error" : code ?: LibretroSkinErrorInfoInvalid};
    }
    dispatch_async(dispatch_get_main_queue(), ^{
      result(reply);
    });
  });
}

/// {skinDirectory|null, console, orientation, width, height,
/// consoleGeometry, cacheDirectory, scale?} -> PNG bytes, or null when the
/// skin cannot be drawn in that orientation. A null skinDirectory is
/// NeoStation's default skin of the console, generated for width x height
/// points with typical safe areas.
- (void)skinPreviewWithArguments:(NSDictionary *)arguments result:(FlutterResult)result {
  NSString *skinDirectory = OptionalStringArgument(arguments, @"skinDirectory");
  NSString *console = StringArgument(arguments, @"console");
  NSString *orientationName = StringArgument(arguments, @"orientation");
  NSString *cacheDirectory = StringArgument(arguments, @"cacheDirectory");
  double width = NumberArgument(arguments, @"width");
  double height = NumberArgument(arguments, @"height");
  if (skinDirectory != nil && !IsAbsolutePath(skinDirectory)) {
    result(InvalidArgument(@"skinDirectory"));
    return;
  }
  if (console.length == 0) {
    result(InvalidArgument(@"console"));
    return;
  }
  if (![orientationName isEqualToString:@"portrait"] && ![orientationName isEqualToString:@"landscape"]) {
    result(InvalidArgument(@"orientation"));
    return;
  }
  if (!isfinite(width) || !isfinite(height) || width < 1 || height < 1 || width > 8192 || height > 8192) {
    result(InvalidArgument(@"size"));
    return;
  }
  if (!IsAbsolutePath(cacheDirectory)) {
    result(InvalidArgument(@"cacheDirectory"));
    return;
  }
  NSDictionary<NSString *, NSDictionary *> *geometry = GeometryArgument(arguments, @"consoleGeometry");
  double requestedScale = NumberArgument(arguments, @"scale");
  CGFloat scale = 0;
  if (isfinite(requestedScale) && requestedScale > 0 && requestedScale <= 4) {
    scale = requestedScale;
  } else {
    scale = LibretroRootViewController().view.window.screen.scale;
    if (scale <= 0) scale = 2;
  }
  LibretroSkinOrientation orientation = [orientationName isEqualToString:@"portrait"]
                                            ? LibretroSkinOrientationPortrait
                                            : LibretroSkinOrientationLandscape;
  BOOL iPad = UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad;
  LibretroInsets insets = PreviewSafeInsets(orientation, iPad);
  CGSize size = CGSizeMake(width, height);
  UIEdgeInsets safeInsets = UIEdgeInsetsMake(insets.top, insets.left, insets.bottom, insets.right);

  void (^render)(LibretroSkinRepresentation *) = ^(LibretroSkinRepresentation *representation) {
    if (representation == nil) {
      result(nil);
      return;
    }
    [LibretroSkinRenderer renderPreviewForRepresentation:representation
                                                    size:size
                                                   scale:scale
                                              safeInsets:safeInsets
                                          cacheDirectory:cacheDirectory
                                              completion:^(UIImage *image) {
                                                if (image == nil) {
                                                  result(nil);
                                                  return;
                                                }
                                                dispatch_async(LibretroChannelQueue(), ^{
                                                  NSData *png = UIImagePNGRepresentation(image);
                                                  dispatch_async(dispatch_get_main_queue(), ^{
                                                    result(png.length > 0 ? [FlutterStandardTypedData typedDataWithBytes:png]
                                                                          : nil);
                                                  });
                                                });
                                              }];
  };

  if (skinDirectory == nil) {
    NSDictionary *entry = geometry[console];
    NSDictionary *regions = [entry[@"regions"] isKindOfClass:NSDictionary.class] ? entry[@"regions"] : nil;
    render([LibretroDefaultSkins representationForConsole:console
                                              orientation:orientation
                                                 viewSize:(LibretroSize){width, height}
                                               safeInsets:insets
                                                     iPad:iPad
                                              arrangement:nil
                                                  swapped:NO
                                                  regions:regions]);
    return;
  }
  dispatch_async(LibretroChannelQueue(), ^{
    NSString *code = nil;
    LibretroSkin *skin = [LibretroSkin skinWithDirectory:skinDirectory consoleGeometry:geometry errorCode:&code];
    if (skin == nil) NSLog(@"[Libretro] skin preview unavailable for %@: %@", skinDirectory, code);
    LibretroSkinRepresentation *representation = [skin representationForOrientation:orientation
                                                                               iPad:iPad
                                                                         edgeToEdge:insets.bottom > 0];
    dispatch_async(dispatch_get_main_queue(), ^{
      render(representation);
    });
  });
}

/// {directory, skinId, skinDirectory, cacheDirectory} -> true once the
/// skin's selections, remaps and layouts are removed from every console
/// file and its cached images are purged (before Dart deletes the skin).
- (void)forgetSkinWithArguments:(NSDictionary *)arguments result:(FlutterResult)result {
  NSString *directory = StringArgument(arguments, @"directory");
  NSString *skinId = StringArgument(arguments, @"skinId");
  NSString *skinDirectory = StringArgument(arguments, @"skinDirectory");
  NSString *cacheDirectory = StringArgument(arguments, @"cacheDirectory");
  if (!IsAbsolutePath(directory)) {
    result(InvalidArgument(@"directory"));
    return;
  }
  if (!LibretroSkinIdentifierIsValid(skinId)) {
    result(InvalidArgument(@"skinId"));
    return;
  }
  if (!IsAbsolutePath(skinDirectory) || !IsAbsolutePath(cacheDirectory)) {
    result(InvalidArgument(IsAbsolutePath(skinDirectory) ? @"cacheDirectory" : @"skinDirectory"));
    return;
  }
  dispatch_async(LibretroChannelQueue(), ^{
    [[LibretroFrontendStore storeWithDirectory:directory] forgetSkin:skinId];
    dispatch_async(dispatch_get_main_queue(), ^{
      [LibretroSkinRenderer purgeCacheForSkinDirectory:skinDirectory cacheDirectory:cacheDirectory];
      result(@YES);
    });
  });
}

#pragma mark - Launch

- (void)launchWithArguments:(NSDictionary *)arguments result:(FlutterResult)result {
  if (self.session != nil || self.launching) {
    result(Failure(@"LIBRETRO_SESSION_ACTIVE", @"A libretro session is already active."));
    return;
  }
  NSString *coreId = StringArgument(arguments, @"coreId");
  NSCharacterSet *invalid =
      [[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyz0123456789_"] invertedSet];
  if (coreId.length == 0 || [coreId rangeOfCharacterFromSet:invalid].location != NSNotFound) {
    result(Failure(@"LIBRETRO_CORE_MISSING", coreId));
    return;
  }
  NSString *corePath = [LibretroInternalBridgePlugin corePathForIdentifier:coreId];
  if (![NSFileManager.defaultManager isReadableFileAtPath:corePath]) {
    result(Failure(@"LIBRETRO_CORE_MISSING", corePath));
    return;
  }
  NSString *contentPath = StringArgument(arguments, @"contentPath");
  if (![contentPath hasPrefix:@"/"] || ![NSFileManager.defaultManager isReadableFileAtPath:contentPath]) {
    result(Failure(@"LIBRETRO_GAME_UNREADABLE", contentPath));
    return;
  }
  NSArray<NSString *> *directoryKeys = @[
    @"systemDirectory", @"saveDirectory", @"stateDirectory", @"optionsDirectory", @"cheatsDirectory",
    @"cacheDirectory", @"skinsDirectory", @"frontendDirectory"
  ];
  for (NSString *key in directoryKeys) {
    if (![StringArgument(arguments, key) hasPrefix:@"/"]) {
      result(Failure(@"LIBRETRO_INVALID_REQUEST", key));
      return;
    }
  }
  // NeoStation console: key of the frontend settings file and of the skins.
  NSString *console = StringArgument(arguments, @"console");
  if (console.length == 0 || [console rangeOfCharacterFromSet:invalid].location != NSNotFound) {
    result(Failure(@"LIBRETRO_INVALID_REQUEST", @"console"));
    return;
  }
  NSDictionary *uiText = [arguments[@"uiText"] isKindOfClass:NSDictionary.class] ? arguments[@"uiText"] : @{};
  for (NSString *key in LibretroRequiredUIText()) {
    id value = uiText[key];
    if (![value isKindOfClass:NSString.class] || [value length] == 0) {
      result(Failure(@"LIBRETRO_UI_TEXT_MISSING", key));
      return;
    }
  }
  UIViewController *root = LibretroRootViewController();
  if (root == nil || root.view.window == nil) {
    result(Failure(@"LIBRETRO_HOST_VIEW_MISSING", @"No foreground window."));
    return;
  }
  [LibretroInternalBridgePlugin installBundledSystemFilesInto:StringArgument(arguments, @"systemDirectory")];

  LibretroSessionConfiguration *configuration = [LibretroSessionConfiguration new];
  configuration.corePath = corePath;
  configuration.contentPath = contentPath;
  configuration.gameTitle = StringArgument(arguments, @"gameTitle");
  configuration.console = console;
  configuration.consoleName = StringArgument(arguments, @"consoleName");
  configuration.gameKey = StringArgument(arguments, @"gameKey");
  configuration.skinsDirectory = StringArgument(arguments, @"skinsDirectory");
  configuration.frontendDirectory = StringArgument(arguments, @"frontendDirectory");
  configuration.consoleGeometry = GeometryArgument(arguments, @"consoleGeometry");
  configuration.lockedOptions = StringDictionaryArgument(arguments, @"lockedOptions");
  configuration.systemDirectory = StringArgument(arguments, @"systemDirectory");
  configuration.saveDirectory = StringArgument(arguments, @"saveDirectory");
  configuration.stateDirectory = StringArgument(arguments, @"stateDirectory");
  configuration.optionsDirectory = StringArgument(arguments, @"optionsDirectory");
  configuration.cheatsDirectory = StringArgument(arguments, @"cheatsDirectory");
  configuration.cacheDirectory = StringArgument(arguments, @"cacheDirectory");
  configuration.uiLocale = StringArgument(arguments, @"uiLocale");
  configuration.retroLanguage = [arguments[@"retroLanguage"] isKindOfClass:NSNumber.class]
                                    ? [arguments[@"retroLanguage"] unsignedIntValue]
                                    : 0;
  configuration.uiText = uiText;
  configuration.optionDefaults =
      [arguments[@"optionDefaults"] isKindOfClass:NSDictionary.class] ? arguments[@"optionDefaults"] : @{};
  configuration.noJitOverrides =
      [arguments[@"noJitOverrides"] isKindOfClass:NSDictionary.class] ? arguments[@"noJitOverrides"] : @{};
  configuration.coreSettings =
      [arguments[@"coreSettings"] isKindOfClass:NSArray.class] ? arguments[@"coreSettings"] : @[];
  configuration.achievementsAllowed = [arguments[@"achievementsAllowed"] boolValue];
  configuration.achievementsConsoleId = [arguments[@"achievementsConsoleId"] isKindOfClass:NSNumber.class]
                                            ? [arguments[@"achievementsConsoleId"] unsignedIntValue]
                                            : 0;
  configuration.preferredHardwareContext = [arguments[@"preferredHardwareContext"] isKindOfClass:NSNumber.class]
                                               ? [arguments[@"preferredHardwareContext"] unsignedIntValue]
                                               : 0;

  LibretroSession *session = [[LibretroSession alloc] initWithConfiguration:configuration];
  __weak LibretroInternalBridgePlugin *weakSelf = self;
  __weak LibretroSession *weakSession = session;
  session.endedHandler = ^{
    LibretroInternalBridgePlugin *plugin = weakSelf;
    if (plugin == nil) return;
    plugin.lastLog = weakSession.recentLog ?: @[];
    if (plugin.session == weakSession) plugin.session = nil;
    [plugin.channel invokeMethod:@"sessionEnded" arguments:@{@"reason" : @"user_exit", @"success" : @YES}];
  };
  self.session = session;
  self.launching = YES;
  [session startFromViewController:root
                        completion:^(NSDictionary<NSString *, id> *launch) {
                          LibretroInternalBridgePlugin *plugin = weakSelf;
                          plugin.launching = NO;
                          if (![launch[@"success"] boolValue]) {
                            plugin.lastLog = launch[@"log"] ?: @[];
                            if (plugin.session == session) plugin.session = nil;
                          }
                          result(launch);
                        }];
}

@end
