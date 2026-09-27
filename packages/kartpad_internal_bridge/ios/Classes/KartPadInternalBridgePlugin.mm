#import "KartPadInternalBridgePlugin.h"
#import "KartPadCoreABI.h"
#include "KartPadCoreLoader.h"
#include "KartPadHostWindowPolicy.h"

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>

#include <cstring>

namespace {
NSString* const kChannel = @"neostation/kartpad_internal";

using NeoKartPadPrepareUserGameFn =
    int (*)(const char* game_path,
            const char* support_path,
            const char* cache_path,
            char* error,
            size_t error_size);

NSString* CorePath() {
  NSString* frameworks = NSBundle.mainBundle.privateFrameworksPath;
  if (frameworks.length == 0) return @"";
  return [frameworks stringByAppendingPathComponent:
      @"KartPadCore.framework/KartPadCore"];
}

UIView* ActiveHostView(UIViewController* flutterController) {
  NSMutableArray<UIView*>* views = [NSMutableArray array];
  std::vector<neokartpad::HostWindowCandidate> candidates;
  auto append = [&](UIViewController* controller, BOOL flutterOwned) {
    // isViewLoaded avoids creating a view just to decide whether it is ready.
    UIView* view = controller.isViewLoaded ? controller.view : nil;
    UIWindow* window = view.window;
    UIWindowScene* scene = window.windowScene;
    if (!view || !window || !scene) return;
    [views addObject:view];
    candidates.push_back({static_cast<bool>(flutterOwned), true,
                          !window.hidden && window.alpha > 0.01,
                          scene.activationState == UISceneActivationStateForegroundActive,
                          static_cast<bool>(window.isKeyWindow)});
  };

  // Flutter's registrar identifies its own view even when the donor SDL
  // window has not relinquished UIKit's key-window designation yet.
  append(flutterController, flutterController != nil);
  for (UIScene* scene in UIApplication.sharedApplication.connectedScenes) {
    if (![scene isKindOfClass:UIWindowScene.class] ||
        scene.activationState != UISceneActivationStateForegroundActive) continue;
    for (UIWindow* window in ((UIWindowScene*)scene).windows) {
      UIViewController* root = window.rootViewController;
      if (![root isKindOfClass:FlutterViewController.class] ||
          (flutterController && root == flutterController)) continue;
      append(root, YES);
    }
  }

  const int selected = neokartpad::SelectHostWindow(candidates);
  if (selected < 0) {
    NSLog(@"[NeoStation/KartPad] no attached foreground Flutter view (candidates=%lu)",
          (unsigned long)views.count);
    return nil;
  }
  UIView* host = views[static_cast<NSUInteger>(selected)];
  NSLog(@"[NeoStation/KartPad] selected Flutter host view (windowKey=%d, candidates=%lu)",
        host.window.isKeyWindow, (unsigned long)views.count);
  return host;
}

NSString* ExitReasonName(int reason) {
  switch (reason) {
    case NEO_KARTPAD_EXIT_USER_RETURN: return @"userReturn";
    case NEO_KARTPAD_EXIT_LANGUAGE_RESTART: return @"languageRestart";
    case NEO_KARTPAD_EXIT_NORMAL_TERMINATION: return @"normalTermination";
    case NEO_KARTPAD_EXIT_LAUNCH_FAILURE: return @"launchFailure";
    case NEO_KARTPAD_EXIT_RUNTIME_FAILURE: return @"runtimeFailure";
    case NEO_KARTPAD_EXIT_CRASH: return @"crash";
    default: return @"none";
  }
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
- (void)deliverSessionEndedForTransaction:(NSInteger)transaction
                               exitReason:(int)exitReason
                                  message:(NSString*)message
                                  success:(BOOL)success;
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
  NSInteger _activeTransaction;
  BOOL _launchCompletionDelivered;
  BOOL _terminationDelivered;
  __weak NSObject<FlutterPluginRegistrar>* _registrar;
}

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar {
  FlutterMethodChannel* channel =
      [FlutterMethodChannel methodChannelWithName:kChannel
                                  binaryMessenger:registrar.messenger];
  KartPadInternalBridgePlugin* instance = [[KartPadInternalBridgePlugin alloc] init];
  instance->_channel = channel;
  instance->_registrar = registrar;
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
      !_api->session_state || !_api->set_ui_text || !_api->runtime_identity ||
      !_api->last_exit_reason) {
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
  if (_launchCompletionDelivered) return;
  FlutterResult pending = _pendingLaunch;
  if (!pending) return;
  _launchCompletionDelivered = YES;
  [_startupTimer invalidate];
  _startupTimer = nil;
  _pendingLaunch = nil;
  pending(response);
}

- (void)deliverSessionEndedForTransaction:(NSInteger)transaction
                               exitReason:(int)exitReason
                                  message:(NSString*)message
                                  success:(BOOL)success {
  if (_terminationDelivered || transaction <= 0) return;
  _terminationDelivered = YES;
  NSString* reasonName = ExitReasonName(exitReason);
  NSLog(@"[NeoStation/KartPad] transaction=%ld hostResult=%@ success=%d",
        (long)transaction, reasonName, success);
  [_channel invokeMethod:@"sessionEnded" arguments:@{
    @"reason": message ?: @"",
    @"exitReason": reasonName,
    @"success": @(success),
    @"restartRequired": @(exitReason == NEO_KARTPAD_EXIT_RUNTIME_FAILURE ||
                           exitReason == NEO_KARTPAD_EXIT_CRASH),
    @"runtimeReleased": @YES,
    @"transaction": @(transaction),
  }];
}

- (void)coreState:(int)state message:(NSString*)message {
  const int exitReason = (_api && _api->last_exit_reason)
      ? _api->last_exit_reason() : NEO_KARTPAD_EXIT_NONE;
  NSLog(@"[NeoStation/KartPad] state=%d exitReason=%@ %@",
        state, ExitReasonName(exitReason), message);

  if (state == NEO_KARTPAD_RUNNING) {
    [self resolveLaunch:@{@"success": @YES, @"stage": @"first_frame",
                         @"message": message ?: @"",
                         @"transaction": @(_transaction)}];
    return;
  }

  if (state != NEO_KARTPAD_IDLE && state != NEO_KARTPAD_ENDED) return;

  const BOOL hadSession = _sessionActive;
  const NSInteger endedTransaction = _activeTransaction;

  _sessionActive = NO;
  _activeTransaction = 0;

  const BOOL cleanExit =
      exitReason == NEO_KARTPAD_EXIT_USER_RETURN ||
      exitReason == NEO_KARTPAD_EXIT_LANGUAGE_RESTART ||
      exitReason == NEO_KARTPAD_EXIT_NORMAL_TERMINATION;
  if (_pendingLaunch && !_launchCompletionDelivered) {
    if (cleanExit) {
      // A user can hit the native return control as soon as the window exists.
      // That is cancellation after successful native creation, never a launch
      // failure. Resolve success once, then deliver the normal end event.
      [self resolveLaunch:@{@"success": @YES,
                           @"stage": @"session_closed",
                           @"message": message ?: @"",
                           @"transaction": @(endedTransaction)}];
    } else {
      [self resolveLaunch:Failure(@"KARTPAD_ENDED_BEFORE_FIRST_FRAME",
                                  @"startup", message ?: @"KartPad ended before its first frame.")];
    }
  }

  if (hadSession && endedTransaction > 0) {
    [self deliverSessionEndedForTransaction:endedTransaction
                                 exitReason:(cleanExit ? exitReason :
                                   (exitReason == NEO_KARTPAD_EXIT_NONE
                                     ? NEO_KARTPAD_EXIT_RUNTIME_FAILURE : exitReason))
                                    message:message
                                    success:cleanExit];
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
  if ([call.method isEqualToString:@"prepareGame"]) {
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
      result(Failure(@"KARTPAD_GAME_UNREADABLE", @"prepare_input",
                     @"The selected Mario Kart Wii file is not readable."));
      return;
    }
    NSDictionary* loadFailure = [self loadCore];
    if (loadFailure) {
      result(loadFailure);
      return;
    }
    if (_sessionActive || _api->is_running()) {
      result(Failure(@"KARTPAD_SESSION_ACTIVE", @"prepare_session",
                     @"KartPad cannot prepare game data while a session is active."));
      return;
    }
    auto prepare = reinterpret_cast<NeoKartPadPrepareUserGameFn>(
        dlsym(_coreHandle, "NeoKartPad_PrepareUserGame"));
    if (!prepare) {
      result(Failure(@"KARTPAD_PREPARE_UNAVAILABLE", @"prepare_api",
                     @"This KartPad Core does not support direct compressed-image preparation."));
      return;
    }

    FlutterResult completion = [result copy];
    NSString* gameCopy = [gamePath copy];
    NSString* supportCopy = [supportPath copy];
    NSString* cacheCopy = [cachePath copy];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
      char error[1024] = {};
      const int prepared = prepare(
          gameCopy.fileSystemRepresentation,
          supportCopy.fileSystemRepresentation,
          cacheCopy.fileSystemRepresentation,
          error, sizeof(error));
      NSString* message = prepared > 0
          ? @"KartPad game data prepared."
          : (error[0] ? [NSString stringWithUTF8String:error]
                      : @"KartPad could not prepare the selected game image.");
      NSDictionary* response = prepared > 0
          ? @{@"success": @YES, @"stage": @"prepare", @"message": message}
          : Failure(@"KARTPAD_PREPARE_FAILED", @"prepare", message);
      dispatch_async(dispatch_get_main_queue(), ^{
        completion(response);
      });
    });
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

  UIView* hostView = ActiveHostView(_registrar.viewController);
  if (!hostView) {
    result(Failure(@"KARTPAD_HOST_VIEW_MISSING", @"presentation",
                   @"NeoStation has no active host view."));
    return;
  }

  _pendingLaunch = [result copy];
  _launchCompletionDelivered = NO;
  _terminationDelivered = NO;
  _transaction = [args[@"transaction"] isKindOfClass:NSNumber.class]
      ? [args[@"transaction"] integerValue] : _transaction + 1;
  _activeTransaction = _transaction;
  _sessionActive = YES;
  NSLog(@"[NeoStation/KartPad] transaction=%ld session launch accepted",
        (long)_activeTransaction);
  const int started = _api->start(
      gamePath.fileSystemRepresentation, (__bridge void*)hostView,
      error, sizeof(error));
  if (started <= 0) {
    NSString* message = error[0]
        ? [NSString stringWithUTF8String:error]
        : @"KartPadCore could not start Mario Kart Wii.";
    _sessionActive = NO;
    _activeTransaction = 0;
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
