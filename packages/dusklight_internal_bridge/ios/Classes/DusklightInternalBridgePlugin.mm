#import "DusklightInternalBridgePlugin.h"
#import "DusklightCoreABI.h"
#include "DusklightCoreLoader.h"

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>

namespace {
NSString* const kChannel = @"neostation/dusklight_internal";

NSString* CorePath() {
  NSString* frameworks = NSBundle.mainBundle.privateFrameworksPath;
  if (frameworks.length == 0) return @"";
  return [frameworks stringByAppendingPathComponent:
      @"DusklightCore.framework/DusklightCore"];
}

UIViewController* ActiveViewController() {
  UIWindow* keyWindow = nil;
  for (UIScene* scene in UIApplication.sharedApplication.connectedScenes) {
    if (![scene isKindOfClass:UIWindowScene.class] ||
        scene.activationState != UISceneActivationStateForegroundActive) {
      continue;
    }
    for (UIWindow* window in ((UIWindowScene*)scene).windows) {
      if (window.isKeyWindow) {
        keyWindow = window;
        break;
      }
    }
    if (keyWindow != nil) break;
  }
  UIViewController* controller = keyWindow.rootViewController;
  while (controller.presentedViewController != nil) {
    controller = controller.presentedViewController;
  }
  return controller;
}

NSDictionary* Failure(NSString* code, NSString* stage, NSString* message) {
  return @{
    @"success" : @NO,
    @"errorCode" : code,
    @"stage" : stage,
    @"message" : message,
    @"buildNumber" : [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"unknown",
    @"corePath" : CorePath(),
  };
}
}  // namespace

@interface DusklightInternalBridgePlugin ()
- (void)coreState:(int)state message:(NSString*)message;
@end

static void OnCoreEvent(void* context, int state, const char* message) {
  DusklightInternalBridgePlugin* plugin = (__bridge DusklightInternalBridgePlugin*)context;
  [plugin coreState:state message:message ? [NSString stringWithUTF8String:message] : @""];
}

@implementation DusklightInternalBridgePlugin {
  void* _coreHandle;
  const NeoDusklightAPI* _api;
  FlutterMethodChannel* _channel;
  FlutterResult _pendingLaunch;
  NSTimer* _startupTimer;
  BOOL _sessionActive;
  NSDictionary* _loadError;
  NSInteger _transaction;
}

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar {
  FlutterMethodChannel* channel =
      [FlutterMethodChannel methodChannelWithName:kChannel
                                  binaryMessenger:registrar.messenger];
  DusklightInternalBridgePlugin* instance =
      [[DusklightInternalBridgePlugin alloc] init];
  instance->_channel = channel;
  [registrar addMethodCallDelegate:instance channel:channel];
}

- (NSDictionary*)diagnostics {
  NSString* path = CorePath();
  BOOL present = NeoDusklightCoreFilePresent(path.fileSystemRepresentation);
  return @{
    @"hostReady" : @YES,
    @"corePresent" : @(present),
    @"coreLoaded" : @(_api != nullptr),
    @"corePath" : path,
    @"buildNumber" : [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"unknown",
    @"abiVersion" : @(NEO_DUSKLIGHT_ABI_VERSION),
    @"sessionState" : @(_api ? _api->session_state() : NEO_DUSKLIGHT_IDLE),
    @"restartRequired" : @(_api && _api->session_state() == NEO_DUSKLIGHT_ENDED),
  };
}

- (NSDictionary*)loadCore {
  if (_api != nullptr) return nil;
  if (_loadError != nil) return _loadError;
  NSString* path = CorePath();
  const auto loaded = NeoDusklightLoadCore(path.fileSystemRepresentation);
  _coreHandle = loaded.handle;
  if (_coreHandle == nullptr) {
    NSString* detail = [NSString stringWithUTF8String:loaded.detail.c_str()];
    NSLog(@"[NeoStation/Dusklight] build=%@ present=%d path=%@ loader=%@",
          [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleVersion"],
          loaded.filePresent, path, detail);
    return Failure(loaded.filePresent ? @"DUSKLIGHT_CORE_LOAD_FAILED" : @"DUSKLIGHT_CORE_NOT_READY",
                   loaded.filePresent ? @"dlopen" : @"core_missing", detail);
  }

  auto getter = reinterpret_cast<NeoDusklightGetAPIFn>(
      dlsym(_coreHandle, "NeoDusklight_GetAPI"));
  _api = getter != nullptr ? getter() : nullptr;
  if (_api == nullptr ||
      _api->abi_version != NEO_DUSKLIGHT_ABI_VERSION ||
      _api->struct_size < sizeof(NeoDusklightAPI) ||
      _api->initialize == nullptr ||
      _api->start == nullptr ||
      _api->stop == nullptr ||
      _api->is_running == nullptr ||
      _api->set_event_callback == nullptr ||
      _api->session_state == nullptr ||
      _api->set_ui_text == nullptr) {
    _api = nullptr;
    // Objective-C classes register at dlopen; keep the image mapped even on
    // ABI refusal rather than leaving class method pointers in unloaded code.
    _loadError = Failure(
        @"DUSKLIGHT_ABI_MISMATCH",
        @"abi",
        @"DusklightCore does not expose the NeoStation ABI v6 contract.");
    return _loadError;
  }
  _api->set_event_callback(OnCoreEvent, (__bridge void*)self);
  return nil;
}

- (void)resolveLaunch:(NSDictionary*)response {
  [_startupTimer invalidate];
  _startupTimer = nil;
  FlutterResult pending = _pendingLaunch;
  _pendingLaunch = nil;
  if (pending) pending(response);
}

- (void)coreState:(int)state message:(NSString*)message {
  NSLog(@"[NeoStation/Dusklight] state=%d %@", state, message);
  if (state == NEO_DUSKLIGHT_RUNNING) {
    [self resolveLaunch:@{@"success": @YES, @"stage": @"first_frame", @"message": message,
                         @"transaction": @(_transaction)}];
  } else if (state == NEO_DUSKLIGHT_ENDED || state == NEO_DUSKLIGHT_IDLE) {
    BOOL hadSession = _sessionActive;
    _sessionActive = NO;
    [self resolveLaunch:Failure(@"DUSKLIGHT_ENDED_BEFORE_FIRST_FRAME", @"startup", message)];
    if (hadSession) {
      [_channel invokeMethod:@"sessionEnded" arguments:@{
        @"reason": message, @"restartRequired": @(state == NEO_DUSKLIGHT_ENDED),
        @"runtimeReleased": @(state == NEO_DUSKLIGHT_ENDED),
        @"transaction": @(_transaction)
      }];
    }
  }
}

- (void)handleMethodCall:(FlutterMethodCall*)call
                  result:(FlutterResult)result {
  if ([call.method isEqualToString:@"diagnostics"]) {
    result([self diagnostics]);
    return;
  }

  if ([call.method isEqualToString:@"stop"]) {
    if (_api != nullptr && _api->is_running()) _api->stop();
    result(@YES);
    return;
  }

  if (![call.method isEqualToString:@"launch"]) {
    result(FlutterMethodNotImplemented);
    return;
  }

  NSDictionary* arguments = [call.arguments isKindOfClass:NSDictionary.class]
      ? call.arguments
      : @{};
  NSString* gamePath = [arguments[@"gamePath"] isKindOfClass:NSString.class]
      ? arguments[@"gamePath"]
      : @"";
  NSString* supportPath =
      [arguments[@"supportPath"] isKindOfClass:NSString.class]
      ? arguments[@"supportPath"]
      : @"";
  NSString* cachePath = [arguments[@"cachePath"] isKindOfClass:NSString.class]
      ? arguments[@"cachePath"]
      : @"";
  if (gamePath.length == 0 ||
      ![NSFileManager.defaultManager isReadableFileAtPath:gamePath]) {
    result(Failure(@"DUSKLIGHT_GAME_UNREADABLE", @"input",
                   @"The selected game file is not readable."));
    return;
  }

  NSDictionary* loadFailure = [self loadCore];
  if (loadFailure != nil) {
    result(loadFailure);
    return;
  }
  if (_sessionActive || _api->is_running()) {
    result(Failure(@"DUSKLIGHT_SESSION_ACTIVE", @"session",
                   @"A Dusklight session is already active."));
    return;
  }

  if (_api->session_state() == NEO_DUSKLIGHT_ENDED) {
    result(Failure(@"DUSKLIGHT_RESTART_REQUIRED", @"session",
                   @"The native runtime failed and is no longer reusable."));
    return;
  }

  char error[1024] = {};
  NSDictionary* uiText = [arguments[@"uiText"] isKindOfClass:NSDictionary.class] ? arguments[@"uiText"] : @{};
  for (NSString* key in @[@"nativeMenu", @"resumeGame", @"returnToLibrary", @"resumeHint", @"cancelReturn",
                          @"gameLanguage", @"gameLanguageHelp", @"languageEnglish", @"languageGerman",
                          @"languageFrench", @"languageSpanish", @"languageItalian", @"languageJapanese"]) {
    NSString* value = [uiText[key] isKindOfClass:NSString.class] ? uiText[key] : @"";
    if (value.length == 0) {
      result(Failure(@"DUSKLIGHT_INITIALIZE_FAILED", @"ui_text", @"Missing translated native UI label."));
      return;
    }
    _api->set_ui_text(key.UTF8String, value.UTF8String);
  }
  if (!_api->initialize(supportPath.fileSystemRepresentation,
                        cachePath.fileSystemRepresentation,
                        error, sizeof(error))) {
    NSString* message = error[0] != '\0'
        ? [NSString stringWithUTF8String:error]
        : @"DusklightCore initialization failed.";
    result(Failure(@"DUSKLIGHT_INITIALIZE_FAILED", @"initialize", message));
    return;
  }

  UIViewController* controller = ActiveViewController();
  if (controller == nil || controller.view == nil) {
    result(Failure(@"DUSKLIGHT_HOST_VIEW_MISSING", @"presentation",
                   @"NeoStation has no active host view."));
    return;
  }
  _pendingLaunch = [result copy];
  _transaction = [arguments[@"transaction"] isKindOfClass:NSNumber.class]
      ? [arguments[@"transaction"] integerValue] : _transaction + 1;
  _sessionActive = YES;
  const int started = _api->start(gamePath.fileSystemRepresentation,
                   (__bridge void*)controller.view,
                   error, sizeof(error));
  if (started <= 0) {
    NSString* message = error[0] != '\0'
        ? [NSString stringWithUTF8String:error]
        : @"DusklightCore could not start the selected disc.";
    _sessionActive = NO;
    [self resolveLaunch:Failure(started == NEO_DUSKLIGHT_DIFFERENT_DISC
        ? @"DUSKLIGHT_DIFFERENT_DISC" : @"DUSKLIGHT_START_FAILED", @"start", message)];
    return;
  }
  __weak DusklightInternalBridgePlugin* weakSelf = self;
  _startupTimer = [NSTimer timerWithTimeInterval:90 repeats:NO block:^(NSTimer*) {
    DusklightInternalBridgePlugin* strongSelf = weakSelf;
    if (!strongSelf || !strongSelf->_pendingLaunch) return;
    [strongSelf resolveLaunch:Failure(@"DUSKLIGHT_FIRST_FRAME_TIMEOUT", @"first_frame",
        @"Dusklight did not submit a frame for the current session within 90 seconds.")];
    // Retain ownership until the terminal native shutdown barrier completed.
    strongSelf->_api->stop();
  }];
  [NSRunLoop.mainRunLoop addTimer:_startupTimer forMode:NSRunLoopCommonModes];
}

- (void)dealloc {
  [_startupTimer invalidate];
  if (_api != nullptr) {
    _api->set_event_callback(nullptr, nullptr);
    if (_api->is_running()) _api->stop();
  }
  _api = nullptr;
  // Keep the native image mapped for its Objective-C classes and TLS lifetime.
}

@end
