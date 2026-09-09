#import "Rpcs3InternalBridgePlugin.h"
#import "Rpcs3JitBridgePlugin.h"
#import "Rpcs3CoreABI.h"
#import "Rpcs3Diagnostics.h"
#import "Rpcs3MemoryPreflight.h"

#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <Security/Security.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <errno.h>
#import <sys/mman.h>
#import <unistd.h>

static NSString* const kRpcs3Channel = @"neostation/rpcs3_internal";
static const uint32_t kExpectedAbi = 30;

extern "C" {
void* SecTaskCreateFromSelf(CFAllocatorRef allocator);
CFTypeRef SecTaskCopyValueForEntitlement(
    void* task,
    CFStringRef entitlement,
    CFErrorRef* error);
int csops(pid_t pid, unsigned int ops, void* useraddr, size_t usersize);
}

#ifndef CS_OPS_STATUS
#define CS_OPS_STATUS 0
#endif
#ifndef CS_DEBUGGED
#define CS_DEBUGGED 0x10000000
#endif

static BOOL RPCS3HostIsDebugged(void) {
  uint32_t flags = 0;
  if (csops(getpid(), CS_OPS_STATUS, &flags, sizeof(flags)) != 0) return NO;
  return (flags & CS_DEBUGGED) != 0;
}

static BOOL RPCS3HostHasEntitlement(CFStringRef entitlement) {
  void* task = SecTaskCreateFromSelf(NULL);
  if (task == NULL) return NO;
  CFTypeRef value = SecTaskCopyValueForEntitlement(task, entitlement, NULL);
  BOOL enabled = value == kCFBooleanTrue;
  if (value != NULL) CFRelease(value);
  CFRelease(task);
  return enabled;
}

// Only the legacy Core backend uses an ordinary RW -> RX transition. On
// iOS 26 the Core itself prepares RX pages through the attached Universal
// debugger and creates mirrored RW aliases; this legacy probe cannot test it.
static BOOL RPCS3ProbeExecutableMemory(NSString** error) {
  if (@available(iOS 26.0, *)) {
    if (RPCS3JitHasActiveCoreHandshake()) return YES;
    if (error) *error = @"RPCS3 requires a fresh Universal JIT attachment before loading its Core.";
    return NO;
  }
  size_t pageSize = (size_t)getpagesize();
  void* page = mmap(NULL,
                    pageSize,
                    PROT_READ | PROT_WRITE,
                    MAP_PRIVATE | MAP_ANON,
                    -1,
                    0);
  if (page == MAP_FAILED) {
    if (error) {
      *error = [NSString stringWithFormat:
          @"RPCS3 JIT readiness allocation failed (errno %d).", errno];
    }
    return NO;
  }

  ((volatile unsigned char*)page)[0] = 0;
  if (mprotect(page, pageSize, PROT_READ | PROT_EXEC) != 0) {
    int savedErrno = errno;
    munmap(page, pageSize);
    if (error) {
      *error = [NSString stringWithFormat:
          @"JIT is attached, but iOS rejected RPCS3 executable memory (errno %d).",
          savedErrno];
    }
    return NO;
  }

  // Restore writable permissions before releasing the test page.
  mprotect(page, pageSize, PROT_READ | PROT_WRITE);
  munmap(page, pageSize);
  return YES;
}

