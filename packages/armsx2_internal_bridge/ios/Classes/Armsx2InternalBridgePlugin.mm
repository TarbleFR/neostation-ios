#import "Armsx2InternalBridgePlugin.h"
#import "Armsx2JitBridgePlugin.h"
#import "ARMSX2CoreABI.h"

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <os/lock.h>

static NSString* const kARMSX2Channel = @"neostation/armsx2_internal";
static const uint32_t kARMSX2ExpectedABI = NEO_ARMSX2_ABI_VERSION;

static UIViewController* ARMSX2RootViewController(void) {
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
  while (controller.presentedViewController) controller = controller.presentedViewController;
  return controller;
}

@interface Armsx2GameViewController : UIViewController
@property(nonatomic, assign) const NeoARMSX2API* api;
@property(nonatomic, assign) UIView* coreView;
@property(nonatomic, copy) dispatch_block_t closeHandler;
@end

@implementation Armsx2GameViewController
- (instancetype)init {
  self = [super init];
  if (self) {
    self.modalPresentationStyle = UIModalPresentationFullScreen;
    self.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
  }
  return self;
}
- (void)loadView {
  UIView* root = [[UIView alloc] initWithFrame:UIScreen.mainScreen.bounds];
  root.backgroundColor = UIColor.blackColor;
  self.view = root;
  char error[512] = {};
  void* raw = self.api ? self.api->create_render_view(error, sizeof(error)) : NULL;
  if (raw) {
    UIView* render = (__bridge UIView*)raw;
    render.frame = root.bounds;
    render.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [root addSubview:render];
    self.coreView = render;
  }
  UIButton* close = [UIButton buttonWithType:UIButtonTypeSystem];
  close.translatesAutoresizingMaskIntoConstraints = NO;
  close.tintColor = UIColor.whiteColor;
  close.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
  close.layer.cornerRadius = 18;
  close.accessibilityLabel = @"Close ARMSX2";
  [close setImage:[UIImage systemImageNamed:@"xmark"] forState:UIControlStateNormal];
  [close addTarget:self action:@selector(closePressed) forControlEvents:UIControlEventTouchUpInside];
  [root addSubview:close];
  [NSLayoutConstraint activateConstraints:@[
    [close.leadingAnchor constraintEqualToAnchor:root.safeAreaLayoutGuide.leadingAnchor constant:12],
    [close.topAnchor constraintEqualToAnchor:root.safeAreaLayoutGuide.topAnchor constant:12],
    [close.widthAnchor constraintEqualToConstant:44],
    [close.heightAnchor constraintEqualToConstant:44],
  ]];
}
- (void)closePressed { if (self.closeHandler) self.closeHandler(); }
@end

@interface Armsx2InternalBridgePlugin ()
@property(nonatomic, strong) FlutterMethodChannel* channel;
@property(nonatomic, strong) Armsx2GameViewController* gameController;
@property(nonatomic, assign) void* coreHandle;
@property(nonatomic, assign) const NeoARMSX2API* api;
@property(nonatomic, assign) BOOL operationBusy;
@end

@implementation Armsx2InternalBridgePlugin {
  dispatch_queue_t _runtimeQueue;
}

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar {
  FlutterMethodChannel* channel = [FlutterMethodChannel
      methodChannelWithName:kARMSX2Channel
            binaryMessenger:registrar.messenger];
  Armsx2InternalBridgePlugin* instance = [Armsx2InternalBridgePlugin new];
  instance.channel = channel;
  [registrar addMethodCallDelegate:instance channel:channel];
  [Armsx2JitBridgePlugin registerWithRegistrar:registrar];
}

- (instancetype)init {
  self = [super init];
  if (self) {
    _runtimeQueue = dispatch_queue_create(
        "com.neogamelab.neostation.armsx2.runtime",
        DISPATCH_QUEUE_SERIAL);
  }
  return self;
}

- (NSString*)corePath {
  NSString* frameworks = NSBundle.mainBundle.privateFrameworksPath ?: @"";
  return [frameworks stringByAppendingPathComponent:@"ARMSX2Core.framework/ARMSX2Core"];
}

- (NSString*)resourcePath {
  NSString* frameworkPath = [[self corePath] stringByDeletingLastPathComponent];
  NSBundle* bundle = [NSBundle bundleWithPath:frameworkPath];
  return bundle.resourcePath ?: frameworkPath;
}

