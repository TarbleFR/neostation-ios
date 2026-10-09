#import "LibretroInternalBridgePlugin.h"

#import "LibretroJit.h"
#import "LibretroSession.h"

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
  if (![call.method isEqualToString:@"launch"]) {
    result(FlutterMethodNotImplemented);
    return;
  }
  [self launchWithArguments:[call.arguments isKindOfClass:NSDictionary.class] ? call.arguments : @{} result:result];
}

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
    @"cacheDirectory"
  ];
  for (NSString *key in directoryKeys) {
    if (![StringArgument(arguments, key) hasPrefix:@"/"]) {
      result(Failure(@"LIBRETRO_INVALID_REQUEST", key));
      return;
    }
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
  configuration.profile = StringArgument(arguments, @"profile");
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
