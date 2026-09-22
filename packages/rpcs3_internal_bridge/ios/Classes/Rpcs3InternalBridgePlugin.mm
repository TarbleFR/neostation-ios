#import <string.h>
#import "Rpcs3InternalBridgePlugin.h"
#import "Rpcs3JitBridgePlugin.h"
#import "Rpcs3CoreABI.h"
#import "Rpcs3Diagnostics.h"
#import "Rpcs3EarlyLoaderDiagnostics.h"
#import "RPCS3GameInputController.h"
#import "RPCS3PerformanceOverlay.h"
#import "RPCS3InGameLocalization.h"
#import "Rpcs3SessionMenu.h"

#import <AVFAudio/AVAudioSession.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <Security/Security.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <errno.h>
#import <os/lock.h>
#import <os/proc.h>
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
@property(nonatomic, copy) dispatch_block_t menuHandler;
@property(nonatomic, copy) void (^performanceToggleHandler)(BOOL visible);
@property(nonatomic, readonly) CAMetalLayer* metalLayer;
@property(nonatomic, strong) RPCS3GameInputController* inputController;
@property(nonatomic, strong) RPCS3PerformanceOverlay* performanceOverlay;
@property(nonatomic, strong) UIButton* menuButton;
@property(nonatomic, strong) UIButton* performanceButton;
@property(nonatomic, assign) BOOL showingPerformance;
@property(nonatomic, copy) NSString* uiLocale;
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
  self.uiLocale = RPCS3CanonicalLocale(self.uiLocale ?: NSLocale.preferredLanguages.firstObject);

  UIButton* menu = [UIButton buttonWithType:UIButtonTypeSystem];
  menu.translatesAutoresizingMaskIntoConstraints = NO;
  menu.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
  menu.tintColor = UIColor.whiteColor;
  menu.layer.cornerRadius = 18;
  menu.accessibilityLabel = RPCS3LocalizedString(@"menu", self.uiLocale);
  [menu setImage:[UIImage systemImageNamed:@"line.3.horizontal"] forState:UIControlStateNormal];
  [menu addTarget:self action:@selector(menuPressed) forControlEvents:UIControlEventTouchUpInside];
  self.menuButton = menu;
  [view addSubview:menu];

  UIButton* performance = [UIButton buttonWithType:UIButtonTypeSystem];
  performance.translatesAutoresizingMaskIntoConstraints = NO;
  performance.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
  performance.tintColor = UIColor.whiteColor;
  performance.layer.cornerRadius = 18;
  performance.accessibilityLabel = RPCS3LocalizedString(@"performance", self.uiLocale);
  performance.accessibilityValue = RPCS3LocalizedString(@"disabled", self.uiLocale);
  [performance setImage:[UIImage systemImageNamed:@"chart.xyaxis.line"] forState:UIControlStateNormal];
  [performance addTarget:self action:@selector(performancePressed) forControlEvents:UIControlEventTouchUpInside];
  self.performanceButton = performance;
  [view addSubview:performance];

  self.performanceOverlay = [[RPCS3PerformanceOverlay alloc] initWithFrame:CGRectZero];
  [self.performanceOverlay setLocaleIdentifier:self.uiLocale];
  self.performanceOverlay.translatesAutoresizingMaskIntoConstraints = NO;
  self.performanceOverlay.hidden = YES;
  [view addSubview:self.performanceOverlay];

  [NSLayoutConstraint activateConstraints:@[
    [menu.leadingAnchor constraintEqualToAnchor:view.safeAreaLayoutGuide.leadingAnchor constant:12],
    // Keep RPCS3 actions in their own rail below the virtual shoulder row.
    [menu.topAnchor constraintEqualToAnchor:view.safeAreaLayoutGuide.topAnchor constant:70],
    [menu.widthAnchor constraintEqualToConstant:44],
    [menu.heightAnchor constraintEqualToConstant:44],
    [performance.centerXAnchor constraintEqualToAnchor:menu.centerXAnchor],
    [performance.topAnchor constraintEqualToAnchor:menu.bottomAnchor constant:8],
    [performance.widthAnchor constraintEqualToConstant:44],
    [performance.heightAnchor constraintEqualToConstant:44],
    [self.performanceOverlay.leadingAnchor constraintEqualToAnchor:menu.trailingAnchor constant:8],
    [self.performanceOverlay.topAnchor constraintEqualToAnchor:menu.topAnchor],
    [self.performanceOverlay.widthAnchor constraintEqualToConstant:310],
    [self.performanceOverlay.heightAnchor constraintEqualToConstant:150],
  ]];
}
- (void)viewDidAppear:(BOOL)animated {
  [super viewDidAppear:animated];
  [self.inputController start];
}
- (void)viewDidLayoutSubviews {
  [super viewDidLayoutSubviews];
  [self.inputController layoutControlsInBounds:self.view.bounds safeAreaInsets:self.view.safeAreaInsets];
  // The virtual pad is installed after loadView; preserve the independent
  // action rail's hit testing above it without sharing any pad geometry.
  [self.view bringSubviewToFront:self.performanceOverlay];
  [self.view bringSubviewToFront:self.menuButton];
  [self.view bringSubviewToFront:self.performanceButton];
}
- (void)viewDidDisappear:(BOOL)animated {
  [self.inputController stop];
  [super viewDidDisappear:animated];
}
- (CAMetalLayer*)metalLayer { return (CAMetalLayer*)self.view.layer; }
- (void)menuPressed { if (self.menuHandler) self.menuHandler(); }
- (void)performancePressed {
  self.showingPerformance = !self.showingPerformance;
  [self.performanceOverlay reset];
  self.performanceOverlay.hidden = !self.showingPerformance;
  self.performanceButton.tintColor = self.showingPerformance ? UIColor.systemGreenColor : UIColor.whiteColor;
  self.performanceButton.accessibilityValue = RPCS3LocalizedString(
      self.showingPerformance ? @"enabled" : @"disabled", self.uiLocale);
  if (self.performanceToggleHandler) self.performanceToggleHandler(self.showingPerformance);
}
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
@property(nonatomic, assign) BOOL llvmSelfTestPassed;
@property(nonatomic, copy) NSString* activeTitleId;
@property(nonatomic, copy) NSString* activeUiLocale;
@property(nonatomic, assign) BOOL audioSessionActive;
@property(nonatomic, copy) NSString* previousAudioCategory;
@property(nonatomic, copy) NSString* previousAudioMode;
@property(nonatomic, assign) AVAudioSessionCategoryOptions previousAudioOptions;
@property(nonatomic, assign) double previousPreferredSampleRate;
@property(nonatomic, assign) NSTimeInterval previousPreferredIOBufferDuration;
@property(nonatomic, assign) BOOL audioPolicyCaptured;
@end