- (BOOL)loadCore:(NSString**)error {
  if (self.api != NULL) return YES;
  if (@available(iOS 26.0, *)) {
    if (!ARMSX2JitConfirmCoreLoadHandoff()) {
      if (error) *error = @"ARMSX2 debugger nonce proof failed at the Core load boundary.";
      return NO;
    }
  }
  NSString* path = [self corePath];
  if (![NSFileManager.defaultManager isReadableFileAtPath:path]) {
    if (error) *error = [NSString stringWithFormat:@"Embedded ARMSX2 Core is missing: %@", path];
    return NO;
  }
  dlerror();
  void* handle = dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
  if (!handle) {
    const char* detail = dlerror();
    if (error) *error = [NSString stringWithFormat:@"ARMSX2 Core dlopen failed: %s", detail ?: "unknown"];
    return NO;
  }
  auto getAPI = reinterpret_cast<NeoARMSX2GetAPI>(dlsym(handle, "NeoARMSX2_GetAPI"));
  const NeoARMSX2API* api = getAPI ? getAPI(kARMSX2ExpectedABI) : NULL;
  if (!api || api->version != kARMSX2ExpectedABI ||
      api->size < sizeof(NeoARMSX2API) || !api->prepare ||
      !api->request_jit_detach || !api->validate_jit || !api->boot) {
    if (error) *error = @"Embedded ARMSX2 Core ABI is incompatible.";
    return NO;
  }
  self.coreHandle = handle; // Intentionally process-lifetime; never dlclose Objective-C classes.
  self.api = api;
  return YES;
}

- (void)dismissGameController {
  Armsx2GameViewController* controller = self.gameController;
  self.gameController = nil;
  if (controller) {
    [controller dismissViewControllerAnimated:NO completion:nil];
  }
  if (self.api && self.api->release_render_view) self.api->release_render_view();
}

- (void)failTransaction:(NSString*)message result:(FlutterResult)result {
  if (self.api) {
    char ignored[256] = {};
    self.api->request_stop();
    self.api->shutdown(30000, ignored, sizeof(ignored));
  }
  ARMSX2JitAbortTransaction();
  self.operationBusy = NO;
  dispatch_async(dispatch_get_main_queue(), ^{
    [self dismissGameController];
    result(@{@"success": @NO, @"message": message ?: @"ARMSX2 launch failed."});
  });
}