static UIViewController* RPCS3RootViewController(void) {
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

@interface RPCS3MetalView : UIView
@end
@implementation RPCS3MetalView
+ (Class)layerClass { return CAMetalLayer.class; }
@end

@interface RPCS3GameViewController : UIViewController
@property(nonatomic, copy) dispatch_block_t closeHandler;
@property(nonatomic, readonly) CAMetalLayer* metalLayer;
@end

@implementation RPCS3GameViewController
- (instancetype)init {
  self = [super init];
  if (self) {
    self.modalPresentationStyle = UIModalPresentationFullScreen;
    self.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
  }
  return self;
}
- (void)loadView {
  RPCS3MetalView* view = [[RPCS3MetalView alloc] initWithFrame:UIScreen.mainScreen.bounds];
  view.backgroundColor = UIColor.blackColor;
  view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  CAMetalLayer* layer = (CAMetalLayer*)view.layer;
  layer.device = MTLCreateSystemDefaultDevice();
  layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
  layer.framebufferOnly = NO;
  layer.contentsScale = UIScreen.mainScreen.scale;
  self.view = view;

  UIButton* close = [UIButton buttonWithType:UIButtonTypeSystem];
  close.translatesAutoresizingMaskIntoConstraints = NO;
  close.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
  close.tintColor = UIColor.whiteColor;
  close.layer.cornerRadius = 18;
  close.accessibilityLabel = @"Quit RPCS3";
  [close setImage:[UIImage systemImageNamed:@"xmark"] forState:UIControlStateNormal];
  [close addTarget:self action:@selector(closePressed) forControlEvents:UIControlEventTouchUpInside];
  [view addSubview:close];
  [NSLayoutConstraint activateConstraints:@[
    [close.leadingAnchor constraintEqualToAnchor:view.safeAreaLayoutGuide.leadingAnchor constant:12],
    [close.topAnchor constraintEqualToAnchor:view.safeAreaLayoutGuide.topAnchor constant:12],
    [close.widthAnchor constraintEqualToConstant:44],
    [close.heightAnchor constraintEqualToConstant:44],
  ]];
}
- (CAMetalLayer*)metalLayer { return (CAMetalLayer*)self.view.layer; }
- (void)closePressed { if (self.closeHandler) self.closeHandler(); }
- (BOOL)prefersStatusBarHidden { return YES; }
- (BOOL)prefersHomeIndicatorAutoHidden { return YES; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskLandscape; }
@end

@interface Rpcs3InternalBridgePlugin ()
@property(nonatomic, strong) FlutterMethodChannel* channel;
@property(nonatomic, strong) RPCS3GameViewController* gameController;
@property(nonatomic, assign) BOOL initialized;
@property(nonatomic, assign) BOOL initializedWithExpandedJit;
@property(nonatomic, assign) BOOL coreLoadedWithExpandedJit;
@property(nonatomic, assign) BOOL operationBusy;
@end

@implementation Rpcs3InternalBridgePlugin {
  dispatch_queue_t _runtimeQueue;
  rpcs3_ios_api _api;
}

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar {
  FlutterMethodChannel* channel = [FlutterMethodChannel methodChannelWithName:kRpcs3Channel
                                                              binaryMessenger:registrar.messenger];
  Rpcs3InternalBridgePlugin* instance = [[Rpcs3InternalBridgePlugin alloc] init];
  instance.channel = channel;
  [registrar addMethodCallDelegate:instance channel:channel];
}

- (instancetype)init {
  self = [super init];
  if (self) {
    _runtimeQueue = dispatch_queue_create("com.neogamelab.neostation.rpcs3.runtime", DISPATCH_QUEUE_SERIAL);
    memset(&_api, 0, sizeof(_api));
  }
  return self;
}

static void RPCS3Log(void* context, int32_t level, const char* message) {
  Rpcs3InternalBridgePlugin* bridge = (__bridge Rpcs3InternalBridgePlugin*)context;
  if (!bridge || !message) return;
  NSString* text = [NSString stringWithUTF8String:message] ?: @"";
  // Keep notices/errors needed for crash diagnosis; do not fsync debug/trace
  // output on the render or emulation hot paths.
  if (level <= 4) RPCS3Diagnostic(@"core_log", text);
  dispatch_async(dispatch_get_main_queue(), ^{
    [bridge.channel invokeMethod:@"coreLog" arguments:@{@"level": @(level), @"message": text}];
  });
}

static void RPCS3Dispatch(void* context,
                          rpcs3_ios_dispatch_function function,
                          void* functionContext) {
  if (!function) return;
  dispatch_async(dispatch_get_main_queue(), ^{ function(functionContext); });
}

static void RPCS3Progress(void* context,
                          uint32_t current,
                          uint32_t total,
                          const char* detail) {
  Rpcs3InternalBridgePlugin* bridge = (__bridge Rpcs3InternalBridgePlugin*)context;
  if (!bridge) return;
  NSString* text = detail ? ([NSString stringWithUTF8String:detail] ?: @"") : @"";
  RPCS3Diagnostic(@"install_progress", text);
  dispatch_async(dispatch_get_main_queue(), ^{
    [bridge.channel invokeMethod:@"installProgress" arguments:@{
      @"current": @(current), @"total": @(total), @"detail": text,
    }];
  });
}

- (NSString*)lastError {
  if (_api.last_error) {
    const char* value = _api.last_error();
    if (value && value[0]) return [NSString stringWithUTF8String:value] ?: @"Unknown RPCS3 error";
  }
  return @"Unknown RPCS3 error";
}

- (BOOL)loadCoreWithExpandedJit:(BOOL)expanded error:(NSString**)error {
  if (_api.handle) {
    if (self.coreLoadedWithExpandedJit != expanded) {
      if (error) {
        *error = @"RPCS3 JIT arena policy cannot change after the Core is loaded; relaunch NeoStation.";
      }
      return NO;
    }
    return YES;
  }

  // The original RPCS3 iOS loader requires JIT to be active before dlopen.
  if (!RPCS3HostIsDebugged()) {
    if (error) *error = @"JIT must be ready before loading RPCS3 Core.";
    return NO;
  }

  // libRPCS3Core.dylib is loaded into NeoStation itself, not a child process.
  // The Core therefore executes with the entitlements of the signed NeoStation
  // host process. Do not gate dlopen on a second SecTask entitlement lookup:
  // some sideload signing paths can make that diagnostic lookup report a false
  // negative even though the kernel has already granted the host capabilities.
  // The executable-memory probe below remains the runtime source of truth.
  NSString* readinessError = nil;
  if (!RPCS3ProbeExecutableMemory(&readinessError)) {
    if (error) *error = readinessError;
    return NO;
  }

  // RPCS3 reads this policy while the dylib is being loaded, before
  // rpcs3_ios_initialize is ever called. Setting it afterwards is too late.
  if (setenv("RPCS3_IOS_EXPANDED_JIT_ARENA", expanded ? "1" : "0", 1) != 0) {
    if (error) {
      *error = [NSString stringWithFormat:
          @"Unable to configure the RPCS3 JIT arena before loading (errno %d).",
          errno];
    }
    return NO;
  }

  NSString* frameworks = NSBundle.mainBundle.privateFrameworksPath ?: @"";
  NSArray<NSString*>* candidates = @[
    [frameworks stringByAppendingPathComponent:@"libRPCS3Core.dylib"],
    [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Frameworks/libRPCS3Core.dylib"],
  ];
  void* handle = NULL;
  dlerror();
  for (NSString* path in candidates) {
    if ([NSFileManager.defaultManager fileExistsAtPath:path]) {
      RPCS3Diagnostic(@"core_load_begin", expanded ? @"expanded arena" : @"standard arena");
      handle = dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
      RPCS3Diagnostic(@"core_load_end", handle ? @"loaded" : @"dlopen failed");
      if (handle) break;
    }
  }
  if (!handle) {
    if (error) *error = [NSString stringWithFormat:@"libRPCS3Core.dylib is missing or could not load: %s", dlerror() ?: "unknown"];
    return NO;
  }
#define LOAD(name, field) do { _api.field = (__typeof__(_api.field))dlsym(handle, name); if (!_api.field) { if (error) *error = [NSString stringWithFormat:@"Missing RPCS3 symbol %s", name]; dlclose(handle); memset(&_api, 0, sizeof(_api)); self.coreLoadedWithExpandedJit = NO; return NO; } } while (0)
  _api.handle = handle;
  self.coreLoadedWithExpandedJit = expanded;
  LOAD("rpcs3_ios_abi_version", abi_version);
  LOAD("rpcs3_ios_build_info", build_info);
  LOAD("rpcs3_ios_initialize", initialize);
  LOAD("rpcs3_ios_firmware_version", firmware_version);
  LOAD("rpcs3_ios_install_firmware", install_firmware);
  LOAD("rpcs3_ios_install_package", install_package);
  LOAD("rpcs3_ios_install_iso", install_iso);
  LOAD("rpcs3_ios_install_zip", install_zip);
  LOAD("rpcs3_ios_install_folder", install_folder);
  LOAD("rpcs3_ios_set_display_surface", set_display_surface);
  LOAD("rpcs3_ios_boot_game", boot_game);
  LOAD("rpcs3_ios_get_emulation_state", get_emulation_state);
  LOAD("rpcs3_ios_stop_emulation", stop_emulation);
  LOAD("rpcs3_ios_shutdown", shutdown);
  LOAD("rpcs3_ios_last_error", last_error);
#undef LOAD
  if (_api.abi_version() != kExpectedAbi) {
    if (error) *error = [NSString stringWithFormat:@"Unsupported RPCS3 iOS ABI %u (expected %u).", _api.abi_version(), kExpectedAbi];
    dlclose(handle);
    memset(&_api, 0, sizeof(_api));
    self.coreLoadedWithExpandedJit = NO;
    return NO;
  }
  return YES;
}

- (NSDictionary*)statusPayload:(rpcs3_ios_status)status {
  BOOL ok = status == 0;
  return ok ? @{@"success": @YES} : @{@"success": @NO, @"message": [self lastError], @"status": @(status)};
}

- (void)handleMethodCall:(FlutterMethodCall*)call result:(FlutterResult)result {
  if ([call.method isEqualToString:@"preflight"]) {
    dispatch_async(_runtimeQueue, ^{
      RPCS3Diagnostic(@"memory_preflight_begin", @"Checking RPCS3 virtual address space before JIT attachment");
      BOOL available = self.initialized || neostation::rpcs3::probe_virtual_layout();
      NSString* message = available ? @"RPCS3 virtual memory layout available." :
          @"iOS refuse l’espace mémoire requis par RPCS3. Réinstallez l’IPA en conservant le droit extended-virtual-addressing lors de la signature. Journal : RPCS3-diagnostic.log.";
      RPCS3Diagnostic(@"memory_preflight_end", message);
      dispatch_async(dispatch_get_main_queue(), ^{
        result(@{@"success": @(available), @"message": message});
      });
    });
    return;
  }

  if ([call.method isEqualToString:@"diagnostics"]) {
    NSString* frameworks = NSBundle.mainBundle.privateFrameworksPath ?: @"";
    NSString* corePath = [frameworks stringByAppendingPathComponent:@"libRPCS3Core.dylib"];
    BOOL present = [NSFileManager.defaultManager fileExistsAtPath:corePath];
    NSString* build = @"";
    uint32_t abi = 0;
    if (_api.handle) {
      abi = _api.abi_version();
      const char* value = _api.build_info();
      if (value) build = [NSString stringWithUTF8String:value] ?: @"";
    }
    result(@{
      @"corePresent": @(present),
      @"coreLoaded": @(_api.handle != NULL),
      @"abi": @(abi),
      @"build": build,
      @"initialized": @(self.initialized),
      @"expandedJitRegion": @(self.initializedWithExpandedJit),
      @"jitReady": @(RPCS3HostIsDebugged()),
      @"extendedVirtualAddressing": @(RPCS3HostHasEntitlement(CFSTR("com.apple.developer.kernel.extended-virtual-addressing"))),
      @"increasedMemoryLimit": @(RPCS3HostHasEntitlement(CFSTR("com.apple.developer.kernel.increased-memory-limit"))),
      @"message": @"",
    });
    return;
  }

  if ([call.method isEqualToString:@"initialize"]) {
    NSDictionary* args = [call.arguments isKindOfClass:NSDictionary.class] ? call.arguments : @{};
    NSString* support = [args[@"supportPath"] isKindOfClass:NSString.class] ? args[@"supportPath"] : @"";
    NSString* cache = [args[@"cachePath"] isKindOfClass:NSString.class] ? args[@"cachePath"] : @"";
    BOOL expanded = [args[@"expandedJitRegion"] boolValue];
    dispatch_async(_runtimeQueue, ^{
      NSString* error = nil;
      if (![self loadCoreWithExpandedJit:expanded error:&error]) {
        dispatch_async(dispatch_get_main_queue(), ^{
          result(@{@"success": @NO, @"message": error ?: @"Core unavailable"});
        });
        return;
      }
      if (self.initialized) {
        if (self.initializedWithExpandedJit == expanded) {
          dispatch_async(dispatch_get_main_queue(), ^{ result(@{@"success": @YES, @"alreadyInitialized": @YES, @"expandedJitRegion": @(expanded)}); });
        } else {
          dispatch_async(dispatch_get_main_queue(), ^{ result(@{@"success": @NO, @"modeMismatch": @YES, @"message": @"RPCS3 Core must be restarted to change runtime mode."}); });
        }
        return;
      }
      rpcs3_ios_init_options options = {};
      options.abi_version = kExpectedAbi;
      options.size = sizeof(options);
      options.support_path = support.fileSystemRepresentation;
      options.cache_path = cache.fileSystemRepresentation;
      options.log_callback = RPCS3Log;
      options.dispatch_callback = RPCS3Dispatch;
      options.context = (__bridge void*)self;
      options.expanded_jit_region = expanded ? 1 : 0;
      options.reserved = 0;
      RPCS3Diagnostic(@"core_initialize_begin", @"Calling rpcs3_ios_initialize");
      rpcs3_ios_status status = self->_api.initialize(&options);
      RPCS3Diagnostic(@"core_initialize_end", [NSString stringWithFormat:@"status=%d", status]);
      if (status == 0) {
        self.initialized = YES;
        self.initializedWithExpandedJit = expanded;
      }
      NSMutableDictionary* payload = [[self statusPayload:status] mutableCopy];
      payload[@"expandedJitRegion"] = @(expanded);
      dispatch_async(dispatch_get_main_queue(), ^{ result(payload); });
    });
    return;
  }

  if ([call.method isEqualToString:@"shutdown"]) {
    dispatch_async(_runtimeQueue, ^{
      if (!self.initialized) {
        dispatch_async(dispatch_get_main_queue(), ^{ result(@{@"success": @YES, @"alreadyShutdown": @YES}); });
        return;
      }
      if (self.gameController && self->_api.stop_emulation) self->_api.stop_emulation();
      if (self->_api.set_display_surface) self->_api.set_display_surface(NULL);
      rpcs3_ios_status status = self->_api.shutdown ? self->_api.shutdown() : 0;
      if (status == 0) {
        self.initialized = NO;
        self.initializedWithExpandedJit = NO;
      }
      NSDictionary* payload = [self statusPayload:status];
      dispatch_async(dispatch_get_main_queue(), ^{
        RPCS3GameViewController* controller = self.gameController;
        self.gameController = nil;
        [controller dismissViewControllerAnimated:NO completion:nil];
        result(payload);
      });
    });
    return;
  }

  if ([call.method isEqualToString:@"firmwareVersion"]) {
    dispatch_async(_runtimeQueue, ^{
      NSString* value = @"";
      if (self.initialized && self->_api.firmware_version) {
        const char* version = self->_api.firmware_version();
        if (version) value = [NSString stringWithUTF8String:version] ?: @"";
      }
      dispatch_async(dispatch_get_main_queue(), ^{ result(value); });
    });
    return;
  }

  if ([call.method hasPrefix:@"install"]) {
    NSDictionary* args = [call.arguments isKindOfClass:NSDictionary.class] ? call.arguments : @{};
    NSString* input = [args[@"path"] isKindOfClass:NSString.class] ? args[@"path"] : @"";
    NSString* keyPath = [args[@"keyPath"] isKindOfClass:NSString.class] ? args[@"keyPath"] : nil;
    dispatch_async(_runtimeQueue, ^{
      if (!self.initialized) { dispatch_async(dispatch_get_main_queue(), ^{ result(@{@"success": @NO, @"message": @"RPCS3 Core is not initialized."}); }); return; }
      if (self.operationBusy) { dispatch_async(dispatch_get_main_queue(), ^{ result(@{@"success": @NO, @"message": @"Another RPCS3 operation is already running."}); }); return; }
      self.operationBusy = YES;
      RPCS3Diagnostic(@"install_begin", call.method);
      rpcs3_ios_status status = -1;
      if ([call.method isEqualToString:@"installFirmware"])
        status = self->_api.install_firmware(input.fileSystemRepresentation, RPCS3Progress, (__bridge void*)self);
      else if ([call.method isEqualToString:@"installPackage"])
        status = self->_api.install_package(input.fileSystemRepresentation, RPCS3Progress, (__bridge void*)self);
      else if ([call.method isEqualToString:@"installIso"])
        status = self->_api.install_iso(input.fileSystemRepresentation, keyPath.length ? keyPath.fileSystemRepresentation : NULL, RPCS3Progress, (__bridge void*)self);
      else if ([call.method isEqualToString:@"installZip"])
        status = self->_api.install_zip(input.fileSystemRepresentation, RPCS3Progress, (__bridge void*)self);
      else if ([call.method isEqualToString:@"installFolder"])
        status = self->_api.install_folder(input.fileSystemRepresentation, RPCS3Progress, (__bridge void*)self);
      self.operationBusy = NO;
      RPCS3Diagnostic(@"install_end", [NSString stringWithFormat:@"%@ status=%d", call.method, status]);
      NSDictionary* payload = [self statusPayload:status];
      dispatch_async(dispatch_get_main_queue(), ^{ result(payload); });
    });
    return;
  }

  if ([call.method isEqualToString:@"launchGame"]) {
    NSDictionary* args = [call.arguments isKindOfClass:NSDictionary.class] ? call.arguments : @{};
    NSString* titleId = [args[@"titleId"] isKindOfClass:NSString.class] ? args[@"titleId"] : @"";
    NSString* savestateId = [args[@"savestateId"] isKindOfClass:NSString.class] ? args[@"savestateId"] : nil;
    if (!self.initialized || !titleId.length || self.gameController) {
      result(@{@"success": @NO, @"message": @"RPCS3 is not ready to boot this title with JIT."});
      return;
    }
    __block RPCS3GameViewController* controller = nil;
    // Flutter delivers this handler on the main queue; dispatch_sync to the
    // same queue deadlocks as soon as standard-arena boot is permitted.
    void (^present)(void) = ^{
      UIViewController* root = RPCS3RootViewController();
      if (!root || root.view.window == nil) return;
      controller = [RPCS3GameViewController new];
      __weak Rpcs3InternalBridgePlugin* weakSelf = self;
      controller.closeHandler = ^{ [weakSelf stopAndDismiss:nil]; };
      [controller loadViewIfNeeded];
      [root presentViewController:controller animated:NO completion:nil];
      self.gameController = controller;
    };
    if (NSThread.isMainThread) present();
    else dispatch_sync(dispatch_get_main_queue(), present);
    if (!controller || !controller.metalLayer.device) { result(@{@"success": @NO, @"message": @"Metal surface could not be created."}); return; }
    CGSize size = controller.view.bounds.size;
    UIScreen* screen = controller.view.window.screen ?: UIScreen.mainScreen;
    CGFloat scale = screen.scale;
    float refreshRate = (float)screen.maximumFramesPerSecond;
    dispatch_async(_runtimeQueue, ^{
      rpcs3_ios_display_surface surface = {};
      surface.size = sizeof(surface);
      surface.width = MAX(1, (uint32_t)llround(size.width * scale));
      surface.height = MAX(1, (uint32_t)llround(size.height * scale));
      surface.refresh_rate = refreshRate;
      surface.metal_layer = (__bridge void*)controller.metalLayer;
      rpcs3_ios_status surfaceStatus = self->_api.set_display_surface(&surface);
      rpcs3_ios_status bootStatus = surfaceStatus == 0
          ? self->_api.boot_game(titleId.UTF8String, savestateId.length ? savestateId.UTF8String : NULL)
          : surfaceStatus;
      NSDictionary* payload = [self statusPayload:bootStatus];
      if (bootStatus != 0) [self stopAndDismiss:nil];
      dispatch_async(dispatch_get_main_queue(), ^{ result(payload); });
    });
    return;
  }

  if ([call.method isEqualToString:@"emulationState"]) {
    dispatch_async(_runtimeQueue, ^{
      int32_t value = self.initialized ? self->_api.get_emulation_state() : 0;
      dispatch_async(dispatch_get_main_queue(), ^{ result(@(value)); });
    });
    return;
  }
  if ([call.method isEqualToString:@"stop"]) { [self stopAndDismiss:result]; return; }
  result(FlutterMethodNotImplemented);
}

- (void)stopAndDismiss:(FlutterResult)result {
  dispatch_async(_runtimeQueue, ^{
    BOOL ok = YES;
    if (self.initialized && self->_api.stop_emulation) ok = self->_api.stop_emulation() == 0;
    if (self.initialized && self->_api.set_display_surface) self->_api.set_display_surface(NULL);
    dispatch_async(dispatch_get_main_queue(), ^{
      RPCS3GameViewController* controller = self.gameController;
      self.gameController = nil;
      [controller dismissViewControllerAnimated:NO completion:nil];
      if (result) result(@(ok));
    });
  });
}

@end