@implementation Rpcs3InternalBridgePlugin {
  dispatch_queue_t _runtimeQueue;
  dispatch_source_t _performanceTimer;
  dispatch_source_t _diagnosticPerformanceTimer;
  uint64_t _diagnosticPerformanceSamples;
  double _diagnosticFpsTotal;
  double _diagnosticMinimumFps;
  uint64_t _diagnosticPeakMemory;
  uint64_t _diagnosticMinimumAvailableMemory;
  NSInteger _diagnosticWorstThermalState;
  rpcs3_ios_api _api;
  BOOL _startupEntered;
}

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar {
  RPCS3RecoverEarlyLoaderLog();
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

- (NSString*)localized:(NSString*)key {
  return RPCS3LocalizedString(key, self.activeUiLocale);
}

// NEOSTATION_RPCS3_BUILD256_HOST_V1: do not leak Core-owned English strings into localized alerts.
- (NSString*)localizedSavestateError:(NSString*)message {
  NSString* lower = (message ?: @"").lowercaseString;
  if ([lower containsString:@"safe point"] || [lower containsString:@"spu threads"]) return [self localized:@"stateSafePoint"];
  if ([lower containsString:@"video decoder"] || [lower containsString:@"vdec"] || [lower containsString:@"cutscene"]) return [self localized:@"stateVideoActive"];
  if ([lower containsString:@"not found"] || [lower containsString:@"missing"]) return [self localized:@"stateMissing"];
  if ([lower containsString:@"in progress"] || [lower containsString:@"already running"]) return [self localized:@"stateBusy"];
  if ([lower containsString:@"write"] || [lower containsString:@"storage"] || [lower containsString:@"temporary file"]) return [self localized:@"stateWriteFailed"];
  if ([lower containsString:@"invalid"] || [lower containsString:@"unsupported"] || [lower containsString:@"compatible"]) return [self localized:@"stateInvalid"];
  return [self localized:@"stateUnknown"];
}

static void RPCS3Log(void* context, int32_t level, const char* message) {
  Rpcs3InternalBridgePlugin* bridge = (__bridge Rpcs3InternalBridgePlugin*)context;
  if (!bridge || !message) return;

  // NEOSTATION_BUILD283_BOUNDED_CORE_LOG
  const BOOL profiler =
      strstr(message, "COREPROF ") != nullptr ||
      strstr(message, "COREPROF_RESILIENCE ") != nullptr;
  if (level > 2 && !profiler) return;

  static os_unfair_lock budgetLock = OS_UNFAIR_LOCK_INIT;
  static CFTimeInterval budgetWindow = 0;
  static uint32_t budgetCount = 0;
  if (!profiler) {
    const CFTimeInterval now = CACurrentMediaTime();
    BOOL allowed = YES;
    os_unfair_lock_lock(&budgetLock);
    if (budgetWindow == 0 || now - budgetWindow >= 1.0) {
      budgetWindow = now;
      budgetCount = 0;
    }
    if (budgetCount >= 128) allowed = NO;
    else budgetCount++;
    os_unfair_lock_unlock(&budgetLock);
    if (!allowed) return;
  }

  NSString* text = [NSString stringWithUTF8String:message] ?: @"";
  RPCS3Diagnostic(@"core_log", text);
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
        *error = @"RPCS3_CORE_MODE_MISMATCH: JIT arena policy cannot change after the Core is loaded; relaunch NeoStation.";
      }
      return NO;
    }
    return YES;
  }

  // libRPCS3Core.dylib is loaded into NeoStation itself, not a child process.
  // This is debugger authorization only, never proof of usable JIT memory.
  // The final nonce below proves live ownership before this single dlopen.
  if (!RPCS3HostIsDebugged()) {
    if (error) *error = @"RPCS3_DEBUGGER_AUTHORIZATION_MISSING: stage=core_load; kernel CS_DEBUGGED is absent.";
    return NO;
  }

  // NEOSTATION_RPCS3_BUILD301_SINGLE_DLOPEN_V1
  // The Core is now passive during dyld loading. Arena capacity belongs only
  // to rpcs3_ios_initialize(), so do not communicate JIT policy through the
  // environment and never retry dlopen under a second path.
  NSString* frameworks = NSBundle.mainBundle.privateFrameworksPath ?: @"";
  NSString* path =
      [frameworks stringByAppendingPathComponent:@"libRPCS3Core.dylib"];
  if (![NSFileManager.defaultManager fileExistsAtPath:path]) {
    NSString* fallback = [NSBundle.mainBundle.bundlePath
        stringByAppendingPathComponent:@"Frameworks/libRPCS3Core.dylib"];
    if ([NSFileManager.defaultManager fileExistsAtPath:fallback]) {
      path = fallback;
    }
  }
  if (![NSFileManager.defaultManager fileExistsAtPath:path]) {
    if (error) *error = @"RPCS3_CORE_MISSING: libRPCS3Core.dylib is missing from NeoStation Frameworks.";
    return NO;
  }

  if (@available(iOS 26.0, *)) {
    RPCS3Milestone(@"core_handoff_begin",
                    @"Final debugger nonce proof immediately before dlopen");
    if (!RPCS3JitConfirmCoreLoadHandoff()) {
      RPCS3Milestone(@"core_handoff_end", @"rejected; dlopen blocked");
      if (error) {
        *error = @"RPCS3_JIT_HANDOFF_FAILED: Universal debugger did not acknowledge the final Core-load nonce; dlopen was blocked.";
      }
      return NO;
    }
    RPCS3Milestone(@"core_handoff_end", @"verified; entering dlopen");
  }

  RPCS3Milestone(@"core_load_begin",
                  expanded ? @"expanded arena" : @"standard arena");
  void* handle = NULL;
  NSString* lastLoadError = @"unknown";
  dlerror();
  {
    // stderr capture is scoped to this single deterministic dlopen. A passive
    // Core must return from this boundary before explicit JIT initialization.
    RPCS3EarlyLoaderCapture earlyLoaderCapture;
    handle = dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
  }
  if (!handle) {
    const char* loadError = dlerror();
    if (loadError) {
      lastLoadError = [NSString stringWithUTF8String:loadError] ?: @"unknown";
    }
    RPCS3Milestone(@"core_load_end",
                    [NSString stringWithFormat:@"dlopen failed: %@", lastLoadError]);
    if (error) {
      *error = [NSString stringWithFormat:
          @"RPCS3_CORE_DLOPEN_FAILED: %@", lastLoadError];
    }
    return NO;
  }
  RPCS3Milestone(@"core_load_end", @"loaded; no Core JIT initialized during dlopen");

#define LOAD(name, field) do { _api.field = (__typeof__(_api.field))dlsym(handle, name); if (!_api.field) { if (error) *error = [NSString stringWithFormat:@"RPCS3_CORE_SYMBOL_MISSING: %s", name]; dlclose(handle); memset(&_api, 0, sizeof(_api)); self.coreLoadedWithExpandedJit = NO; return NO; } } while (0)
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
  LOAD("rpcs3_ios_set_pad_state", set_pad_state);
  LOAD("rpcs3_ios_set_game_setting", set_game_setting);
  LOAD("rpcs3_ios_boot_game", boot_game);
  LOAD("rpcs3_ios_get_emulation_state", get_emulation_state);
  LOAD("rpcs3_ios_get_performance_metrics", get_performance_metrics);
  LOAD("neostation_rpcs3_ios_save_state", save_state);
  LOAD("neostation_rpcs3_ios_save_state_slot", save_state_slot);
  LOAD("neostation_rpcs3_ios_get_savestate_status", get_savestate_status);
  LOAD("neostation_rpcs3_ios_enumerate_savestates_live", enumerate_savestates_live);
  LOAD("rpcs3_ios_stop_emulation", stop_emulation);
  LOAD("rpcs3_ios_shutdown", shutdown);
  LOAD("rpcs3_ios_last_error", last_error);
#undef LOAD
  if (_api.abi_version() != kExpectedAbi) {
    if (error) *error = [NSString stringWithFormat:@"RPCS3_CORE_ABI_MISMATCH: got %u expected %u.", _api.abi_version(), kExpectedAbi];
    dlclose(handle);
    memset(&_api, 0, sizeof(_api));
    self.coreLoadedWithExpandedJit = NO;
    return NO;
  }
  return YES;
}

- (NSDictionary*)statusPayload:(rpcs3_ios_status)status {
  NSString* message = status == 0 ? @"" : [self lastError];
  NSString* code = status == 0 ? @"RPCS3_OK" : [NSString stringWithFormat:@"RPCS3_CORE_STATUS_%d", status];
  if ([message hasPrefix:@"RPCS3_"]) {
    code = [message componentsSeparatedByCharactersInSet:
        [NSCharacterSet characterSetWithCharactersInString:@" :\n"]].firstObject ?: code;
  }
  return @{@"success": @(status == 0), @"status": @(status), @"code": code,
    @"message": message ?: @"", @"stage": @"core"};
}

- (BOOL)activateRPCS3AudioSession:(NSString**)fatalError {
  AVAudioSession* session = AVAudioSession.sharedInstance;
  NSError* error = nil;
  if (!self.audioPolicyCaptured) {
    self.previousAudioCategory = session.category;
    self.previousAudioMode = session.mode;
    self.previousAudioOptions = session.categoryOptions;
    self.previousPreferredSampleRate = session.preferredSampleRate;
    self.previousPreferredIOBufferDuration = session.preferredIOBufferDuration;
    self.audioPolicyCaptured = YES;
  }

  if (![session setCategory:AVAudioSessionCategoryPlayback
                        mode:AVAudioSessionModeDefault
                     options:0
                       error:&error]) {
    if (fatalError) *fatalError = [NSString stringWithFormat:@"RPCS3 audio category failed: %@", error.localizedDescription ?: @"unknown error"];
    return NO;
  }

  // RPCS3's iOS backend models a 512-frame callback at 48 kHz. Pin the host
  // route to that cadence before RemoteIO opens; letting iOS choose a much
  // shorter slice causes the emulator mixer to be drained too aggressively and
  // presents as repeated underruns/crackle under PS3 CPU load.
  NSError* sampleError = nil;
  [session setPreferredSampleRate:48000.0 error:&sampleError];
  NSError* bufferError = nil;
  [session setPreferredIOBufferDuration:(512.0 / 48000.0) error:&bufferError];
  error = nil;
  if (![session setActive:YES error:&error]) {
    if (fatalError) *fatalError = [NSString stringWithFormat:@"RPCS3 audio session activation failed: %@", error.localizedDescription ?: @"unknown error"];
    return NO;
  }
  self.audioSessionActive = YES;

  NSString* warning = @"";
  if (sampleError || bufferError) {
    warning = [NSString stringWithFormat:@" preferenceWarning=%@/%@",
        sampleError.localizedDescription ?: @"none", bufferError.localizedDescription ?: @"none"];
  }
  RPCS3Diagnostic(@"audio_session_active", [NSString stringWithFormat:
      @"rate=%.1fHz ioBuffer=%.3fms outputLatency=%.3fms%@",
      session.sampleRate, session.IOBufferDuration * 1000.0,
      session.outputLatency * 1000.0, warning]);
  return YES;
}