- (void)handleMethodCall:(FlutterMethodCall*)call result:(FlutterResult)result {
  if ([call.method isEqualToString:@"diagnostics"]) {
    NSString* path = [self corePath];
    result(@{
      @"corePresent": @([NSFileManager.defaultManager isReadableFileAtPath:path]),
      @"coreLoaded": @(self.api != NULL),
      @"busy": @(self.operationBusy),
      @"abi": @(self.api ? self.api->version : 0),
      @"sourceRevision": self.api && self.api->source_revision
          ? [NSString stringWithUTF8String:self.api->source_revision] : @"",
    });
    return;
  }

  if ([call.method isEqualToString:@"stop"]) {
    dispatch_async(_runtimeQueue, ^{
      BOOL ok = YES;
      NSString* message = @"";
      if (self.api) {
        char error[512] = {};
        self.api->request_stop();
        ok = self.api->shutdown(30000, error, sizeof(error)) != 0;
        if (!ok && error[0]) message = [NSString stringWithUTF8String:error] ?: @"";
      }
      ARMSX2JitAbortTransaction();
      self.operationBusy = NO;
      dispatch_async(dispatch_get_main_queue(), ^{
        [self dismissGameController];
        result(@{@"success": @(ok), @"message": message});
      });
    });
    return;
  }

  if (![call.method isEqualToString:@"launch"]) {
    result(FlutterMethodNotImplemented);
    return;
  }

  if (self.operationBusy) {
    result(@{@"success": @NO, @"message": @"An ARMSX2 transaction is already active."});
    return;
  }
  NSDictionary* args = [call.arguments isKindOfClass:NSDictionary.class] ? call.arguments : @{};
  NSNumber* transactionNumber = [args[@"transaction"] isKindOfClass:NSNumber.class] ? args[@"transaction"] : nil;
  NSString* gamePath = [args[@"gamePath"] isKindOfClass:NSString.class] ? args[@"gamePath"] : @"";
  NSString* dataPath = [args[@"dataPath"] isKindOfClass:NSString.class] ? args[@"dataPath"] : @"";
  NSString* biosDirectory = [args[@"biosDirectory"] isKindOfClass:NSString.class] ? args[@"biosDirectory"] : @"";
  NSString* biosFilename = [args[@"biosFilename"] isKindOfClass:NSString.class] ? args[@"biosFilename"] : @"";
  if (!transactionNumber || transactionNumber.unsignedLongLongValue == 0 ||
      ![gamePath hasPrefix:@"/"] || ![dataPath hasPrefix:@"/"] ||
      ![biosDirectory hasPrefix:@"/"]) {
    result(@{@"success": @NO, @"message": @"Invalid ARMSX2 launch parameters."});
    return;
  }
  if (![NSFileManager.defaultManager isReadableFileAtPath:gamePath]) {
    result(@{@"success": @NO, @"message": @"The selected PS2 game is not readable."});
    return;
  }

  self.operationBusy = YES;
  dispatch_async(_runtimeQueue, ^{
    NSString* loadError = nil;
    if (![self loadCore:&loadError]) {
      [self failTransaction:loadError result:result];
      return;
    }

    __block Armsx2GameViewController* controller = nil;
    dispatch_sync(dispatch_get_main_queue(), ^{
      UIViewController* root = ARMSX2RootViewController();
      if (!root || root.view.window == nil) return;
      controller = [Armsx2GameViewController new];
      controller.api = self.api;
      __weak Armsx2InternalBridgePlugin* weakSelf = self;
      controller.closeHandler = ^{ [weakSelf handleMethodCall:
          [FlutterMethodCall methodCallWithMethodName:@"stop" arguments:nil]
          result:^(id _){}]; };
      [controller loadViewIfNeeded];
      if (!controller.coreView) { controller = nil; return; }
      [root presentViewController:controller animated:NO completion:nil];
      self.gameController = controller;
    });
    if (!controller) {
      [self failTransaction:@"ARMSX2 render view could not be created." result:result];
      return;
    }

    NSFileManager* fm = NSFileManager.defaultManager;
    [fm createDirectoryAtPath:dataPath withIntermediateDirectories:YES attributes:nil error:nil];

    char error[2048] = {};
    NeoARMSX2Configuration config = {};
    config.size = sizeof(config);
    config.transaction = transactionNumber.unsignedLongLongValue;
    config.data_directory = dataPath.fileSystemRepresentation;
    NSString* resources = [self resourcePath];
    config.resource_directory = resources.fileSystemRepresentation;
    config.bios_directory = biosDirectory.fileSystemRepresentation;
    config.bios_filename = biosFilename.length ? biosFilename.fileSystemRepresentation : "";
    config.event = NULL;
    config.context = NULL;

    if (!self.api->prepare(&config, 120000, error, sizeof(error))) {
      NSString* message = error[0] ? [NSString stringWithUTF8String:error] : @"ARMSX2 Core preparation failed.";
      [self failTransaction:message result:result];
      return;
    }
    memset(error, 0, sizeof(error));
    if (!self.api->request_jit_detach(error, sizeof(error))) {
      NSString* message = error[0] ? [NSString stringWithUTF8String:error] : @"ARMSX2 debugger detach request failed.";
      [self failTransaction:message result:result];
      return;
    }

    NSString* detachMessage = nil;
    if (!ARMSX2JitWaitForDetach(120.0, &detachMessage)) {
      [self failTransaction:detachMessage ?: @"ARMSX2 helper did not confirm debugger detach." result:result];
      return;
    }

    memset(error, 0, sizeof(error));
    if (!self.api->validate_jit(error, sizeof(error))) {
      NSString* message = error[0] ? [NSString stringWithUTF8String:error] : @"ARMSX2 post-detach JIT validation failed.";
      [self failTransaction:message result:result];
      return;
    }

    NSString* ext = gamePath.pathExtension.lowercaseString;
    uint32_t kind = [ext isEqualToString:@"elf"] ? NEO_ARMSX2_BOOT_ELF : NEO_ARMSX2_BOOT_DISC;
    memset(error, 0, sizeof(error));
    if (!self.api->boot(gamePath.fileSystemRepresentation, kind, 120000, error, sizeof(error))) {
      NSString* message = error[0] ? [NSString stringWithUTF8String:error] : @"ARMSX2 boot failed.";
      [self failTransaction:message result:result];
      return;
    }

    self.operationBusy = NO;
    NSString* revision = self.api->source_revision
        ? [NSString stringWithUTF8String:self.api->source_revision] : @"";
    dispatch_async(dispatch_get_main_queue(), ^{
      result(@{
        @"success": @YES,
        @"transaction": transactionNumber,
        @"bootKind": kind == NEO_ARMSX2_BOOT_ELF ? @"elf" : @"disc",
        @"sourceRevision": revision ?: @"",
        @"message": @"ARMSX2 entered Running.",
      });
    });
  });
}

@end
