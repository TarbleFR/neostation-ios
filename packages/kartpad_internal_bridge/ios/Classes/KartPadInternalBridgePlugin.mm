#import "KartPadInternalBridgePlugin.h"
#import "KartPadCoreABI.h"
#include "KartPadCoreLoader.h"

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>

#include <cstring>

namespace {
NSString* const kChannel = @"neostation/kartpad_internal";

NSString* CorePath() {
  NSString* frameworks = NSBundle.mainBundle.privateFrameworksPath;
  if (frameworks.length == 0) return @"";
  return [frameworks stringByAppendingPathComponent:
      @"KartPadCore.framework/KartPadCore"];
}

UIViewController* ActiveViewController() {
  UIWindow* keyWindow = nil;
  for (UIScene* scene in UIApplication.sharedApplication.connectedScenes) {
    if (![scene isKindOfClass:UIWindowScene.class] ||
        scene.activationState != UISceneActivationStateForegroundActive) continue;
    for (UIWindow* window in ((UIWindowScene*)scene).windows) {
      if (window.isKeyWindow) { keyWindow = window; break; }
    }
    if (keyWindow) break;
  }
  UIViewController* controller = keyWindow.rootViewController;
  while (controller.presentedViewController) {
    controller = controller.presentedViewController;
  }
  return controller;
}

NSDictionary* Failure(NSString* code, NSString* stage, NSString* message) {
  return @{
    @"success": @NO,
    @"errorCode": code,
    @"stage": stage,
    @"message": message,
    @"buildNumber": [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"unknown",
    @"corePath": CorePath(),
  };
}
}

@interface KartPadInternalBridgePlugin ()
- (void)coreState:(int)state message:(NSString*)message;
@end

static void OnCoreEvent(void* context, int state, const char* message) {
  KartPadInternalBridgePlugin* plugin =
      (__bridge KartPadInternalBridgePlugin*)context;
  [plugin coreState:state
            message:message ? [NSString stringWithUTF8String:message] : @""];
}

@implementation KartPadInternalBridgePlugin {
  void* _coreHandle;
  const NeoKartPadAPI* _api;
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
  KartPadInternalBridgePlugin* instance = [[KartPadInternalBridgePlugin alloc] init];
  instance->_channel = channel;
  [registrar addMethodCallDelegate:instance channel:channel];
}

- (NSDictionary*)diagnostics {
  NSString* path = CorePath();
  BOOL present = NeoKartPadCoreFilePresent(path.fileSystemRepresentation);
  const char* identity =
      (_api && _api->runtime_identity) ? _api->runtime_identity() : nullptr;
  return @{
    @"hostReady": @YES,
    @"corePresent": @(present),
    @"coreLoaded": @(_api != nullptr),
    @"corePath": path,
    @"buildNumber": [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"unknown",
    @"abiVersion": @(NEO_KARTPAD_ABI_VERSION),
    @"runtimeIdentity": identity ? [NSString stringWithUTF8String:identity] : @"",
    @"sessionState": @(_api ? _api->session_state() : NEO_KARTPAD_IDLE),
    @"restartRequired": @(_api && _api->session_state() == NEO_KARTPAD_ENDED),
  };
}

- (NSDictionary*)loadCore {
  if (_api) return nil;
  if (_loadError) return _loadError;

  NSString* path = CorePath();
  const auto loaded = NeoKartPadLoadCore(path.fileSystemRepresentation);
  _coreHandle = loaded.handle;
  if (!_coreHandle) {
    NSString* detail = [NSString stringWithUTF8String:loaded.detail.c_str()];
    return Failure(loaded.filePresent ? @"KARTPAD_CORE_LOAD_FAILED"
                                      : @"KARTPAD_CORE_NOT_READY",
                   loaded.filePresent ? @"dlopen" : @"core_missing", detail);
  }

  auto getter = reinterpret_cast<NeoKartPadGetAPIFn>(
      dlsym(_coreHandle, "NeoKartPad_GetAPI"));
  _api = getter ? getter() : nullptr;
  if (!_api ||
      _api->abi_version != NEO_KARTPAD_ABI_VERSION ||
      _api->struct_size < sizeof(NeoKartPadAPI) ||
      !_api->initialize || !_api->start || !_api->stop ||
      !_api->is_running || !_api->set_event_callback ||
      !_api->session_state || !_api->set_ui_text || !_api->runtime_identity) {
    _api = nullptr;
    _loadError = Failure(@"KARTPAD_ABI_MISMATCH", @"abi",
                         @"KartPadCore does not expose the NeoStation ABI v1 contract.");
    return _loadError;
  }

  const char* identity = _api->runtime_identity();
  if (!identity || std::strcmp(identity, NEO_KARTPAD_RUNTIME_IDENTITY) != 0) {
    _api = nullptr;
    _loadError = Failure(
        @"KARTPAD_RUNTIME_PROFILE_MISMATCH", @"identity",
        @"KartPadCore is not the validated full RMCP01 game runtime.");
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
  NSLog(@"[NeoStation/KartPad] state=%d %@", state, message);
  if (state == NEO_KARTPAD_RUNNING) {
    [self resolveLaunch:@{@"success": @YES, @"stage": @"first_frame",
                         @"message": message, @"transaction": @(_transaction)}];
    return;
  }
  if (state == NEO_KARTPAD_IDLE || state == NEO_KARTPAD_ENDED) {
    BOOL hadSession = _sessionActive;
    _sessionActive = NO;
    [self resolveLaunch:Failure(@"KARTPAD_ENDED_BEFORE_FIRST_FRAME",
                                @"startup", message)];
    if (hadSession) {
      [_channel invokeMethod:@"sessionEnded" arguments:@{
        @"reason": message,
        @"restartRequired": @(state == NEO_KARTPAD_ENDED),
        @"runtimeReleased": @(state == NEO_KARTPAD_ENDED),
        @"transaction": @(_transaction),
      }];
    }
  }
}

- (void)handleMethodCall:(FlutterMethodCall*)call result:(FlutterResult)result {
  if ([call.method isEqualToString:@"diagnostics"]) {
    result([self diagnostics]);
    return;
  }
  if ([call.method isEqualToString:@"stop"]) {
    if (_api && _api->is_running()) _api->stop();
    result(@YES);
    return;
  }
  if (![call.method isEqualToString:@"launch"]) {
    result(FlutterMethodNotImplemented);
    return;
  }

  NSDictionary* args =
      [call.arguments isKindOfClass:NSDictionary.class] ? call.arguments : @{};
  NSString* gamePath =
      [args[@"gamePath"] isKindOfClass:NSString.class] ? args[@"gamePath"] : @"";
  NSString* supportPath =
      [args[@"supportPath"] isKindOfClass:NSString.class] ? args[@"supportPath"] : @"";
  NSString* cachePath =
      [args[@"cachePath"] isKindOfClass:NSString.class] ? args[@"cachePath"] : @"";

  if (!gamePath.length ||
      ![NSFileManager.defaultManager isReadableFileAtPath:gamePath]) {
    result(Failure(@"KARTPAD_GAME_UNREADABLE", @"input",
                   @"The selected Mario Kart Wii file is not readable."));
    return;
  }

  NSDictionary* loadFailure = [self loadCore];
  if (loadFailure) { result(loadFailure); return; }

  if (_sessionActive || _api->is_running()) {
    result(Failure(@"KARTPAD_SESSION_ACTIVE", @"session",
                   @"A KartPad session is already active."));
    return;
  }
  if (_api->session_state() == NEO_KARTPAD_ENDED) {
    result(Failure(@"KARTPAD_RESTART_REQUIRED", @"session",
                   @"The KartPad native runtime failed and is no longer reusable."));
    return;
  }

  NSDictionary* uiText =
      [args[@"uiText"] isKindOfClass:NSDictionary.class] ? args[@"uiText"] : @{};
  for (id rawKey in uiText) {
    if (![rawKey isKindOfClass:NSString.class]) continue;
    id rawValue = uiText[rawKey];
    if (![rawValue isKindOfClass:NSString.class]) continue;
    _api->set_ui_text([(NSString*)rawKey UTF8String],
                      [(NSString*)rawValue UTF8String]);
  }

  char error[1024] = {};
  if (!_api->initialize(supportPath.fileSystemRepresentation,
                        cachePath.fileSystemRepresentation,
                        error, sizeof(error))) {
    NSString* message = error[0]
        ? [NSString stringWithUTF8String:error]
        : @"KartPadCore initialization failed.";
    result(Failure(@"KARTPAD_INITIALIZE_FAILED", @"initialize", message));
    return;
  }

  UIViewController* controller = ActiveViewController();
  if (!controller || !controller.view) {
    result(Failure(@"KARTPAD_HOST_VIEW_MISSING", @"presentation",
                   @"NeoStation has no active host view."));
    return;
  }

  _pendingLaunch = [result copy];
  _transaction = [args[@"transaction"] isKindOfClass:NSNumber.class]
      ? [args[@"transaction"] integerValue] : _transaction + 1;
  _sessionActive = YES;
  const int started = _api->start(
      gamePath.fileSystemRepresentation, (__bridge void*)controller.view,
      error, sizeof(error));
  if (started <= 0) {
    NSString* message = error[0]
        ? [NSString stringWithUTF8String:error]
        : @"KartPadCore could not start Mario Kart Wii.";
    _sessionActive = NO;
    [self resolveLaunch:Failure(@"KARTPAD_START_FAILED", @"start", message)];
    return;
  }

  __weak KartPadInternalBridgePlugin* weakSelf = self;
  _startupTimer = [NSTimer timerWithTimeInterval:90 repeats:NO block:^(NSTimer*) {
    KartPadInternalBridgePlugin* strongSelf = weakSelf;
    if (!strongSelf || !strongSelf->_pendingLaunch) return;
    [strongSelf resolveLaunch:Failure(
        @"KARTPAD_FIRST_FRAME_TIMEOUT", @"first_frame",
        @"KartPad did not submit a frame within 90 seconds.")];
    strongSelf->_api->stop();
  }];
  [NSRunLoop.mainRunLoop addTimer:_startupTimer forMode:NSRunLoopCommonModes];
}

- (void)dealloc {
  [_startupTimer invalidate];
  if (_api) {
    _api->set_event_callback(nullptr, nullptr);
    if (_api->is_running()) _api->stop();
  }
  _api = nullptr;
  // Do not dlclose: Objective-C classes and native TLS may outlive a session.
}

@end
