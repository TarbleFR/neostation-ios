#import "DusklightInternalBridgePlugin.h"
#import "DusklightCoreABI.h"

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
  };
}
}  // namespace

@implementation DusklightInternalBridgePlugin {
  void* _coreHandle;
  const NeoDusklightAPI* _api;
}

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar {
  FlutterMethodChannel* channel =
      [FlutterMethodChannel methodChannelWithName:kChannel
                                  binaryMessenger:registrar.messenger];
  DusklightInternalBridgePlugin* instance =
      [[DusklightInternalBridgePlugin alloc] init];
  [registrar addMethodCallDelegate:instance channel:channel];
}

- (NSDictionary*)diagnostics {
  NSString* path = CorePath();
  BOOL present = path.length > 0 &&
      [NSFileManager.defaultManager isExecutableFileAtPath:path];
  return @{
    @"hostReady" : @YES,
    @"corePresent" : @(present),
    @"coreLoaded" : @(_api != nullptr),
    @"corePath" : path,
    @"abiVersion" : @(NEO_DUSKLIGHT_ABI_VERSION),
  };
}

- (NSDictionary*)loadCore {
  if (_api != nullptr) return nil;
  NSString* path = CorePath();
  if (path.length == 0 ||
      ![NSFileManager.defaultManager isExecutableFileAtPath:path]) {
    return Failure(
        @"DUSKLIGHT_CORE_NOT_READY",
        @"core_missing",
        @"DusklightCore is not included in this build yet.");
  }

  _coreHandle = dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
  if (_coreHandle == nullptr) {
    const char* raw = dlerror();
    NSString* detail = raw != nullptr
        ? [NSString stringWithUTF8String:raw]
        : @"Unknown loader error.";
    return Failure(@"DUSKLIGHT_CORE_LOAD_FAILED", @"dlopen", detail);
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
      _api->is_running == nullptr) {
    _api = nullptr;
    dlclose(_coreHandle);
    _coreHandle = nullptr;
    return Failure(
        @"DUSKLIGHT_ABI_MISMATCH",
        @"abi",
        @"DusklightCore does not expose the NeoStation ABI v1 contract.");
  }
  return nil;
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
  if (_api->is_running()) {
    result(Failure(@"DUSKLIGHT_SESSION_ACTIVE", @"session",
                   @"A Dusklight session is already active."));
    return;
  }

  char error[1024] = {};
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
  if (!_api->start(gamePath.fileSystemRepresentation,
                   (__bridge void*)controller.view,
                   error, sizeof(error))) {
    NSString* message = error[0] != '\0'
        ? [NSString stringWithUTF8String:error]
        : @"DusklightCore could not start the selected disc.";
    result(Failure(@"DUSKLIGHT_START_FAILED", @"start", message));
    return;
  }
  result(@{@"success" : @YES, @"stage" : @"running"});
}

- (void)dealloc {
  if (_api != nullptr && _api->is_running()) _api->stop();
  _api = nullptr;
  if (_coreHandle != nullptr) dlclose(_coreHandle);
}

@end