- (void)deactivateRPCS3AudioSession {
  if (!self.audioSessionActive && !self.audioPolicyCaptured) return;
  AVAudioSession* session = AVAudioSession.sharedInstance;
  NSError* error = nil;

  if (self.audioPolicyCaptured) {
    // RPCS3 owns `.playback` only while its game view is active. Always
    // return to NeoStation's ambient policy instead of replaying a category
    // that another native component may have changed after capture.
    [session setCategory:AVAudioSessionCategoryAmbient
                    mode:AVAudioSessionModeDefault
                 options:AVAudioSessionCategoryOptionMixWithOthers
                   error:&error];
    if (error == nil && self.previousPreferredSampleRate > 0.0) {
      [session setPreferredSampleRate:self.previousPreferredSampleRate error:&error];
    }
    if (error == nil && self.previousPreferredIOBufferDuration > 0.0) {
      [session setPreferredIOBufferDuration:self.previousPreferredIOBufferDuration error:&error];
    }
    if (error == nil && UIApplication.sharedApplication.applicationState == UIApplicationStateActive) {
      [session setActive:YES error:&error];
    }
  } else {
    [session setActive:NO
           withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
                 error:&error];
  }

  RPCS3Diagnostic(@"audio_session_inactive",
                  error ? error.localizedDescription : @"frontend audio policy restored");
  self.audioSessionActive = NO;
  self.audioPolicyCaptured = NO;
  self.previousAudioCategory = nil;
  self.previousAudioMode = nil;
  self.previousAudioOptions = 0;
  self.previousPreferredSampleRate = 0.0;
  self.previousPreferredIOBufferDuration = 0.0;
}

- (void)showMessage:(NSString*)title message:(NSString*)message {
  dispatch_async(dispatch_get_main_queue(), ^{
    RPCS3GameViewController* controller = self.gameController;
    if (!controller || controller.presentedViewController) return;
    UIAlertController* alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:[self localized:@"ok"] style:UIAlertActionStyleDefault handler:nil]];
    [controller presentViewController:alert animated:YES completion:nil];
  });
}

- (void)setPerformanceSamplingEnabled:(BOOL)enabled {
  dispatch_async(_runtimeQueue, ^{
    if (!enabled) {
      if (self->_performanceTimer) {
        dispatch_source_cancel(self->_performanceTimer);
        self->_performanceTimer = nil;
      }
      return;
    }
    if (self->_performanceTimer || !self->_api.get_performance_metrics) return;
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self->_runtimeQueue);
    self->_performanceTimer = timer;
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 0),
                              (uint64_t)(0.5 * NSEC_PER_SEC),
                              (uint64_t)(0.05 * NSEC_PER_SEC));
    __weak Rpcs3InternalBridgePlugin* weakSelf = self;
    dispatch_source_set_event_handler(timer, ^{
      Rpcs3InternalBridgePlugin* strongSelf = weakSelf;
      if (!strongSelf) return;
      rpcs3_ios_performance_metrics metrics = {};
      metrics.size = sizeof(metrics);
      if (strongSelf->_api.get_performance_metrics(&metrics) != 0) return;
      const double timestamp = CACurrentMediaTime() * 1000.0;
      dispatch_async(dispatch_get_main_queue(), ^{
        RPCS3GameViewController* owner = strongSelf.gameController;
        if (!owner || !owner.showingPerformance) return;
        [owner.performanceOverlay appendMetricsWithFPS:metrics.frames_per_second
                                                   cpu:metrics.cpu_usage_percent
                                                   gpu:metrics.gpu_usage_percent
                                            memoryUsed:metrics.memory_used_bytes
                                           memoryTotal:metrics.memory_total_bytes
                                           validFields:metrics.valid_fields
                                             timestamp:timestamp];
      });
    });
    dispatch_resume(timer);
  });
}

// NEOSTATION_RPCS3_PERFORMANCE_TELEMETRY_V1: one buffered sample per second, outside emulation hot paths.
- (void)startDiagnosticPerformanceSampling {
  if (_diagnosticPerformanceTimer || !_api.get_performance_metrics || !self.activeTitleId.length) return;
  _diagnosticPerformanceSamples = 0;
  _diagnosticFpsTotal = 0.0;
  _diagnosticMinimumFps = 0.0;
  _diagnosticPeakMemory = 0;
  _diagnosticMinimumAvailableMemory = UINT64_MAX;
  _diagnosticWorstThermalState = NSProcessInfoThermalStateNominal;

  dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _runtimeQueue);
  _diagnosticPerformanceTimer = timer;
  dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),
                            NSEC_PER_SEC, (uint64_t)(0.1 * NSEC_PER_SEC));
  __weak Rpcs3InternalBridgePlugin* weakSelf = self;
  dispatch_source_set_event_handler(timer, ^{
    Rpcs3InternalBridgePlugin* strongSelf = weakSelf;
    if (!strongSelf || !strongSelf.activeTitleId.length) return;
    rpcs3_ios_performance_metrics metrics = {};
    metrics.size = sizeof(metrics);
    if (strongSelf->_api.get_performance_metrics(&metrics) != 0) return;

    const NSInteger thermal = NSProcessInfo.processInfo.thermalState;
    const uint64_t availableMemory = os_proc_available_memory();
    strongSelf->_diagnosticWorstThermalState = MAX(strongSelf->_diagnosticWorstThermalState, thermal);
    strongSelf->_diagnosticMinimumAvailableMemory = MIN(strongSelf->_diagnosticMinimumAvailableMemory, availableMemory);
    if (metrics.valid_fields & rpcs3_ios_performance_memory) {
      strongSelf->_diagnosticPeakMemory = MAX(strongSelf->_diagnosticPeakMemory, metrics.memory_used_bytes);
    }
    if (metrics.valid_fields & rpcs3_ios_performance_fps) {
      if (strongSelf->_diagnosticPerformanceSamples == 0 || metrics.frames_per_second < strongSelf->_diagnosticMinimumFps) {
        strongSelf->_diagnosticMinimumFps = metrics.frames_per_second;
      }
      strongSelf->_diagnosticFpsTotal += metrics.frames_per_second;
      strongSelf->_diagnosticPerformanceSamples++;
    }

    RPCS3Diagnostic(@"performance_sample", [NSString stringWithFormat:
        @"title=%@ valid=0x%x fps=%.2f cpu=%.1f rsx=%.1f memory=%llu/%llu available=%llu thermal=%ld",
        strongSelf.activeTitleId, metrics.valid_fields, metrics.frames_per_second,
        metrics.cpu_usage_percent, metrics.gpu_usage_percent,
        (unsigned long long)metrics.memory_used_bytes,
        (unsigned long long)metrics.memory_total_bytes,
        (unsigned long long)availableMemory, (long)thermal]);
  });
  dispatch_resume(timer);
}

- (void)stopDiagnosticPerformanceSampling {
  if (_diagnosticPerformanceTimer) {
    dispatch_source_cancel(_diagnosticPerformanceTimer);
    _diagnosticPerformanceTimer = nil;
  }
  if (_diagnosticPerformanceSamples > 0) {
    const double average = _diagnosticFpsTotal / (double)_diagnosticPerformanceSamples;
    RPCS3Diagnostic(@"performance_summary", [NSString stringWithFormat:
        @"title=%@ samples=%llu average_fps=%.2f minimum_fps=%.2f peak_memory=%llu minimum_available=%llu worst_thermal=%ld",
        self.activeTitleId ?: @"", (unsigned long long)_diagnosticPerformanceSamples,
        average, _diagnosticMinimumFps, (unsigned long long)_diagnosticPeakMemory,
        (unsigned long long)(_diagnosticMinimumAvailableMemory == UINT64_MAX ? 0 : _diagnosticMinimumAvailableMemory),
        (long)_diagnosticWorstThermalState]);
  }
  _diagnosticPerformanceSamples = 0;
}

static void RPCS3CollectSavestate(void* context, const rpcs3_ios_savestate_info* info) {
  if (!context || !info || !info->identifier) return;
  NSMutableArray* states = (__bridge NSMutableArray*)context;
  NSString* identifier = [NSString stringWithUTF8String:info->identifier] ?: @"";
  if (!identifier.length) return;
  [states addObject:@{
    @"id": identifier,
    @"compatible": @(info->compatible != 0),
    @"size": @(info->byte_size),
    @"modified": @(info->modified_time),
  }];
}

- (NSArray<NSDictionary*>*)languageChoices {
  return @[
    @{@"label": @"日本語", @"value": @"Japanese"},
    @{@"label": @"English (US)", @"value": @"English (US)"},
    @{@"label": @"Français", @"value": @"French"},
    @{@"label": @"Español", @"value": @"Spanish"},
    @{@"label": @"Deutsch", @"value": @"German"},
    @{@"label": @"Italiano", @"value": @"Italian"},
    @{@"label": @"Nederlands", @"value": @"Dutch"},
    @{@"label": @"Português (Portugal)", @"value": @"Portuguese (Portugal)"},
    @{@"label": @"Русский", @"value": @"Russian"},
    @{@"label": @"한국어", @"value": @"Korean"},
    @{@"label": @"中文（繁體）", @"value": @"Chinese (Traditional)"},
    @{@"label": @"中文（简体）", @"value": @"Chinese (Simplified)"},
    @{@"label": @"Suomi", @"value": @"Finnish"},
    @{@"label": @"Svenska", @"value": @"Swedish"},
    @{@"label": @"Dansk", @"value": @"Danish"},
    @{@"label": @"Norsk", @"value": @"Norwegian"},
    @{@"label": @"Polski", @"value": @"Polish"},
    @{@"label": @"English (UK)", @"value": @"English (UK)"},
    @{@"label": @"Português (Brasil)", @"value": @"Portuguese (Brazil)"},
    @{@"label": @"Türkçe", @"value": @"Turkish"},
  ];
}

// NeoStation Build 260 modern in-game sheets. Action sheets use the
// native compact bottom-sheet presentation on iPhone and remain safely anchored
// to the menu button on iPad.
- (void)presentModernMenu:(UIAlertController*)menu
                     from:(RPCS3GameViewController*)controller {
  UIPopoverPresentationController* popover = menu.popoverPresentationController;
  if (popover) {
    popover.sourceView = controller.menuButton;
    popover.sourceRect = controller.menuButton.bounds;
    popover.permittedArrowDirections = UIPopoverArrowDirectionAny;
  }
  [controller presentViewController:menu animated:YES completion:nil];
}

- (void)showLanguageMenu {
  RPCS3GameViewController* controller = self.gameController;
  NSString* titleId = self.activeTitleId;
  if (!controller || !titleId.length || controller.presentedViewController) return;
  UIAlertController* alert = [UIAlertController alertControllerWithTitle:[self localized:@"languageTitle"]
                                                                 message:[self localized:@"languageRestart"]
                                                          preferredStyle:UIAlertControllerStyleActionSheet];
  __weak Rpcs3InternalBridgePlugin* weakSelf = self;
  for (NSDictionary* choice in [self languageChoices]) {
    NSString* label = choice[@"label"];
    NSString* value = choice[@"value"];
    [alert addAction:[UIAlertAction actionWithTitle:label style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction* action) {
      Rpcs3InternalBridgePlugin* strongSelf = weakSelf;
      if (!strongSelf) return;
      dispatch_async(strongSelf->_runtimeQueue, ^{
        if (!strongSelf.activeTitleId.length || !strongSelf->_api.stop_emulation || !strongSelf->_api.set_game_setting) return;
        rpcs3_ios_status status = strongSelf->_api.stop_emulation();
        if (status == 0) status = strongSelf->_api.set_game_setting(strongSelf.activeTitleId.UTF8String, "system.language", value.UTF8String);
        if (status == 0) status = strongSelf->_api.boot_game(strongSelf.activeTitleId.UTF8String, NULL);
        if (status != 0) [strongSelf showMessage:@"RPCS3" message:[strongSelf lastError]];
        else RPCS3Diagnostic(@"game_language", [NSString stringWithFormat:@"%@ = %@", strongSelf.activeTitleId, value]);
      });
    }]];
  }
  [alert addAction:[UIAlertAction actionWithTitle:[self localized:@"cancel"] style:UIAlertActionStyleCancel handler:nil]];
  [self presentModernMenu:alert from:controller];
}

- (void)applyResolutionScale:(NSString*)value {
  NSString* titleId = [self.activeTitleId copy];
  if (!titleId.length || !value.length) return;
  dispatch_async(_runtimeQueue, ^{
    if (!self->_api.stop_emulation || !self->_api.set_game_setting ||
        !self->_api.boot_game) {
      [self showMessage:@"RPCS3" message:[self lastError]];
      return;
    }
    rpcs3_ios_status status = self->_api.stop_emulation();
    if (status == 0) {
      status = self->_api.set_game_setting(
          titleId.UTF8String, "gpu.resolution_scale", value.UTF8String);
    }
    if (status == 0) {
      status = self->_api.boot_game(titleId.UTF8String, NULL);
    }
    if (status != 0) {
      [self showMessage:@"RPCS3" message:[self lastError]];
    } else {
      RPCS3Diagnostic(@"game_resolution_scale",
                      [NSString stringWithFormat:@"%@ = %@%%", titleId, value]);
    }
  });
}

- (void)showResolutionScaleMenu {
  RPCS3GameViewController* controller = self.gameController;
  if (!controller || !self.activeTitleId.length ||
      controller.presentedViewController) return;
  UIAlertController* alert = [UIAlertController
      alertControllerWithTitle:[self localized:@"upscaleTitle"]
                       message:[self localized:@"upscaleRestart"]
                preferredStyle:UIAlertControllerStyleActionSheet];
  __weak Rpcs3InternalBridgePlugin* weakSelf = self;
  for (NSString* value in @[@"50", @"75", @"100", @"125", @"150", @"200"]) {
    NSString* label = [value stringByAppendingString:@"%"];
    [alert addAction:[UIAlertAction
        actionWithTitle:label
                  style:UIAlertActionStyleDefault
                handler:^(__unused UIAlertAction* action) {
                  [weakSelf applyResolutionScale:value];
                }]];
  }
  [alert addAction:[UIAlertAction
      actionWithTitle:[self localized:@"cancel"]
                style:UIAlertActionStyleCancel
              handler:nil]];
  [self presentModernMenu:alert from:controller];
}

- (void)applyStretchMode:(BOOL)stretched {
  NSString* titleId = [self.activeTitleId copy];
  if (!titleId.length) return;
  dispatch_async(_runtimeQueue, ^{
    rpcs3_ios_status status = self->_api.stop_emulation();
    if (status == 0) status = self->_api.set_game_setting(
        titleId.UTF8String, "gpu.stretch_to_display", stretched ? "true" : "false");
    if (status == 0) status = self->_api.boot_game(titleId.UTF8String, NULL);
    if (status != 0) [self showMessage:@"RPCS3" message:[self lastError]];
    else RPCS3Diagnostic(@"game_stretch", [NSString stringWithFormat:@"%@ = %d", titleId, stretched]);
  });
}

- (void)showStretchMenu {
  RPCS3GameViewController* controller = self.gameController;
  if (!controller || !self.activeTitleId.length || controller.presentedViewController) return;
  UIAlertController* alert = [UIAlertController alertControllerWithTitle:[self localized:@"stretchTitle"]
      message:[self localized:@"stretchMessage"] preferredStyle:UIAlertControllerStyleActionSheet];
  __weak Rpcs3InternalBridgePlugin* weakSelf = self;
  [alert addAction:[UIAlertAction actionWithTitle:[self localized:@"normal"] style:UIAlertActionStyleDefault
      handler:^(__unused UIAlertAction* action) { [weakSelf applyStretchMode:NO]; }]];
  [alert addAction:[UIAlertAction actionWithTitle:[self localized:@"stretched"] style:UIAlertActionStyleDefault
      handler:^(__unused UIAlertAction* action) { [weakSelf applyStretchMode:YES]; }]];
  [alert addAction:[UIAlertAction actionWithTitle:[self localized:@"cancel"] style:UIAlertActionStyleCancel handler:nil]];
  [self presentModernMenu:alert from:controller];
}

// NEOSTATION_SAVESTATE_PROGRESS_V1
// Keep ownership visible until the native write AND automatic restoration end.
- (void)finishSavestateAlert:(UIAlertController*)alert success:(BOOL)success message:(NSString*)message {
  dispatch_async(dispatch_get_main_queue(), ^{
    alert.message = success ? [self localized:@"stateDone"] :
        [NSString stringWithFormat:@"%@\n%@", [self localized:@"stateFailed"], [self localizedSavestateError:message]];
    [alert addAction:[UIAlertAction actionWithTitle:[self localized:@"ok"]
                                            style:UIAlertActionStyleDefault handler:nil]];
  });
}

- (void)pollSavestateAlert:(UIAlertController*)alert {
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), _runtimeQueue, ^{
    uint32_t phase = 0;
    char reason[2048] = {};
    rpcs3_ios_status status = self->_api.get_savestate_status
        ? self->_api.get_savestate_status(&phase, reason, sizeof(reason)) : -1;
    if (status == 0 && phase >= 1 && phase <= 3) {
      [self pollSavestateAlert:alert];
      return;
    }
    NSString* message = status == 0 ? ([NSString stringWithUTF8String:reason] ?: @"") : [self lastError];
    RPCS3Diagnostic(@"savestate_complete", [NSString stringWithFormat:@"phase=%u status=%d %@", phase, status, message]);
    [self finishSavestateAlert:alert success:(status == 0 && phase == 4) message:message];
  });
}

- (NSInteger)slotForSavestateIdentifier:(NSString*)identifier titleId:(NSString*)titleId {
  NSString* prefix = [NSString stringWithFormat:@"%@_1_", titleId ?: @""];
  if (!identifier.length || !titleId.length || ![identifier hasPrefix:prefix]) return NSNotFound;
  NSRange suffix = [identifier rangeOfString:@".SAVESTAT"];
  if (suffix.location == NSNotFound || suffix.location <= prefix.length) return NSNotFound;
  NSString* number = [identifier substringWithRange:NSMakeRange(prefix.length, suffix.location - prefix.length)];
  NSScanner* scanner = [NSScanner scannerWithString:number];
  NSInteger zeroBased = -1;
  if (![scanner scanInteger:&zeroBased] || !scanner.isAtEnd || zeroBased < 0 || zeroBased > 9) return NSNotFound;
  return zeroBased + 1;
}

- (NSDictionary<NSNumber*, NSDictionary*>*)statesBySlot:(NSArray<NSDictionary*>*)states titleId:(NSString*)titleId {
  NSMutableDictionary<NSNumber*, NSDictionary*>* result = [NSMutableDictionary dictionary];
  for (NSDictionary* entry in states) {
    NSInteger slot = [self slotForSavestateIdentifier:entry[@"id"] titleId:titleId];
    if (slot != NSNotFound) result[@(slot)] = entry;
  }
  return result;
}

- (void)saveCurrentStateAtSlot:(NSUInteger)slot {
  if (slot < 1 || slot > 10) return;
  dispatch_async(dispatch_get_main_queue(), ^{
    RPCS3GameViewController* controller = self.gameController;
    if (!controller) return;
    UIAlertController* alert = [UIAlertController alertControllerWithTitle:[self localized:@"state"]
        message:[self localized:@"stateStarted"] preferredStyle:UIAlertControllerStyleAlert];
    alert.modalInPresentation = YES;
    void (^start)(void) = ^{
      [controller presentViewController:alert animated:YES completion:^{
        dispatch_async(self->_runtimeQueue, ^{
          rpcs3_ios_status status = self->_api.save_state_slot ? self->_api.save_state_slot((uint32_t)slot) : -1;
          if (status == 0) {
            RPCS3Diagnostic(@"savestate_save", [NSString stringWithFormat:@"slot=%lu requested; waiting for native completion", (unsigned long)slot]);
            [self pollSavestateAlert:alert];
          } else {
            [self finishSavestateAlert:alert success:NO message:[self lastError]];
          }
        });
      }];
    };
    if (controller.presentedViewController) [controller dismissViewControllerAnimated:NO completion:start];
    else start();
  });
}

- (void)confirmOverwriteSlot:(NSUInteger)slot {
  RPCS3GameViewController* controller = self.gameController;
  if (!controller || controller.presentedViewController) return;
  NSString* message = [NSString stringWithFormat:[self localized:@"overwriteMessage"], (long)slot];
  UIAlertController* alert = [UIAlertController alertControllerWithTitle:[self localized:@"overwriteTitle"]
      message:message preferredStyle:UIAlertControllerStyleAlert];
  __weak Rpcs3InternalBridgePlugin* weakSelf = self;
  [alert addAction:[UIAlertAction actionWithTitle:[self localized:@"overwrite"] style:UIAlertActionStyleDestructive
      handler:^(__unused UIAlertAction* action) { [weakSelf saveCurrentStateAtSlot:slot]; }]];
  [alert addAction:[UIAlertAction actionWithTitle:[self localized:@"cancel"] style:UIAlertActionStyleCancel handler:nil]];
  [controller presentViewController:alert animated:YES completion:nil];
}

- (void)showSaveSavestateMenu {
  NSString* titleId = [self.activeTitleId copy];
  if (!titleId.length) return;
  dispatch_async(_runtimeQueue, ^{
    NSMutableArray<NSDictionary*>* states = [NSMutableArray array];
    rpcs3_ios_status status = self->_api.enumerate_savestates_live
        ? self->_api.enumerate_savestates_live(titleId.UTF8String, RPCS3CollectSavestate, (__bridge void*)states) : -1;
    if (status != 0) { [self showMessage:[self localized:@"states"] message:[self localizedSavestateError:[self lastError]]]; return; }
    NSDictionary<NSNumber*, NSDictionary*>* bySlot = [self statesBySlot:states titleId:titleId];
    dispatch_async(dispatch_get_main_queue(), ^{
      RPCS3GameViewController* controller = self.gameController;
      if (!controller || controller.presentedViewController) return;
      UIAlertController* alert = [UIAlertController alertControllerWithTitle:[self localized:@"createState"]
          message:nil preferredStyle:UIAlertControllerStyleActionSheet];
      NSDateFormatter* formatter = [NSDateFormatter new];
      formatter.dateStyle = NSDateFormatterShortStyle;
      formatter.timeStyle = NSDateFormatterShortStyle;
      formatter.locale = [NSLocale localeWithLocaleIdentifier:self.activeUiLocale ?: @"en"];
      __weak Rpcs3InternalBridgePlugin* weakSelf = self;
      for (NSUInteger slot = 1; slot <= 10; ++slot) {
        NSDictionary* existing = bySlot[@(slot)];
        int64_t modified = [existing[@"modified"] longLongValue];
        NSString* detail = existing
            ? [formatter stringFromDate:[NSDate dateWithTimeIntervalSince1970:(NSTimeInterval)modified]]
            : [self localized:@"emptySlot"];
        NSString* label = [NSString stringWithFormat:@"%@ %lu · %@", [self localized:@"slot"], (unsigned long)slot, detail];
        [alert addAction:[UIAlertAction actionWithTitle:label style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction* action) {
          dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (existing) [weakSelf confirmOverwriteSlot:slot];
            else [weakSelf saveCurrentStateAtSlot:slot];
          });
        }]];
      }
      [alert addAction:[UIAlertAction actionWithTitle:[self localized:@"cancel"] style:UIAlertActionStyleCancel handler:nil]];
      [self presentModernMenu:alert from:controller];
    });
  });
}

- (void)loadSavestateIdentifier:(NSString*)identifier {
  if (!identifier.length) return;
  dispatch_async(_runtimeQueue, ^{
    NSString* titleId = [self.activeTitleId copy];
    if (!titleId.length) return;
    rpcs3_ios_status status = self->_api.stop_emulation();
    if (status == 0) status = self->_api.boot_game(titleId.UTF8String, identifier.UTF8String);
    if (status != 0) {
      NSString* originalError = [self lastError];
      // A rejected/corrupt state must not strand the user on a black surface.
      // Restore the normal title after preserving the original diagnostic.
      if (self->_api.stop_emulation) self->_api.stop_emulation();
      rpcs3_ios_status recovery = self->_api.boot_game(titleId.UTF8String, NULL);
      NSString* message = [self localizedSavestateError:originalError];
      if (recovery == 0) message = [NSString stringWithFormat:@"%@\n%@", message, [self localized:@"stateFreshRestart"]];
      [self showMessage:[self localized:@"state"] message:message];
      RPCS3Diagnostic(@"savestate_load_failed", [NSString stringWithFormat:@"%@ recovery=%d original=%@", identifier, recovery, originalError]);
    } else RPCS3Diagnostic(@"savestate_load", identifier);
  });
}

- (void)showLoadSavestateMenu {
  NSString* titleId = [self.activeTitleId copy];
  if (!titleId.length) return;
  dispatch_async(_runtimeQueue, ^{
    NSMutableArray<NSDictionary*>* states = [NSMutableArray array];
    rpcs3_ios_status status = self->_api.enumerate_savestates_live
        ? self->_api.enumerate_savestates_live(titleId.UTF8String, RPCS3CollectSavestate, (__bridge void*)states) : -1;
    if (status != 0) { [self showMessage:[self localized:@"states"] message:[self localizedSavestateError:[self lastError]]]; return; }
    NSDictionary<NSNumber*, NSDictionary*>* bySlot = [self statesBySlot:states titleId:titleId];
    dispatch_async(dispatch_get_main_queue(), ^{
      RPCS3GameViewController* controller = self.gameController;
      if (!controller || controller.presentedViewController) return;
      if (!bySlot.count) { [self showMessage:[self localized:@"states"] message:[self localized:@"noStates"]]; return; }
      UIAlertController* alert = [UIAlertController alertControllerWithTitle:[self localized:@"loadState"]
          message:nil preferredStyle:UIAlertControllerStyleActionSheet];
      NSDateFormatter* formatter = [NSDateFormatter new];
      formatter.dateStyle = NSDateFormatterShortStyle;
      formatter.timeStyle = NSDateFormatterMediumStyle;
      formatter.locale = [NSLocale localeWithLocaleIdentifier:self.activeUiLocale ?: @"en"];
      __weak Rpcs3InternalBridgePlugin* weakSelf = self;
      for (NSUInteger slot = 1; slot <= 10; ++slot) {
        NSDictionary* entry = bySlot[@(slot)];
        if (!entry) continue;
        NSString* identifier = entry[@"id"];
        BOOL compatible = [entry[@"compatible"] boolValue];
        int64_t modified = [entry[@"modified"] longLongValue];
        NSDate* date = modified > 0 ? [NSDate dateWithTimeIntervalSince1970:(NSTimeInterval)modified] : nil;
        NSString* dateText = date ? [formatter stringFromDate:date] : [self localized:@"unknownDate"];
        NSString* label = [NSString stringWithFormat:@"%@ %lu · %@%@", [self localized:@"slot"], (unsigned long)slot,
            dateText, compatible ? @"" : [@" · " stringByAppendingString:[self localized:@"incompatible"]]];
        UIAlertAction* action = [UIAlertAction actionWithTitle:label style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction* selected) {
          if (compatible) [weakSelf loadSavestateIdentifier:identifier];
          else [weakSelf showMessage:[weakSelf localized:@"state"] message:[weakSelf localized:@"incompatibleState"]];
        }];
        [alert addAction:action];
      }
      [alert addAction:[UIAlertAction actionWithTitle:[self localized:@"cancel"] style:UIAlertActionStyleCancel handler:nil]];
      [self presentModernMenu:alert from:controller];
    });
  });
}

- (void)performSessionCommand:(NSString*)command
                         value:(id)value
                    completion:(void (^)(BOOL success, NSString* message))completion {
  RPCS3GameViewController* controller = self.gameController;
  NSString* titleId = [self.activeTitleId copy];
  if (!controller || !titleId.length) {
    if (completion) completion(NO, [self localized:@"settingsFailed"]);
    return;
  }

  if ([command isEqual:@"performance"]) {
    BOOL visible = [value boolValue];
    controller.showingPerformance = visible;
    [controller.performanceOverlay reset];
    controller.performanceOverlay.hidden = !visible;
    controller.performanceButton.tintColor = visible ? UIColor.systemGreenColor : UIColor.whiteColor;
    controller.performanceButton.accessibilityValue =
        RPCS3LocalizedString(visible ? @"enabled" : @"disabled", controller.uiLocale);
    [self setPerformanceSamplingEnabled:visible];
    if (completion) completion(YES, @"");
    return;
  }

  if ([command isEqual:@"touchControls"]) {
    controller.inputController.touchControlsEnabled = [value boolValue];
    if (completion) completion(YES, @"");
    return;
  }

  NSString* setting = nil;
  NSString* settingValue = nil;
  if ([command isEqual:@"resolution"] && [value isKindOfClass:NSString.class]) {
    setting = @"gpu.resolution_scale";
    settingValue = value;
  } else if ([command isEqual:@"stretch"]) {
    setting = @"gpu.stretch_to_display";
    settingValue = [value boolValue] ? @"true" : @"false";
  } else if ([command isEqual:@"language"] && [value isKindOfClass:NSString.class]) {
    setting = @"system.language";
    settingValue = value;
  }
  if (!setting.length || !settingValue.length) {
    if (completion) completion(NO, [self localized:@"settingsFailed"]);
    return;
  }

  dispatch_async(_runtimeQueue, ^{
    if (self.operationBusy || !self->_api.stop_emulation ||
        !self->_api.set_game_setting || !self->_api.boot_game) {
      NSString* message = self.operationBusy ? [self localized:@"stateBusy"] : [self lastError];
      dispatch_async(dispatch_get_main_queue(), ^{
        if (completion) completion(NO, message ?: [self localized:@"settingsFailed"]);
      });
      return;
    }
    self.operationBusy = YES;
    rpcs3_ios_status status = self->_api.stop_emulation();
    if (status == 0)
      status = self->_api.set_game_setting(titleId.UTF8String, setting.UTF8String, settingValue.UTF8String);
    if (status == 0)
      status = self->_api.boot_game(titleId.UTF8String, NULL);
    NSString* message = status == 0 ? @"" : [self lastError];
    self.operationBusy = NO;
    if (status == 0)
      RPCS3Diagnostic(@"game_setting", [NSString stringWithFormat:@"%@ %@=%@", titleId, setting, settingValue]);
    dispatch_async(dispatch_get_main_queue(), ^{
      if (completion) completion(status == 0, status == 0 ? @"" : (message ?: [self localized:@"settingsFailed"]));
    });
  });
}

- (void)readSessionStates:(void (^)(NSDictionary<NSString*, id>* state))completion {
  NSString* titleId = [self.activeTitleId copy];
  if (!titleId.length || !completion) { if (completion) completion(nil); return; }
  dispatch_async(_runtimeQueue, ^{
    NSMutableArray<NSDictionary*>* states = [NSMutableArray array];
    rpcs3_ios_status status = self->_api.enumerate_savestates_live
        ? self->_api.enumerate_savestates_live(
              titleId.UTF8String, RPCS3CollectSavestate, (__bridge void*)states)
        : -1;
    if (status != 0) {
      dispatch_async(dispatch_get_main_queue(), ^{ completion(nil); });
      return;
    }
    NSDictionary<NSNumber*, NSDictionary*>* bySlot = [self statesBySlot:states titleId:titleId];
    NSMutableArray* slots = [NSMutableArray arrayWithCapacity:10];
    for (NSUInteger slot = 1; slot <= 10; ++slot) {
      NSDictionary* existing = bySlot[@(slot)];
      [slots addObject:@{
        @"slot": @(slot),
        @"exists": @(existing != nil),
        @"compatible": @(!existing || [existing[@"compatible"] boolValue]),
        @"modified": existing[@"modified"] ?: @0,
        @"id": existing[@"id"] ?: @"",
      }];
    }
    dispatch_async(dispatch_get_main_queue(), ^{ completion(@{@"slots": slots}); });
  });
}

- (void)waitForSessionSavestate:(NSUInteger)remaining
                     completion:(void (^)(BOOL success, NSString* message))completion {
  if (!completion) return;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                 _runtimeQueue, ^{
    uint32_t phase = 0;
    char reason[2048] = {};
    rpcs3_ios_status status = self->_api.get_savestate_status
        ? self->_api.get_savestate_status(&phase, reason, sizeof(reason)) : -1;
    if (status == 0 && phase >= 1 && phase <= 3 && remaining > 0) {
      [self waitForSessionSavestate:remaining - 1 completion:completion];
      return;
    }
    NSString* raw = reason[0] ? ([NSString stringWithUTF8String:reason] ?: @"") : [self lastError];
    BOOL success = status == 0 && phase == 4;
    NSString* message = success ? @"" : [self localizedSavestateError:raw];
    dispatch_async(dispatch_get_main_queue(), ^{ completion(success, message); });
  });
}

- (void)performSessionStateAtSlot:(NSInteger)slot
                             load:(BOOL)load
                       identifier:(NSString*)identifier
                       completion:(void (^)(BOOL success, NSString* message))completion {
  NSString* titleId = [self.activeTitleId copy];
  if (!titleId.length || slot < 1 || slot > 10 || !completion) {
    if (completion) completion(NO, [self localized:@"stateFailed"]);
    return;
  }
  dispatch_async(_runtimeQueue, ^{
    if (self.operationBusy) {
      dispatch_async(dispatch_get_main_queue(), ^{ completion(NO, [self localized:@"stateBusy"]); });
      return;
    }
    self.operationBusy = YES;
    if (!load) {
      rpcs3_ios_status status = self->_api.save_state_slot
          ? self->_api.save_state_slot((uint32_t)slot) : -1;
      if (status != 0) {
        NSString* message = [self localizedSavestateError:[self lastError]];
        self.operationBusy = NO;
        dispatch_async(dispatch_get_main_queue(), ^{ completion(NO, message); });
        return;
      }
      [self waitForSessionSavestate:240 completion:^(BOOL success, NSString* message) {
        self.operationBusy = NO;
        completion(success, message);
      }];
      return;
    }

    if (!identifier.length || !self->_api.stop_emulation || !self->_api.boot_game) {
      self.operationBusy = NO;
      dispatch_async(dispatch_get_main_queue(), ^{ completion(NO, [self localized:@"stateInvalid"]); });
      return;
    }
    rpcs3_ios_status status = self->_api.stop_emulation();
    if (status == 0) status = self->_api.boot_game(titleId.UTF8String, identifier.UTF8String);
    NSString* message = @"";
    if (status != 0) {
      NSString* original = [self lastError];
      if (self->_api.stop_emulation) self->_api.stop_emulation();
      rpcs3_ios_status recovery = self->_api.boot_game(titleId.UTF8String, NULL);
      message = [self localizedSavestateError:original];
      if (recovery == 0)
        message = [NSString stringWithFormat:@"%@\n%@", message, [self localized:@"stateFreshRestart"]];
    }
    self.operationBusy = NO;
    dispatch_async(dispatch_get_main_queue(), ^{ completion(status == 0, message); });
  });
}

- (void)showGameMenu {
  RPCS3GameViewController* controller = self.gameController;
  if (!controller || controller.presentedViewController) return;

  Rpcs3SessionMenu* menu = [Rpcs3SessionMenu new];
  menu.localeIdentifier = self.activeUiLocale ?: controller.uiLocale ?: @"en";
  menu.gameTitle = self.activeTitleId.length ? self.activeTitleId : @"RPCS3";
  menu.performanceVisible = controller.showingPerformance;
  menu.touchControlsVisible = controller.inputController.isTouchControlsEnabled;
  menu.languageChoices = [self languageChoices];

  __weak Rpcs3InternalBridgePlugin* weakSelf = self;
  __weak RPCS3GameViewController* weakController = controller;
  menu.performCommand = ^(NSString* command, id value,
                          void (^completion)(BOOL success, NSString* message)) {
    Rpcs3InternalBridgePlugin* bridge = weakSelf;
    if (!bridge) { if (completion) completion(NO, @""); return; }
    [bridge performSessionCommand:command value:value completion:completion];
  };
  menu.readStates = ^(void (^completion)(NSDictionary<NSString*, id>* state)) {
    Rpcs3InternalBridgePlugin* bridge = weakSelf;
    if (!bridge) { if (completion) completion(nil); return; }
    [bridge readSessionStates:completion];
  };
  menu.performStateOperation = ^(NSInteger slot, BOOL load, NSString* identifier,
                                 void (^completion)(BOOL success, NSString* message)) {
    Rpcs3InternalBridgePlugin* bridge = weakSelf;
    if (!bridge) { if (completion) completion(NO, @""); return; }
    [bridge performSessionStateAtSlot:slot load:load identifier:identifier completion:completion];
  };
  menu.resumeGame = ^{
    RPCS3GameViewController* owner = weakController;
    if (owner.presentedViewController)
      [owner dismissViewControllerAnimated:YES completion:nil];
  };
  menu.quitGame = ^{
    Rpcs3InternalBridgePlugin* bridge = weakSelf;
    RPCS3GameViewController* owner = weakController;
    if (!bridge || !owner) return;
    [owner dismissViewControllerAnimated:YES completion:^{
      [bridge stopAndDismiss:nil];
    }];
  };

  UINavigationController* navigation =
      [[UINavigationController alloc] initWithRootViewController:menu];
  navigation.modalPresentationStyle = UIModalPresentationOverFullScreen;
  navigation.modalInPresentation = YES;
  [controller presentViewController:navigation animated:YES completion:nil];
}

- (void)handleMethodCall:(FlutterMethodCall*)call result:(FlutterResult)result {
  if ([call.method isEqualToString:@"abortStartup"]) {
    // Queue behind initialize: never detach or unmap while the Core is still
    // preparing pages. A timeout of this operation remains a precise failure.
    dispatch_async(_runtimeQueue, ^{
      RPCS3JitAbortStartup(^(NSDictionary* closure) {
        dispatch_async(self->_runtimeQueue, ^{
          NSMutableDictionary* report = [closure mutableCopy];
          if ([closure[@"success"] boolValue]) {
            rpcs3_ios_status resetStatus = 0;
            if (self->_startupEntered && self->_api.reset_failed_startup)
              resetStatus = self->_api.reset_failed_startup();
            const int releaseStatus = self->_reservation.discard();
            BOOL reset = resetStatus == 0 && releaseStatus == 0 && !self->_reservation.poisoned;
            report[@"success"] = @(reset);
            report[@"retryable"] = @(reset);
            report[@"transactionClosed"] = @YES;
            report[@"code"] = reset ? @"RPCS3_STARTUP_ABORTED" :
                (releaseStatus ? @"RPCS3_VA_ROLLBACK_FAILED" : @"RPCS3_CORE_RESET_RESTART_REQUIRED");
            report[@"message"] = reset ? @"JIT transaction closed; uncommitted startup resources released." :
                [N  if ([call.method isEqualToString:@"abortStartup"]) {
    // Close only resources owned by this startup attempt. There is no host VA
    // reservation in Build 303: the recovery Core owns its adaptive arena.
    dispatch_async(_runtimeQueue, ^{
      RPCS3JitAbortStartup(^(NSDictionary* closure) {
        dispatch_async(self->_runtimeQueue, ^{
          NSMutableDictionary* report = [closure mutableCopy];
          if ([closure[@"success"] boolValue]) {
            rpcs3_ios_status shutdownStatus = 0;
            if (self->_startupEntered && self->_api.shutdown) {
              shutdownStatus = self->_api.shutdown();
            }
            const BOOL closed = shutdownStatus == 0;
            report[@"success"] = @(closed);
            report[@"transactionClosed"] = @YES;
            report[@"code"] = closed ? @"RPCS3_STARTUP_ABORTED" : @"RPCS3_CORE_SHUTDOWN_FAILED";
            report[@"message"] = closed
                ? @"JIT transaction closed and failed Core startup shut down."
                : [NSString stringWithFormat:@"Core shutdown status=%d; %@", shutdownStatus, [self lastError]];
            if (closed) {
              self->_startupEntered = NO;
              self.initialized = NO;
              self.llvmSelfTestPassed = NO;
            }
          }
          RPCS3Milestone(@"startup_abort_end", report[@"message"] ?: @"");
          dispatch_async(dispatch_get_main_queue(), ^{ result(report); });
        });
      });
    });
    return;
  }

  if ([call.method isEqualToString:@"verifyJitExecution"]) {
    dispatch_async(_runtimeQueue, ^{
      using SelfTest = rpcs3_ios_status (*)(uint64_t, uint64_t*);
      auto test = self->_api.handle ? reinterpret_cast<SelfTest>(dlsym(self->_api.handle, "rpcs3_ios_run_llvm_self_test")) : nullptr;
      uint64_t output = 0;
      rpcs3_ios_status status = -1;
      if (self.initialized && test && RPCS3JitTransactionIsClosed()) {
        RPCS3Milestone(@"llvm_self_test_begin", @"Executing generated ARM64 code after confirmed debugger closure");
        status = test(11, &output);
      }
      self.llvmSelfTestPassed = status == 0 && output == 40;
      NSString* message = [NSString stringWithFormat:@"status=%d input=11 output=%llu expected=40; %@", status, (unsigned long long)output, self.llvmSelfTestPassed ? @"passed" : [self lastError]];
      RPCS3Milestone(@"llvm_self_test_end", message);
      NSDictionary* report = @{@"success": @(self.llvmSelfTestPassed),
        @"code": self.llvmSelfTestPassed ? @"RPCS3_JIT_EXECUTION_VERIFIED" : @"RPCS3_LLVM_EXECUTION_FAILED",
        @"stage": @"llvm_execution", @"message": message, @"status": @(status), @"output": @(output)};
      dispatch_async(dispatch_get_main_queue(), ^{ result(report); });
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
      @"llvmSelfTestPassed": @(self.llvmSelfTestPassed),
      @"expandedJitRegion": @(self.initializedWithExpandedJit),
      @"jitReady": @(self.llvmSelfTestPassed && RPCS3JitTransactionIsClosed()),
      @"debuggerFlag": @(RPCS3HostIsDebugged()),
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

    // Build 303 recovery Core owns its adaptive JIT arena. The host only
    // controls startup ordering and never reserves or adopts fixed VA ranges.
    BOOL expanded = NO;
    dispatch_async(_runtimeQueue, ^{
      NSString* error = nil;
      if (self->_api.handle && !self.initialized) {
        if (@available(iOS 26.0, *)) {
          if (!RPCS3JitConfirmCoreLoadHandoff()) {
            dispatch_async(dispatch_get_main_queue(), ^{ result(@{@"success": @NO, @"code": @"RPCS3_JIT_NONCE_FAILED", @"message": @"RPCS3_JIT_NONCE_FAILED: current retry did not acknowledge the debugger nonce."}); });
            return;
          }
        }
      }
      if (![self loadCoreWithExpandedJit:expanded error:&error]) {
        NSString* message = error ?: @"RPCS3_CORE_LOAD_FAILED: Core unavailable";
        NSString* code = @"RPCS3_CORE_LOAD_FAILED";
        if ([message hasPrefix:@"RPCS3_"]) {
          code = [message componentsSeparatedByCharactersInSet:
              [NSCharacterSet characterSetWithCharactersInString:@" :\n"]].firstObject ?: code;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
          result(@{@"success": @NO, @"code": code, @"stage": @"core_load", @"message": message});
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
      self->_startupEntered = YES;
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
      RPCS3Milestone(@"rpcs3_initialize_begin", @"Calling explicit rpcs3_ios_initialize");
      RPCS3Milestone(@"core_initialize_begin", @"Calling rpcs3_ios_initialize");
      rpcs3_ios_status status = self->_api.initialize(&options);
      RPCS3Milestone(@"core_initialize_end", [NSString stringWithFormat:@"status=%d", status]);
      if (status == 0) {
        RPCS3Milestone(@"rpcs3_initialize_end", @"status=0");
        self.initialized = YES;
        self.initializedWithExpandedJit = expanded;
      } else {
        RPCS3Milestone(@"rpcs3_initialize_failed",
                       [NSString stringWithFormat:@"status=%d error=%@",
                                                  status, [self lastError]]);
      }
      NSMutableDictionary* payload = [[self statusPayload:status] mutableCopy];
      payload[@"expandedJitRegion"] = @(expanded);
      payload[@"stage"] = @"core_initialize";
      payload[@"nativeStatus"] = @(status);
      if (status != 0 && [payload[@"code"] hasPrefix:@"RPCS3_CORE_STATUS_"]) {
        payload[@"code"] = @"RPCS3_CORE_INITIALIZE_FAILED";
      }
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
      rpcs3_ios_status stopStatus = self->_api.stop_emulation ? self->_api.stop_emulation() : 0;
      if (stopStatus != 0) {
        NSDictionary* failure = [self statusPayload:stopStatus];
        dispatch_async(dispatch_get_main_queue(), ^{ result(failure); });
        return;
      }
      [self stopDiagnosticPerformanceSampling];
      if (self->_performanceTimer) { dispatch_source_cancel(self->_performanceTimer); self->_performanceTimer = nil; }
      if (self->_api.set_display_surface) self->_api.set_display_surface(NULL);
      [self deactivateRPCS3AudioSession];
      self.activeTitleId = nil;
      self.activeUiLocale = nil;
      rpcs3_ios_status status = self->_api.shutdown ? self->_api.shutdown() : 0;
      if (status == 0) {
        self.initialized = NO;
        self.llvmSelfTestPassed = NO;
        self.initializedWithExpandedJit = NO;
        self->_startupEntered = NO;
      }
      NSDictionary* payload = [self statusPayload:status];
      dispatch_async(dispatch_get_main_queue(), ^{
        RPCS3GameViewController* controller = self.gameController;
        [controller.inputController stop];
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
    NSString* uiLocale = [args[@"uiLocale"] isKindOfClass:NSString.class] ? args[@"uiLocale"] : @"en";
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
      controller.uiLocale = RPCS3CanonicalLocale(uiLocale);
      __weak Rpcs3InternalBridgePlugin* weakSelf = self;
      controller.closeHandler = ^{ [weakSelf stopAndDismiss:nil]; };
      controller.menuHandler = ^{ [weakSelf showGameMenu]; };
      controller.performanceToggleHandler = ^(BOOL visible) { [weakSelf setPerformanceSamplingEnabled:visible]; };
      [controller loadViewIfNeeded];
      controller.inputController = [[RPCS3GameInputController alloc] initWithHostView:controller.view api:&self->_api];
      [controller.inputController start];
      [controller.inputController layoutControlsInBounds:controller.view.bounds safeAreaInsets:controller.view.safeAreaInsets];
      [root presentViewController:controller animated:NO completion:nil];
      self.gameController = controller;
      self.activeTitleId = titleId;
      self.activeUiLocale = controller.uiLocale;
    };
    if (NSThread.isMainThread) present();
    else dispatch_sync(dispatch_get_main_queue(), present);
    if (!controller || !controller.metalLayer.device) { result(@{@"success": @NO, @"message": @"Metal surface could not be created."}); return; }
    CGSize size = controller.view.bounds.size;
    UIScreen* screen = controller.view.window.screen ?: UIScreen.mainScreen;
    CGFloat scale = screen.scale;
    float refreshRate = (float)screen.maximumFramesPerSecond;
    dispatch_async(_runtimeQueue, ^{
      if (!self.llvmSelfTestPassed || !RPCS3JitTransactionIsClosed()) {
        [self stopAndDismiss:nil];
        dispatch_async(dispatch_get_main_queue(), ^{
          result(@{@"success": @NO, @"code": @"RPCS3_STARTUP_NOT_VERIFIED",
            @"stage": @"game_boot", @"message": @"RPCS3_STARTUP_NOT_VERIFIED: complete startup and execution verification before boot."});
        });
        return;
      }
      NSString* audioError = nil;
      if (![self activateRPCS3AudioSession:&audioError]) {
        [self stopAndDismiss:nil];
        dispatch_async(dispatch_get_main_queue(), ^{
          result(@{@"success": @NO, @"message": audioError ?: @"RPCS3 audio session could not start."});
        });
        return;
      }
      rpcs3_ios_display_surface surface = {};
      surface.size = sizeof(surface);
      surface.width = MAX(1, (uint32_t)llround(size.width * scale));
      surface.height = MAX(1, (uint32_t)llround(size.height * scale));
      surface.refresh_rate = refreshRate;
      surface.metal_layer = (__bridge void*)controller.metalLayer;
      rpcs3_ios_status surfaceStatus = self->_api.set_display_surface(&surface);
      RPCS3Milestone(@"game_boot_begin", titleId);
      rpcs3_ios_status bootStatus = surfaceStatus == 0
          ? self->_api.boot_game(titleId.UTF8String, savestateId.length ? savestateId.UTF8String : NULL)
          : surfaceStatus;
      RPCS3Milestone(@"game_boot_return", [NSString stringWithFormat:@"%@ status=%d", titleId, bootStatus]);
      NSDictionary* payload = [self statusPayload:bootStatus];
      if (bootStatus == 0) [self startDiagnosticPerformanceSampling];
      else [self stopAndDismiss:nil];
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
    if (!ok) {
      [self showMessage:[self localized:@"state"] message:[self lastError]];
      dispatch_async(dispatch_get_main_queue(), ^{ if (result) result(@NO); });
      return; // Keep Metal, controls and audio attached while the save owns Emu.
    }
    [self stopDiagnosticPerformanceSampling];
    if (self->_performanceTimer) {
      dispatch_source_cancel(self->_performanceTimer);
      self->_performanceTimer = nil;
    }
    if (self.initialized && self->_api.set_display_surface) self->_api.set_display_surface(NULL);
    [self deactivateRPCS3AudioSession];
    self.activeTitleId = nil;
    self.activeUiLocale = nil;
    dispatch_async(dispatch_get_main_queue(), ^{
      RPCS3GameViewController* controller = self.gameController;
      [controller.inputController stop];
      controller.performanceToggleHandler = nil;
      self.gameController = nil;
      [controller dismissViewControllerAnimated:NO completion:nil];
      if (result) result(@(ok));
    });
  });
}

@end
