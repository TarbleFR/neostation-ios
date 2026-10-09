#import "LibretroSession.h"

#import "LibretroAchievements.h"
#import "LibretroAddressSpace.h"
#import "LibretroAudioOutput.h"
#import "LibretroChromeLayout.h"
#import "LibretroCoreHost.h"
#import "LibretroCoreOptions.h"
#import "LibretroDefaultSkins.h"
#import "LibretroFrontendMenu.h"
#import "LibretroFrontendStore.h"
#import "LibretroGLRenderer.h"
#import "LibretroGameViewController.h"
#import "LibretroGeometry.h"
#import "LibretroInputMap.h"
#import "LibretroInputState.h"
#import "LibretroJit.h"
#import "LibretroMetalPresenter.h"
#import "LibretroOrientation.h"
#import "LibretroSessionJournal.h"
#import "LibretroSessionMenu.h"
#import "LibretroShaderLibrary.h"
#import "LibretroSkin.h"
#import "LibretroSkinLayout.h"
#import "LibretroSkinRenderer.h"
#import "LibretroTouchOverlay.h"
#import "LibretroVulkanRenderer.h"

#include <mach/mach_time.h>
#include <math.h>
#include <stdatomic.h>

static const NSInteger kStateSlots = 5;
/// Quick save / quick load (frontend actions): slot 0, "<content>.state".
static const NSInteger kQuickSlot = 0;
/// Controls opacity while the user has chosen none: default skins, and
/// translucent imported skins (Delta's default).
static const double kDefaultSkinOpacity = 0.75;
static const double kImportedSkinOpacity = 0.7;
static const double kMinimumOpacity = 0.15;
/// Redraws of the last frame used to measure a shader preset.
static const NSUInteger kShaderMeasureIterations = 30;
/// Startup period: the launch is reported successful once the core has run
/// this many frames and this long (frame-to-frame time, at most 0.25 s per
/// frame, pauses excluded). Before that, a core that stops by itself (PPSSPP
/// when its boot fails) is a launch failure carrying its own error lines,
/// not a silent return to the library.
static const NSUInteger kStartupFrames = 60;
static const double kStartupSeconds = 5.0;
static const double kStartupFrameCap = 0.25;
/// Error lines of the core quoted in a LIBRETRO_CORE_STOPPED failure.
static const NSUInteger kStartupErrorLines = 4;

static NSString *SettingString(id value) {
  return [value isKindOfClass:NSString.class] && ((NSString *)value).length > 0 ? value : nil;
}

static NSDictionary *SettingDictionary(id value) {
  return [value isKindOfClass:NSDictionary.class] ? value : nil;
}

/// After the game is dismissed: the app's own orientations again
/// (LibretroOrientation rules).
static void LibretroRestoreAppOrientations(UIViewController *presenter) {
  LibretroOrientationSetGameMask(0);
  UIViewController *root = presenter.view.window.rootViewController;
  [root setNeedsUpdateOfSupportedInterfaceOrientations];
  if (presenter != nil && presenter != root) [presenter setNeedsUpdateOfSupportedInterfaceOrientations];
}

@implementation LibretroSessionConfiguration
@end

@interface LibretroSession () <LibretroCoreHostDelegate, LibretroGameViewLayoutSource, LibretroFrontendMenuHost>
@end

@implementation LibretroSession {
  LibretroSessionConfiguration *_configuration;
  LibretroInputState *_input;
  LibretroGameViewController *_controller;
  CAMetalLayer *_metalLayer;
  UINavigationController *_menu;
  LibretroMetalPresenter *_presenter;
  LibretroGLRenderer *_gl;
  LibretroVulkanRenderer *_vulkan;
  const struct retro_hw_render_context_negotiation_interface *_negotiation;
  LibretroAudioOutput *_audio;
  LibretroCoreHost *_host;
  LibretroAchievements *_achievements;
  NSThread *_thread;
  NSCondition *_condition;
  NSMutableArray<dispatch_block_t> *_commands;
  /// Quit requested by the user (menu, plugin "stop").
  BOOL _stopRequested;
  /// RETRO_ENVIRONMENT_SHUTDOWN from the core.
  BOOL _coreStopRequested;
  // Startup period (emulation thread).
  BOOL _startupConfirmed;
  NSUInteger _startupFrames;
  double _startupSeconds;
  LibretroSessionJournal *_journal;
  BOOL _menuPaused;
  BOOL _backgroundPaused;
  _Atomic bool _fastForward;
  BOOL _loaded;
  BOOL _hwFrameValid;
  unsigned _hwWidth;
  unsigned _hwHeight;
  BOOL _glNeedsResize;
  dispatch_semaphore_t _glFrameSemaphore;
  void (^_startCompletion)(NSDictionary<NSString *, id> *);
  NSMutableArray<dispatch_block_t> *_stopCompletions;
  NSMutableArray<NSMutableDictionary<NSString *, id> *> *_cheats;
  NSString *_cheatsPath;
  unsigned _diskCount;
  unsigned _diskIndex;
  NSArray<NSString *> *_diskLabels;
  BOOL _smooth;
  BOOL _touchControls;
  BOOL _started;
  NSArray<NSString *> *_finalLog;

  // Frontend: skins, screens, format, shaders, controls (main thread unless noted).
  NSString *_console;
  LibretroFrontendStore *_store;  // thread-safe, also read on the emulation thread
  LibretroInputMap *_inputMap;
  LibretroSkin *_defaultSkin;
  LibretroSkin *_currentSkin;
  LibretroSkinRepresentation *_currentRepresentation;
  LibretroSkinOrientation _currentOrientation;
  LibretroSize _viewSize;
  LibretroInsets _safeInsets;
  BOOL _iPad;
  NSMutableDictionary<NSString *, LibretroSkin *> *_skinCache;
  NSMutableSet<NSString *> *_failedSkins;
  BOOL _skinFailureShown;
  NSArray<LibretroSkin *> *_availableSkins;
  NSArray<LibretroPresenterScreen *> *_presenterScreens;
  NSArray<NSValue *> *_lastTouchMappings;
  LibretroFrontendMenu *_frontendMenu;
  BOOL _screensAndShadersAvailable;
  BOOL _editingControls;
  BOOL _fastForwardHeld;
  _Atomic bool _redrawPending;
  // Picture aspect the current layout was made for (pictureLayoutAspect).
  double _laidOutPictureAspect;
  _Atomic bool _pictureCheckPending;
}

- (instancetype)initWithConfiguration:(LibretroSessionConfiguration *)configuration {
  self = [super init];
  if (self) {
    _configuration = configuration;
    _input = [LibretroInputState new];
    _condition = [NSCondition new];
    _commands = [NSMutableArray array];
    _stopCompletions = [NSMutableArray array];
    _glFrameSemaphore = dispatch_semaphore_create(1);
    _cheats = [NSMutableArray array];
    _diskLabels = @[];
    _screensAndShadersAvailable = YES;
    _currentOrientation = LibretroSkinOrientationLandscape;
    _skinCache = [NSMutableDictionary dictionary];
    _failedSkins = [NSMutableSet set];
    _lastTouchMappings = @[];
    _presenterScreens = @[];
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    _smooth = [defaults objectForKey:@"libretro.smooth"] != nil ? [defaults boolForKey:@"libretro.smooth"] : NO;
    _touchControls =
        [defaults objectForKey:@"libretro.touchControls"] != nil ? [defaults boolForKey:@"libretro.touchControls"] : YES;
  }
  return self;
}

- (BOOL)active {
  return _thread != nil;
}

- (NSArray<NSString *> *)recentLog {
  return _host != nil ? _host.recentLog : (_finalLog ?: @[]);
}

#pragma mark - Text

- (NSString *)text:(NSString *)key {
  NSString *value = _configuration.uiText[key];
  return value.length > 0 ? value : key;
}

- (NSString *)text:(NSString *)key replacing:(NSString *)placeholder with:(NSString *)value {
  return [[self text:key] stringByReplacingOccurrencesOfString:placeholder withString:value ?: @""];
}

#pragma mark - Start and stop

- (void)startFromViewController:(UIViewController *)presenter
                     completion:(void (^)(NSDictionary<NSString *, id> *result))completion {
  _startCompletion = [completion copy];
  _journal = [LibretroSessionJournal journalInDirectory:_configuration.logsDirectory ?: @""];
  [_journal note:[NSString stringWithFormat:@"launch: \"%@\" (%@) with %@, console %@, locale %@",
                                            _configuration.gameTitle ?: @"",
                                            _configuration.contentPath.lastPathComponent ?: @"",
                                            _configuration.corePath.lastPathComponent ?: @"",
                                            _configuration.console ?: @"", _configuration.uiLocale ?: @""]];
  [self prepareFrontend];
  NSString *cacheDirectory =
      _configuration.cacheDirectory.length > 0 ? _configuration.cacheDirectory : NSTemporaryDirectory();
  _controller = [[LibretroGameViewController alloc] initWithInput:_input cacheDirectory:cacheDirectory];
  _controller.title = _configuration.gameTitle;
  _controller.menuAccessibilityLabel = [self text:@"menu"];
  _controller.touchControlsEnabled = _touchControls;
  _controller.allowedOrientations = UIInterfaceOrientationMaskAllButUpsideDown;
  _controller.layoutSource = self;
  __weak LibretroSession *weakSelf = self;
  _controller.menuHandler = ^{
    [weakSelf openMenu];
  };
  _controller.activeHandler = ^(BOOL active) {
    [weakSelf applicationActive:active];
  };
  _controller.screenMappingsProvider = ^NSArray<NSValue *> * {
    LibretroSession *session = weakSelf;
    return session != nil ? [session touchScreenMappings] : @[];
  };
  [_controller loadViewIfNeeded];
  _metalLayer = _controller.metalLayer;
  _presenter = [[LibretroMetalPresenter alloc] initWithLayer:_metalLayer];
  if (_presenter == nil) {
    _controller = nil;
    [_journal finishWithOutcome:@"launch failed LIBRETRO_VIDEO_FAILED (no Metal presenter)"];
    [self finishStartWithResult:@{@"success" : @NO, @"code" : @"LIBRETRO_VIDEO_FAILED", @"message" : @"Metal"}];
    return;
  }
  _presenter.smooth = _smooth;
  void (^actions)(LibretroFrontendAction, BOOL) = ^(LibretroFrontendAction action, BOOL pressed) {
    [weakSelf performFrontendAction:action pressed:pressed];
  };
  _controller.overlay.actionHandler = actions;
  _input.actionHandler = actions;
  [_controller setLoading:YES];
  // Portrait and landscape while the game is shown; restored to the app's
  // orientations only in the dismissal completion.
  LibretroOrientationSetGameMask(UIInterfaceOrientationMaskAllButUpsideDown);
  [presenter presentViewController:_controller
                          animated:NO
                        completion:^{
                          LibretroSession *session = weakSelf;
                          if (session == nil) return;
                          [session->_journal note:@"launch: game view presented, emulation thread starting"];
                          session->_thread = [[NSThread alloc] initWithTarget:session
                                                                     selector:@selector(threadMain)
                                                                       object:nil];
                          session->_thread.name = @"NeoStation libretro";
                          session->_thread.qualityOfService = NSQualityOfServiceUserInteractive;
                          session->_thread.stackSize = 16 * 1024 * 1024;
                          [session->_thread start];
                        }];
}

/// Console preferences: store, logical input map, default skin.
- (void)prepareFrontend {
  _console = [_configuration.console copy] ?: @"";
  _store = [LibretroFrontendStore storeWithDirectory:_configuration.frontendDirectory ?: @""];
  _inputMap = [LibretroInputMap mapForConsole:_console];
  _defaultSkin = [LibretroDefaultSkins skinForConsole:_console];
  _defaultSkin.name = [self text:@"skinDefaultName"];
  _currentSkin = _defaultSkin;
  [_input setInputMap:_inputMap gamepadRemap:[self gamepadRemap]];
}

- (void)finishStartWithResult:(NSDictionary<NSString *, id> *)result {
  void (^completion)(NSDictionary<NSString *, id> *) = _startCompletion;
  _startCompletion = nil;
  if (completion != nil) completion(result);
}

- (void)stopWithCompletion:(dispatch_block_t)completion {
  if (completion != nil) [_stopCompletions addObject:[completion copy]];
  if (_thread == nil) {
    [self finishStop];
    return;
  }
  [_journal note:@"stop: requested by the user"];
  [_condition lock];
  _stopRequested = YES;
  [_condition signal];
  [_condition unlock];
}

- (void)finishStop {
  _thread = nil;
  _finalLog = _host.recentLog;
  LibretroGameViewController *controller = _controller;
  _controller = nil;
  _menu = nil;
  _frontendMenu = nil;
  _editingControls = NO;
  _input.actionHandler = nil;
  [controller stopInputPolling];
  NSArray<dispatch_block_t> *completions = [_stopCompletions copy];
  [_stopCompletions removeAllObjects];
  BOOL notify = _started;
  _started = NO;
  UIViewController *presenter = controller.presentingViewController;
  LibretroSessionJournal *journal = _journal;
  NSArray<NSString *> *finalLog = _finalLog ?: @[];
  [journal note:@"stop: dismissing the game view"];
  dispatch_block_t done = ^{
    LibretroRestoreAppOrientations(presenter);
    [journal note:@"stop: game view dismissed, returning to NeoStation"];
    [journal noteLines:finalLog title:@"core log"];
    [journal finishWithOutcome:@"closed"];
    for (dispatch_block_t completion in completions) completion();
    if (notify && self.endedHandler != nil) self.endedHandler();
  };
  if (presenter != nil) {
    [presenter dismissViewControllerAnimated:NO completion:done];
  } else {
    done();
  }
}

- (void)failStartWithResult:(NSDictionary<NSString *, id> *)result {
  _thread = nil;
  _finalLog = result[@"log"];
  LibretroGameViewController *controller = _controller;
  _controller = nil;
  _menu = nil;
  _frontendMenu = nil;
  _editingControls = NO;
  _input.actionHandler = nil;
  [controller stopInputPolling];
  // A stop asked while the launch was failing is answered too.
  NSArray<dispatch_block_t> *completions = [_stopCompletions copy];
  [_stopCompletions removeAllObjects];
  UIViewController *presenter = controller.presentingViewController;
  LibretroSessionJournal *journal = _journal;
  NSString *code = [result[@"code"] isKindOfClass:NSString.class] ? result[@"code"] : @"";
  NSArray<NSString *> *finalLog = [_finalLog isKindOfClass:NSArray.class] ? _finalLog : @[];
  [journal note:[NSString stringWithFormat:@"launch failed %@: %@", code, result[@"message"] ?: @""]];
  dispatch_block_t done = ^{
    LibretroRestoreAppOrientations(presenter);
    [journal noteLines:finalLog title:@"core log"];
    [journal finishWithOutcome:[@"launch failed " stringByAppendingString:code]];
    [self finishStartWithResult:result];
    for (dispatch_block_t completion in completions) completion();
  };
  if (presenter != nil) {
    [presenter dismissViewControllerAnimated:NO completion:done];
  } else {
    done();
  }
}

#pragma mark - Emulation thread

- (void)threadMain {
  NSDictionary<NSString *, id> *failure = nil;
  @autoreleasepool {
    failure = [self loadContent];
  }
  if (failure != nil) {
    @autoreleasepool {
      [self unloadCore];
    }
    dispatch_async(dispatch_get_main_queue(), ^{
      [self failStartWithResult:failure];
    });
    return;
  }
  [_journal note:[NSString stringWithFormat:@"run: %@ %@ loaded, renderer %@", _host.libraryName ?: @"",
                                            _host.libraryVersion ?: @"", [self rendererName]]];
  dispatch_async(dispatch_get_main_queue(), ^{
    [self->_controller setLoading:NO];
  });
  [self runLoop];
  [_condition lock];
  BOOL coreStopped = _coreStopRequested && !_stopRequested;
  [_condition unlock];
  NSDictionary<NSString *, id> *startupFailure = nil;
  if (coreStopped) {
    [_journal note:[NSString stringWithFormat:@"run: the core requested shutdown after %lu frames",
                                              (unsigned long)_startupFrames]];
  }
  if (!_startupConfirmed) {
    if (coreStopped) {
      startupFailure = [self coreStoppedFailure];
    } else {
      // Left by the user before the end of the startup period: the game ran.
      [self confirmStartup];
    }
  }
  @autoreleasepool {
    [self unloadCore];
  }
  if (startupFailure != nil) {
    NSMutableDictionary<NSString *, id> *result = [startupFailure mutableCopy];
    result[@"log"] = _finalLog ?: @[];
    dispatch_async(dispatch_get_main_queue(), ^{
      [self failStartWithResult:result];
    });
    return;
  }
  dispatch_async(dispatch_get_main_queue(), ^{
    [self finishStop];
  });
}

- (NSString *)rendererName {
  return _gl != nil ? @"gles" : (_vulkan != nil ? @"vulkan" : @"software");
}

/// Emulation thread. Tells Dart the launch succeeded: the core has run for
/// the startup period, or the user left the game before its end.
- (void)confirmStartup {
  if (_startupConfirmed) return;
  _startupConfirmed = YES;
  [_journal note:[NSString stringWithFormat:@"run: startup confirmed after %lu frames (%.1f s)",
                                            (unsigned long)_startupFrames, _startupSeconds]];
  NSDictionary<NSString *, id> *success = @{
    @"success" : @YES,
    @"code" : @"",
    @"libraryName" : _host.libraryName ?: @"",
    @"libraryVersion" : _host.libraryVersion ?: @"",
    @"hardwareRendering" : [self rendererName],
    @"jitCapable" : @(LibretroJitUsableByCores()),
  };
  dispatch_async(dispatch_get_main_queue(), ^{
    self->_started = YES;
    [self finishStartWithResult:success];
  });
}

/// Emulation thread, after a frame of the startup period.
- (void)countStartupFrame:(uint64_t *)lastFrame {
  static mach_timebase_info_data_t timebase;
  if (timebase.denom == 0) mach_timebase_info(&timebase);
  uint64_t now = mach_absolute_time();
  if (*lastFrame != 0) {
    double seconds = (double)(now - *lastFrame) * timebase.numer / timebase.denom / 1e9;
    _startupSeconds += MIN(seconds, kStartupFrameCap);
  }
  *lastFrame = now;
  _startupFrames++;
  if (_host.shutdownRequested) return;
  if (_startupFrames >= kStartupFrames && _startupSeconds >= kStartupSeconds) [self confirmStartup];
}

/// LIBRETRO_CORE_STOPPED: the core asked to shut down (RETRO_ENVIRONMENT_SHUTDOWN)
/// before the startup period ended. The message quotes the core's last error
/// lines (PPSSPP logs why its boot failed); the log is added by the caller.
- (NSDictionary<NSString *, id> *)coreStoppedFailure {
  NSArray<NSString *> *errors = [_host recentErrors:kStartupErrorLines];
  NSString *detail = errors.count > 0
                         ? [errors componentsJoinedByString:@"\n"]
                         : [NSString stringWithFormat:@"%@ requested RETRO_ENVIRONMENT_SHUTDOWN after %lu frames",
                                                      _host.libraryName ?: @"the core",
                                                      (unsigned long)_startupFrames];
  return [self failureWithCode:@"LIBRETRO_CORE_STOPPED" detail:detail];
}

- (NSDictionary<NSString *, id> *)failureWithCode:(NSString *)code detail:(NSString *)detail {
  return @{
    @"success" : @NO,
    @"code" : code,
    @"message" : detail ?: @"",
    @"log" : _host.recentLog ?: @[],
  };
}

- (NSDictionary<NSString *, id> *)failureFromError:(NSError *)error {
  NSString *code = @"LIBRETRO_CORE_LOAD_FAILED";
  if ([error.domain isEqualToString:LibretroHostErrorDomain]) {
    switch ((LibretroHostError)error.code) {
      case LibretroHostErrorCoreMissing:
        code = @"LIBRETRO_CORE_MISSING";
        break;
      case LibretroHostErrorCoreIncompatible:
        code = @"LIBRETRO_CORE_INCOMPATIBLE";
        break;
      case LibretroHostErrorContentMissing:
        code = @"LIBRETRO_GAME_UNREADABLE";
        break;
      case LibretroHostErrorContentUnsupported:
        code = @"LIBRETRO_FORMAT_UNSUPPORTED";
        break;
      case LibretroHostErrorContentRejected:
        code = @"LIBRETRO_GAME_REJECTED";
        break;
      case LibretroHostErrorHardwareRenderUnavailable:
        code = @"LIBRETRO_HARDWARE_RENDER_FAILED";
        break;
      default:
        break;
    }
  }
  return [self failureWithCode:code detail:error.localizedDescription];
}

- (void)applyGeometry:(struct retro_game_geometry)geometry {
  float aspect = geometry.aspect_ratio;
  if (aspect <= 0 && geometry.base_height > 0) aspect = (float)geometry.base_width / (float)geometry.base_height;
  _presenter.aspectRatio = aspect;
  _vulkan.aspectRatio = aspect;
  [self pictureGeometryChanged];
}

/// Emulation thread: the core's aspect or rotation changed. The default
/// skin is laid out again on the main thread when the picture it was sized
/// for changed (coalesced: some cores send their geometry at every frame).
- (void)pictureGeometryChanged {
  if (atomic_exchange(&_pictureCheckPending, true)) return;
  __weak LibretroSession *weakSelf = self;
  dispatch_async(dispatch_get_main_queue(), ^{
    LibretroSession *session = weakSelf;
    if (session == nil) return;
    atomic_store(&session->_pictureCheckPending, false);
    if (session->_controller == nil) return;
    if (fabs([session pictureLayoutAspect] - session->_laidOutPictureAspect) < 1e-4) return;
    [session->_controller setNeedsSkinLayout];
  });
}

/// Main thread. The legacy Vulkan picture is aspect-fitted over the whole
/// view whatever the skin says: in portrait the default skin's opaque panel
/// would hide most of it, so the game stays in landscape, where the
/// controls are beside the picture (see adaptToLegacyPicture:viewSize:).
- (void)keepLandscapeForLegacyPicture {
  LibretroGameViewController *controller = _controller;
  if (controller == nil) return;
  UIInterfaceOrientationMask landscape = UIInterfaceOrientationMaskLandscape;
  // The app's own mask is landscape: the two always have orientations in common.
  LibretroOrientationSetGameMask(landscape);
  controller.allowedOrientations = landscape;
  UIViewController *root = controller.view.window.rootViewController;
  if (root != nil && root != controller) [root setNeedsUpdateOfSupportedInterfaceOrientations];
}

- (NSDictionary<NSString *, id> *)loadContent {
  LibretroSessionConfiguration *configuration = _configuration;
  _host = [[LibretroCoreHost alloc] initWithCorePath:configuration.corePath
                                     systemDirectory:configuration.systemDirectory
                                       saveDirectory:configuration.saveDirectory
                                      stateDirectory:configuration.stateDirectory
                                    optionsDirectory:configuration.optionsDirectory
                                      cacheDirectory:configuration.cacheDirectory
                                            language:configuration.retroLanguage
                                          jitCapable:LibretroJitUsableByCores()];
  _host.delegate = self;
  // Given to the option store before retro_set_environment and retro_init:
  // DeSmuME reads its options only in retro_init. Locked options (DS / 3DS
  // screen layout and pointer) win over everything and stay read-only.
  _host.initialOptionDefaults = configuration.optionDefaults.count > 0 ? configuration.optionDefaults : nil;
  _host.initialSessionOverrides =
      !LibretroJitUsableByCores() && configuration.noJitOverrides.count > 0 ? configuration.noJitOverrides : nil;
  _host.lockedSessionOverrides = configuration.lockedOptions.count > 0 ? configuration.lockedOptions : nil;
  NSError *error = nil;
  if (![_host loadCore:&error]) return [self failureFromError:error];
  [_journal note:[NSString stringWithFormat:@"load: core %@ %@ initialised", _host.libraryName ?: @"",
                                            _host.libraryVersion ?: @""]];
  if ([_host.libraryName isEqualToString:@"PPSSPP"]) {
    // PPSSPP maps the PSP memory at fixed addresses between 4 and 6 GiB
    // while it boots: record whether this process leaves room for it.
    NSString *report = LibretroPPSSPPAddressSpaceReport();
    [_host appendLog:report];
    [_journal note:report];
  }
  if (![_host loadContentAtPath:configuration.contentPath error:&error]) return [self failureFromError:error];
  [_journal note:[NSString stringWithFormat:@"load: content accepted (%@)",
                                            _host.usesHardwareRendering ? @"hardware rendering" : @"software"]];
  struct retro_system_av_info av = _host.avInfo;
  [self applyGeometry:av.geometry];
  _presenter.rotation = _host.rotation;
  BOOL shadersAvailable = YES;
  if (_host.usesHardwareRendering) {
    BOOL prepared = NO;
    if (_gl != nil) {
      prepared = [_gl prepareWithWidth:MAX(av.geometry.max_width, av.geometry.base_width)
                                height:MAX(av.geometry.max_height, av.geometry.base_height)
                                 error:&error];
    } else if (_vulkan != nil) {
      if (_negotiation != NULL) [_vulkan setNegotiationInterface:_negotiation];
      _vulkan.smooth = _smooth;
      _vulkan.aspectRatio = _presenter.aspectRatio;
      // Frames copied to host memory reach Metal like every other core.
      __weak LibretroMetalPresenter *weakPresenter = _presenter;
      _vulkan.frameHandler = ^(const void *pixels, unsigned width, unsigned height, size_t bytesPerRow,
                               MTLPixelFormat pixelFormat) {
        [weakPresenter presentPixels:pixels
                               width:width
                              height:height
                         bytesPerRow:bytesPerRow
                         pixelFormat:pixelFormat];
      };
      prepared = [_vulkan prepare:&error];
      if (prepared && !_vulkan.handsOffFrames) {
        // Legacy presentation on the layer: no screens, format or shaders.
        _vulkan.frameHandler = nil;
        shadersAvailable = NO;
        NSLog(@"[Libretro] Vulkan frames cannot reach Metal: legacy presentation without screens or shaders");
        __weak LibretroSession *weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
          LibretroSession *session = weakSelf;
          if (session == nil) return;
          session->_screensAndShadersAvailable = NO;
          [session keepLandscapeForLegacyPicture];
          [session->_controller setNeedsSkinLayout];
        });
      }
    }
    if (!prepared) return [self failureWithCode:@"LIBRETRO_HARDWARE_RENDER_FAILED" detail:error.localizedDescription];
    [_journal note:[NSString stringWithFormat:@"load: %@ context ready, context_reset called", [self rendererName]]];
    [_host hardwareContextReset];
  } else {
    [_presenter presentBlack];
  }
  if (shadersAvailable) [self applyStoredShader];
  _audio = [[LibretroAudioOutput alloc] initWithInputRate:av.timing.sample_rate];
  NSError *audioError = nil;
  if (![_audio start:&audioError]) {
    NSLog(@"[Libretro] audio output unavailable: %@", audioError);
    _audio = nil;
  }
  [self loadCheats];
  [self refreshDiskSnapshot];
  if (configuration.achievementsAllowed && configuration.achievementsConsoleId > 0) {
    _achievements = [[LibretroAchievements alloc] initWithConsoleId:configuration.achievementsConsoleId host:_host];
    __weak LibretroSession *weakSelf = self;
    _achievements.unlocked = ^(NSString *title) {
      LibretroSession *session = weakSelf;
      if (session == nil) return;
      [session showStatus:[session text:@"achievementsUnlocked" replacing:@"{title}" with:title]];
    };
    [_achievements startWithContentPath:configuration.contentPath];
  }
  _loaded = YES;
  return nil;
}

- (void)runLoop {
  static mach_timebase_info_data_t timebase;
  if (timebase.denom == 0) mach_timebase_info(&timebase);
  uint64_t next = mach_absolute_time();
  // Previous frame of the startup period; 0 after a pause.
  uint64_t lastStartupFrame = 0;
  while (YES) {
    @autoreleasepool {
      [_condition lock];
      while ((_menuPaused || _backgroundPaused) && !_stopRequested && !_coreStopRequested && _commands.count == 0) {
        [_achievements idle];
        [_condition waitUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.5]];
      }
      NSArray<dispatch_block_t> *commands = [_commands copy];
      [_commands removeAllObjects];
      BOOL stop = _stopRequested || _coreStopRequested || _host.shutdownRequested;
      BOOL paused = _menuPaused || _backgroundPaused;
      [_condition unlock];
      for (dispatch_block_t command in commands) command();
      if (stop) break;
      if (paused) {
        next = mach_absolute_time();
        lastStartupFrame = 0;
        continue;
      }
      [self runOneFrame];
      if (!_startupConfirmed) [self countStartupFrame:&lastStartupFrame];
      double fps = _host.avInfo.timing.fps > 1.0 ? _host.avInfo.timing.fps : 60.0;
      bool fast = atomic_load(&_fastForward);
      double seconds = 1.0 / (fps * (fast ? 3.0 : 1.0));
      uint64_t period = (uint64_t)(seconds * 1e9 * timebase.denom / timebase.numer);
      next += period;
      uint64_t now = mach_absolute_time();
      if (next > now) {
        mach_wait_until(next);
      } else if (now - next > period * 4) {
        next = now;
      }
    }
  }
}

- (void)runOneFrame {
  BOOL gl = _gl != nil;
  if (gl) {
    dispatch_semaphore_wait(_glFrameSemaphore, DISPATCH_TIME_FOREVER);
    [_gl makeCurrent];
  }
  _hwFrameValid = NO;
  if (_vulkan != nil) [_vulkan beginFrame];
  [_host runFrame];
  if (_vulkan != nil) {
    [_vulkan endFrameWithWidth:_hwWidth height:_hwHeight valid:_hwFrameValid];
  } else if (gl) {
    if (_hwFrameValid) {
      id<MTLTexture> texture = [_gl finishFrame];
      dispatch_semaphore_t semaphore = _glFrameSemaphore;
      if (texture != nil) {
        [_presenter presentTexture:texture
                             width:_hwWidth
                            height:_hwHeight
                           flipped:_gl.bottomLeftOrigin
                        completion:^{
                          dispatch_semaphore_signal(semaphore);
                        }];
      } else {
        dispatch_semaphore_signal(semaphore);
      }
    } else {
      dispatch_semaphore_signal(_glFrameSemaphore);
    }
    if (_glNeedsResize) {
      _glNeedsResize = NO;
      struct retro_system_av_info av = _host.avInfo;
      // The presenter keeps the last texture for redraws: it is released, and
      // the GPU has finished with it, before the IOSurface is reallocated.
      dispatch_semaphore_wait(_glFrameSemaphore, DISPATCH_TIME_FOREVER);
      [_presenter invalidateLastFrame];
      [_gl prepareWithWidth:av.geometry.max_width height:av.geometry.max_height error:nil];
      dispatch_semaphore_signal(_glFrameSemaphore);
    }
  }
  [_achievements doFrame];
}

/// Emulation thread. RetroArch's order: context_destroy, then
/// retro_unload_game and retro_deinit with the GL context current or the
/// Vulkan device alive (the core frees its renderer there: Azahar destroys
/// its Vulkan objects through this device in retro_unload_game), then the
/// renderer is released. Releasing the device first made the core use a
/// destroyed VkDevice when a 3DS game was closed.
- (void)unloadCore {
  [_journal note:@"teardown: started"];
  [_achievements shutdown];
  _achievements = nil;
  [_audio stop];
  _audio = nil;
  LibretroGLRenderer *gl = _gl;
  LibretroVulkanRenderer *vulkan = _vulkan;
  LibretroCoreHost *host = _host;
  LibretroMetalPresenter *presenter = _presenter;
  LibretroSessionJournal *journal = _journal;
  dispatch_semaphore_t semaphore = _glFrameSemaphore;
  __block BOOL glFrameHeld = NO;
  host.teardownObserver = ^(NSString *step, BOOL finished) {
    [journal note:[NSString stringWithFormat:@"teardown: %@ %@", step, finished ? @"returned" : @"called"]];
  };
  [host unloadWithContextDestroy:^{
    if (gl != nil) {
      // Waits for the frame the GPU may still read and drops the presenter's
      // reference; no frame is presented until the IOSurface is released.
      glFrameHeld =
          dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, (int64_t)NSEC_PER_SEC)) == 0;
      [presenter invalidateLastFrame];
      [gl makeCurrent];
    }
    if (vulkan != nil) {
      vulkan.frameHandler = nil;
      [vulkan waitIdle];
    }
    [journal note:@"teardown: context_destroy called"];
    [host hardwareContextDestroy];
    [journal note:@"teardown: context_destroy returned"];
  }
      contextRelease:^{
        [journal note:[NSString stringWithFormat:@"teardown: releasing the %@ renderer",
                                                 gl != nil ? @"OpenGL ES" : (vulkan != nil ? @"Vulkan" : @"software")]];
        if (gl != nil) {
          [gl teardown];
          if (glFrameHeld) dispatch_semaphore_signal(semaphore);
        }
        if (vulkan != nil) [vulkan teardown];
        [journal note:@"teardown: renderer released"];
      }];
  host.teardownObserver = nil;
  _finalLog = _host.recentLog;
}

- (void)enqueue:(dispatch_block_t)command {
  [_condition lock];
  [_commands addObject:[command copy]];
  [_condition signal];
  [_condition unlock];
}

#pragma mark - LibretroCoreHostDelegate (emulation thread)

- (void)coreHost:(LibretroCoreHost *)host
      videoFrame:(const void *)data
           width:(unsigned)width
          height:(unsigned)height
           pitch:(size_t)pitch {
  if (data == RETRO_HW_FRAME_BUFFER_VALID) {
    _hwFrameValid = YES;
    _hwWidth = width;
    _hwHeight = height;
    return;
  }
  if (data == NULL || _gl != nil || _vulkan != nil) return;
  [_presenter presentSoftwareFrame:data width:width height:height pitch:pitch format:host.pixelFormat];
}

- (void)coreHost:(LibretroCoreHost *)host audioFrames:(const int16_t *)frames count:(size_t)count {
  if (atomic_load(&_fastForward)) return;
  [_audio pushFrames:frames count:count];
}

- (void)coreHost:(LibretroCoreHost *)host fillInput:(LibretroInputSnapshot *)snapshot {
  [_input snapshot:snapshot];
}

- (BOOL)coreHost:(LibretroCoreHost *)host prepareHardwareRender:(struct retro_hw_render_callback *)callback {
  if (callback->context_type == RETRO_HW_CONTEXT_VULKAN) {
    if (_metalLayer == nil) return NO;
    _vulkan = [LibretroVulkanRenderer rendererForCallback:callback layer:_metalLayer];
    if (_vulkan != nil && _negotiation != NULL) [_vulkan setNegotiationInterface:_negotiation];
    return _vulkan != nil;
  }
  _gl = [LibretroGLRenderer rendererForCallback:callback device:_presenter.device];
  return _gl != nil;
}

- (unsigned)preferredHardwareContextForCoreHost:(LibretroCoreHost *)host {
  unsigned preferred = _configuration.preferredHardwareContext;
  return preferred != RETRO_HW_CONTEXT_NONE ? preferred : RETRO_HW_CONTEXT_OPENGLES3;
}

- (const struct retro_hw_render_interface *)hardwareRenderInterfaceForCoreHost:(LibretroCoreHost *)host {
  return [_vulkan renderInterface];
}

- (BOOL)coreHost:(LibretroCoreHost *)host
    setNegotiationInterface:(const struct retro_hw_render_context_negotiation_interface *)negotiation {
  if (negotiation->interface_type != RETRO_HW_RENDER_CONTEXT_NEGOTIATION_INTERFACE_VULKAN) return NO;
  _negotiation = negotiation;
  if (_vulkan != nil) [_vulkan setNegotiationInterface:negotiation];
  return YES;
}

- (unsigned)coreHost:(LibretroCoreHost *)host
    negotiationVersionForType:(enum retro_hw_render_context_negotiation_interface_type)type {
  return [LibretroVulkanRenderer negotiationVersionForType:type];
}

- (void)coreHost:(LibretroCoreHost *)host geometryChanged:(struct retro_game_geometry)geometry {
  [self applyGeometry:geometry];
}

- (void)coreHost:(LibretroCoreHost *)host timingChanged:(struct retro_system_av_info)avInfo {
  [self applyGeometry:avInfo.geometry];
  [_audio setInputRate:avInfo.timing.sample_rate];
  if (_gl != nil) _glNeedsResize = YES;
}

- (void)coreHost:(LibretroCoreHost *)host rotationChanged:(unsigned)rotation {
  _presenter.rotation = rotation;
  [self pictureGeometryChanged];
}

- (void)coreHost:(LibretroCoreHost *)host message:(NSString *)message durationMilliseconds:(unsigned)duration {
  // Core messages are untranslated core text: kept in the diagnostics log only.
}

- (void)coreHostRequestedShutdown:(LibretroCoreHost *)host {
  // Kept apart from a user stop: during the startup period it is a failure.
  [_condition lock];
  _coreStopRequested = YES;
  [_condition signal];
  [_condition unlock];
}

- (unsigned)audioBufferOccupancyForCoreHost:(LibretroCoreHost *)host {
  return _audio != nil ? _audio.occupancyPercent : 50;
}

#pragma mark - Pausing

- (void)applicationActive:(BOOL)active {
  [_condition lock];
  _backgroundPaused = !active;
  [_condition signal];
  [_condition unlock];
  if (!active && _loaded) {
    LibretroCoreHost *host = _host;
    [self enqueue:^{
      [host flushSaveRAM:nil];
    }];
  }
  if (active) [self requestRedraw];
}

- (void)setMenuPaused:(BOOL)paused {
  [_condition lock];
  _menuPaused = paused;
  [_condition signal];
  [_condition unlock];
  if (paused && _loaded) {
    LibretroCoreHost *host = _host;
    LibretroVulkanRenderer *vulkan = _vulkan;
    [self enqueue:^{
      // The newest Vulkan frame is the one kept on screen while paused.
      if (vulkan.handsOffFrames) [vulkan flushPendingFrame];
      [host flushSaveRAM:nil];
    }];
  }
}

#pragma mark - Redraws while paused

/// Coalesced redraw of the last frame (format, screens, shader or skin
/// changed while the game is paused). Main thread.
- (void)requestRedraw {
  if (!_loaded || !_screensAndShadersAvailable || _presenter == nil) return;
  if (atomic_exchange(&_redrawPending, true)) return;
  __weak LibretroSession *weakSelf = self;
  [self enqueue:^{
    LibretroSession *session = weakSelf;
    if (session == nil) return;
    atomic_store(&session->_redrawPending, false);
    [session redrawLastFrameIfPaused];
  }];
}

/// Emulation thread. A running game redraws at its next frame; Metal work
/// is never submitted while the application is inactive.
- (void)redrawLastFrameIfPaused {
  [_condition lock];
  BOOL redraw = _menuPaused && !_backgroundPaused && !_stopRequested;
  [_condition unlock];
  if (!redraw || !_loaded) return;
  if (_vulkan != nil) {
    if (!_vulkan.handsOffFrames) return;
    [_vulkan flushPendingFrame];
  }
  if (_gl != nil) {
    // The OpenGL frame is shared with the core: no core frame may render into
    // it while the presenter reads it.
    dispatch_semaphore_wait(_glFrameSemaphore, DISPATCH_TIME_FOREVER);
    dispatch_semaphore_t drawn = dispatch_semaphore_create(0);
    if ([_presenter representLastFrameWithCompletion:^{
          dispatch_semaphore_signal(drawn);
        }]) {
      dispatch_semaphore_wait(drawn, dispatch_time(DISPATCH_TIME_NOW, (int64_t)NSEC_PER_SEC));
    }
    dispatch_semaphore_signal(_glFrameSemaphore);
    return;
  }
  [_presenter representLastFrameWithCompletion:nil];
}

#pragma mark - Frontend settings

- (NSString *)gameScopeKey {
  return _configuration.gameKey.length > 0 ? _configuration.gameKey : nil;
}

/// Resolved value: game, else console, else nil (NeoStation default).
/// Thread-safe.
- (id)settingValue:(NSString *)key {
  return [_store valueForKey:key console:_console game:[self gameScopeKey] scope:NULL];
}

- (NSDictionary<NSString *, NSString *> *)gamepadRemap {
  NSDictionary *stored = SettingDictionary([self settingValue:LibretroSettingGamepad]);
  NSMutableDictionary<NSString *, NSString *> *remap = [NSMutableDictionary dictionary];
  for (id element in stored) {
    id input = stored[element];
    if ([element isKindOfClass:NSString.class] && [input isKindOfClass:NSString.class]) remap[element] = input;
  }
  return remap;
}

- (NSDictionary<NSString *, NSArray<NSString *> *> *)touchRemapForSkin:(LibretroSkin *)skin {
  NSString *skinId = skin.installedIdentifier;
  if (skinId.length == 0) return @{};
  NSDictionary *stored = SettingDictionary([self settingValue:LibretroSettingTouchRemapKey(skinId)]);
  NSMutableDictionary<NSString *, NSArray<NSString *> *> *remap = [NSMutableDictionary dictionary];
  for (id item in stored) {
    id inputs = stored[item];
    if (![item isKindOfClass:NSString.class] || ![inputs isKindOfClass:NSArray.class]) continue;
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (id input in (NSArray *)inputs) {
      if ([input isKindOfClass:NSString.class]) [names addObject:input];
    }
    remap[item] = names;
  }
  return remap;
}

- (NSDictionary<NSString *, NSDictionary *> *)layoutOverridesForSkin:(LibretroSkin *)skin
                                                         orientation:(LibretroSkinOrientation)orientation {
  NSString *skinId = skin.installedIdentifier;
  if (skinId.length == 0) return @{};
  NSString *key = LibretroSettingLayoutKey(skinId, LibretroSkinOrientationName(orientation));
  NSDictionary *stored = SettingDictionary([self settingValue:key]);
  NSMutableDictionary<NSString *, NSDictionary *> *overrides = [NSMutableDictionary dictionary];
  for (id item in stored) {
    id value = stored[item];
    if ([item isKindOfClass:NSString.class] && [value isKindOfClass:NSDictionary.class]) overrides[item] = value;
  }
  return overrides;
}

- (CGFloat)opacityForRepresentation:(LibretroSkinRepresentation *)representation {
  id stored = [self settingValue:LibretroSettingOpacity];
  if ([stored isKindOfClass:NSNumber.class]) {
    double opacity = [stored doubleValue];
    if (isfinite(opacity)) return MIN(MAX(opacity, kMinimumOpacity), 1.0);
  }
  return representation.generated ? kDefaultSkinOpacity : kImportedSkinOpacity;
}

- (BOOL)screensSwapped {
  id stored = [self settingValue:LibretroSettingScreensSwapped];
  return [stored isKindOfClass:NSNumber.class] && [stored boolValue];
}

- (NSDictionary *)consoleGeometryEntry {
  return SettingDictionary(_configuration.consoleGeometry[_console]);
}

- (NSDictionary<NSString *, NSArray<NSNumber *> *> *)consoleRegions {
  return SettingDictionary([self consoleGeometryEntry][@"regions"]);
}

/// Display aspect of the whole picture as the screen format shows it: the
/// fixed ratio chosen (4:3, 16:9, 16:10), else the core's after rotation
/// (Original, Stretch); 0 while the core has given none. The default
/// single-screen skins size their portrait game area with it, so a
/// vertical arcade game gets a tall area. Main thread.
- (double)displayedPictureAspect {
  switch (LibretroScreenFormatFromIdentifier(SettingString([self settingValue:LibretroSettingScreenFormat]))) {
    case LibretroScreenFormat4x3:
      return 4.0 / 3.0;
    case LibretroScreenFormat16x9:
      return 16.0 / 9.0;
    case LibretroScreenFormat16x10:
      return 16.0 / 10.0;
    case LibretroScreenFormatOriginal:
    case LibretroScreenFormatStretch:
      break;
  }
  LibretroMetalPresenter *presenter = _presenter;
  if (presenter == nil) return 0;
  return LibretroSourceAspect(presenter.aspectRatio, LibretroRectUnit, presenter.rotation);
}

/// The picture aspect a layout depends on: the core's own aspect for the
/// legacy Vulkan picture (fitted by the renderer, without format or
/// rotation), the displayed aspect for single-screen consoles, none for the
/// DS / 3DS screens (their shapes are fixed). Main thread.
- (double)pictureLayoutAspect {
  if (!_screensAndShadersAvailable) return _presenter != nil ? (double)_presenter.aspectRatio : 0;
  if ([LibretroDefaultSkins isDualScreenConsole:_console]) return 0;
  return [self displayedPictureAspect];
}

/// Console pixels of the whole core picture ({0, 0} when unknown, arcade).
- (LibretroSize)consoleNominalSize {
  NSArray *size = [self consoleGeometryEntry][@"size"];
  if (![size isKindOfClass:NSArray.class] || size.count < 2 || ![size[0] isKindOfClass:NSNumber.class] ||
      ![size[1] isKindOfClass:NSNumber.class]) {
    return (LibretroSize){0, 0};
  }
  double width = [size[0] doubleValue], height = [size[1] doubleValue];
  if (!isfinite(width) || !isfinite(height) || width <= 0 || height <= 0) return (LibretroSize){0, 0};
  return (LibretroSize){width, height};
}

#pragma mark - Skins

/// Imported skin `identifier` compatible with this console, parsed once per
/// session; nil when missing or unparsable (logged, and announced once
/// when `report`).
- (LibretroSkin *)importedSkinWithIdentifier:(NSString *)identifier report:(BOOL)report {
  if (!LibretroSkinIdentifierIsValid(identifier) || [identifier isEqualToString:LibretroDefaultSkinIdentifier]) {
    return nil;
  }
  LibretroSkin *cached = _skinCache[identifier];
  if (cached != nil) return cached;
  if (![_failedSkins containsObject:identifier]) {
    NSString *root = _configuration.skinsDirectory;
    NSString *code = nil;
    LibretroSkin *skin = nil;
    if (root.length > 0) {
      skin = [LibretroSkin skinWithDirectory:[root stringByAppendingPathComponent:identifier]
                             consoleGeometry:_configuration.consoleGeometry
                                   errorCode:&code];
    }
    if (skin != nil && [skin.consoles containsObject:_console]) {
      _skinCache[identifier] = skin;
      return skin;
    }
    NSLog(@"[Libretro] skin %@ not usable for %@: %@", identifier, _console, code ?: @"other console");
    [_failedSkins addObject:identifier];
  }
  if (report && !_skinFailureShown) {
    _skinFailureShown = YES;
    __weak LibretroSession *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
      LibretroSession *session = weakSelf;
      if (session == nil) return;
      [session showStatus:[session text:@"skinLoadFailed"]];
    });
  }
  return nil;
}

/// Skin chosen for an orientation (game, else console); the default skin
/// when none is chosen or the chosen one cannot be loaded.
- (LibretroSkin *)selectedSkinForOrientation:(LibretroSkinOrientation)orientation {
  NSString *key =
      orientation == LibretroSkinOrientationPortrait ? LibretroSettingSkinPortrait : LibretroSettingSkinLandscape;
  NSString *identifier = SettingString([self settingValue:key]);
  if (identifier == nil || [identifier isEqualToString:LibretroDefaultSkinIdentifier]) return _defaultSkin;
  return [self importedSkinWithIdentifier:identifier report:YES] ?: _defaultSkin;
}

/// NeoStation's skin generated for the view: DS / 3DS arrangement and
/// swap from the settings, screen regions from the core catalog, portrait
/// game area of single-screen consoles from the displayed picture aspect.
- (LibretroSkinRepresentation *)defaultRepresentationForOrientation:(LibretroSkinOrientation)orientation
                                                           viewSize:(LibretroSize)size
                                                         safeInsets:(LibretroInsets)insets
                                                               iPad:(BOOL)iPad {
  NSString *arrangement = nil;
  BOOL dual = [LibretroDefaultSkins isDualScreenConsole:_console];
  if (dual) {
    NSString *key = orientation == LibretroSkinOrientationPortrait ? LibretroSettingArrangementPortrait
                                                                    : LibretroSettingArrangementLandscape;
    NSString *stored = SettingString([self settingValue:key]);
    if (stored != nil &&
        [[LibretroDefaultSkins arrangementsForConsole:_console orientation:orientation] containsObject:stored]) {
      arrangement = stored;
    }
  }
  LibretroSkinRepresentation *representation =
      [LibretroDefaultSkins representationForConsole:_console
                                         orientation:orientation
                                            viewSize:size
                                          safeInsets:insets
                                                iPad:iPad
                                         arrangement:arrangement
                                             swapped:[self screensSwapped]
                                             regions:[self consoleRegions]
                                          coreAspect:dual ? 0 : [self displayedPictureAspect]];
  if (!_screensAndShadersAvailable) [self adaptToLegacyPicture:representation viewSize:size];
  return representation;
}

/// Legacy Vulkan presentation (frames cannot reach Metal): the renderer
/// draws the whole picture aspect-fitted over the full view, whatever the
/// skin says (LibretroVulkanRenderer). The default skin then shows one
/// "full" screen exactly there, which is the touch screen of the DS / 3DS
/// (as touchScreenMappings reports it), and no opaque panel that would hide
/// it. The game is also kept in landscape (keepLandscapeForLegacyPicture),
/// where the controls stand beside the picture.
- (void)adaptToLegacyPicture:(LibretroSkinRepresentation *)representation viewSize:(LibretroSize)size {
  double aspect = _presenter != nil ? (double)_presenter.aspectRatio : 0;
  LibretroRect picture = LibretroRectAspectFit(LibretroRectMake(0, 0, size.w, size.h), aspect);
  BOOL touch = _inputMap.hasTouchScreen;
  LibretroSkinScreen *screen = [LibretroSkinScreen new];
  screen.role = @"full";
  screen.source = LibretroRectUnit;
  screen.outputFrame = picture;
  screen.hasOutputFrame = YES;
  screen.touchScreen = touch;
  representation.screens = @[ screen ];
  NSMutableArray<LibretroSkinItem *> *items = [NSMutableArray array];
  for (LibretroSkinItem *item in representation.items) {
    if (item.kind != LibretroSkinItemKindTouchScreen) [items addObject:item];
  }
  if (touch) {
    LibretroSkinItem *touchItem = [LibretroSkinItem new];
    touchItem.identifier = @"touchScreen";
    touchItem.kind = LibretroSkinItemKindTouchScreen;
    touchItem.shape = LibretroSkinItemShapeNone;
    touchItem.inputs = @[ @"touchScreen" ];
    touchItem.frame = picture;
    touchItem.hitFrame = picture;
    touchItem.assetFrame = picture;
    touchItem.movable = NO;
    [items addObject:touchItem];
  }
  representation.items = items;
  representation.panelColor = 0;
  representation.panelFrame = LibretroRectMake(0, 0, 0, 0);
}

/// View size and safe insets for an orientation: the current ones, or
/// the rotated view with typical insets (previews of the other orientation).
- (void)viewSize:(LibretroSize *)size insets:(LibretroInsets *)insets forOrientation:(LibretroSkinOrientation)orientation {
  if (orientation == _currentOrientation) {
    *size = _viewSize;
    *insets = _safeInsets;
    return;
  }
  *size = (LibretroSize){_viewSize.h, _viewSize.w};
  LibretroInsets current = _safeInsets;
  BOOL notched = current.top + current.left + current.bottom + current.right > 0;
  if (_iPad || !notched) {
    *insets = current;
  } else if (orientation == LibretroSkinOrientationPortrait) {
    *insets = (LibretroInsets){MAX(current.left, current.right), 0, current.bottom > 0 ? 34 : 0, 0};
  } else {
    *insets = (LibretroInsets){0, current.top, current.bottom > 0 ? 21 : 0, current.top};
  }
}

#pragma mark - LibretroGameViewLayoutSource (main thread)

- (LibretroSkinRepresentation *)representationForOrientation:(LibretroSkinOrientation)orientation
                                                    viewSize:(LibretroSize)size
                                                  safeInsets:(LibretroInsets)insets
                                                        iPad:(BOOL)iPad {
  _currentOrientation = orientation;
  _viewSize = size;
  _safeInsets = insets;
  _iPad = iPad;
  _laidOutPictureAspect = [self pictureLayoutAspect];
  LibretroSkin *skin = [self selectedSkinForOrientation:orientation];
  LibretroSkinRepresentation *representation = nil;
  if (skin != _defaultSkin) {
    // No orientation fallback inside a skin: the default skin is used for
    // an orientation the chosen skin lacks (the Skins page says so).
    representation = [skin representationForOrientation:orientation iPad:iPad edgeToEdge:insets.bottom > 0];
    if (representation == nil) skin = _defaultSkin;
  }
  if (representation == nil) {
    representation = [self defaultRepresentationForOrientation:orientation viewSize:size safeInsets:insets iPad:iPad];
  }
  _currentSkin = skin;
  _currentRepresentation = representation;
  return representation;
}

- (NSDictionary<NSString *, NSDictionary *> *)layoutOverridesForRepresentation:
    (LibretroSkinRepresentation *)representation {
  LibretroSkin *skin = representation.generated ? _defaultSkin : (_currentSkin ?: _defaultSkin);
  return [self layoutOverridesForSkin:skin orientation:representation.orientation];
}

- (void)gameViewDidLayout:(LibretroSkinLayoutResult *)layout
           representation:(LibretroSkinRepresentation *)representation
             drawableSize:(CGSize)drawableSize
                   points:(CGSize)pointSize {
  LibretroScreenFormat format =
      LibretroScreenFormatFromIdentifier(SettingString([self settingValue:LibretroSettingScreenFormat]));
  LibretroSize nominal = [self consoleNominalSize];
  double width = pointSize.width > 0 ? pointSize.width : 1;
  double height = pointSize.height > 0 ? pointSize.height : 1;
  NSMutableArray<LibretroPresenterScreen *> *screens = [NSMutableArray array];
  for (LibretroLaidOutScreen *screen in layout.screens) {
    LibretroRect points = screen.container;
    LibretroRect container = LibretroRectMake(points.x / width, points.y / height, points.w / width, points.h / height);
    LibretroPresenterScreen *entry = [LibretroPresenterScreen screenWithSource:screen.source
                                                                      container:container
                                                                         format:format
                                                                    touchScreen:screen.touchScreen];
    // Console pixels of this screen for the shaders: DS 256x192 each, 3DS
    // top 400x240 and bottom 320x240, PSP 480x272 even when upscaled.
    if (nominal.w > 0 && nominal.h > 0) {
      entry.nominalSize = (LibretroSize){screen.source.w * nominal.w, screen.source.h * nominal.h};
    }
    [screens addObject:entry];
  }
  _presenterScreens = [screens copy];
  [_presenter setDrawableSize:drawableSize screens:_presenterScreens];
  LibretroSkin *skin = representation.generated ? _defaultSkin : (_currentSkin ?: _defaultSkin);
  [_controller.overlay applyLayout:layout inputMap:_inputMap touchRemap:[self touchRemapForSkin:skin]];
  [_input setInputMap:_inputMap gamepadRemap:[self gamepadRemap]];
  _controller.controlsOpacity = [self opacityForRepresentation:representation];
  [self requestRedraw];
}

/// Touch-screen mappings of the last presented frame, normalized to the
/// drawable (LibretroGameViewController converts them to overlay points).
- (NSArray<NSValue *> *)touchScreenMappings {
  if (!_screensAndShadersAvailable) {
    // Legacy Vulkan presentation: the whole picture, aspect-fitted by the
    // renderer, is one touch screen for DS / 3DS.
    LibretroVulkanRenderer *vulkan = _vulkan;
    if (vulkan == nil || !_inputMap.hasTouchScreen) return @[];
    CGRect rect = vulkan.normalizedVideoRect;
    LibretroScreenMapping mapping;
    mapping.output = LibretroRectMake(rect.origin.x, rect.origin.y, rect.size.width, rect.size.height);
    mapping.source = LibretroRectUnit;
    mapping.rotation = 0;
    return @[ [NSValue valueWithBytes:&mapping objCType:@encode(LibretroScreenMapping)] ];
  }
  NSArray<NSValue *> *mappings = [_presenter screenMappings];
  NSArray<LibretroPresenterScreen *> *screens = _presenterScreens;
  // The last frame was drawn with an older layout: keep the previous mappings.
  if (mappings.count != screens.count) return _lastTouchMappings;
  NSMutableArray<NSValue *> *touch = [NSMutableArray array];
  for (NSUInteger index = 0; index < screens.count; index++) {
    if (screens[index].touchScreen) [touch addObject:mappings[index]];
  }
  _lastTouchMappings = [touch copy];
  return _lastTouchMappings;
}

#pragma mark - LibretroFrontendMenuHost (main thread)

- (NSString *)uiLocale {
  return _configuration.uiLocale.length > 0 ? _configuration.uiLocale : @"en";
}

- (NSString *)console {
  return _console ?: @"";
}

- (NSString *)consoleName {
  return _configuration.consoleName ?: @"";
}

- (NSString *)gameKey {
  return _configuration.gameKey ?: @"";
}

- (LibretroFrontendStore *)frontendStore {
  return _store;
}

- (LibretroInputMap *)inputMap {
  return _inputMap;
}

- (NSArray<LibretroSkin *> *)availableSkins {
  if (_availableSkins != nil) return _availableSkins;
  NSMutableArray<LibretroSkin *> *imported = [NSMutableArray array];
  NSString *root = _configuration.skinsDirectory;
  NSArray<NSString *> *entries =
      root.length > 0 ? [NSFileManager.defaultManager contentsOfDirectoryAtPath:root error:nil] : nil;
  for (NSString *entry in entries) {
    if (!LibretroSkinIdentifierIsValid(entry) || [entry isEqualToString:LibretroDefaultSkinIdentifier]) continue;
    // neostation-skin.json (written by Dart at import) names the consoles.
    NSString *metadataPath =
        [[root stringByAppendingPathComponent:entry] stringByAppendingPathComponent:@"neostation-skin.json"];
    NSData *data = [NSData dataWithContentsOfFile:metadataPath];
    NSDictionary *metadata =
        SettingDictionary(data.length > 0 ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil);
    NSArray *consoles = [metadata[@"consoles"] isKindOfClass:NSArray.class] ? metadata[@"consoles"] : nil;
    if (![consoles containsObject:_console]) continue;
    LibretroSkin *skin = [self importedSkinWithIdentifier:entry report:NO];
    if (skin != nil) [imported addObject:skin];
  }
  [imported sortUsingComparator:^NSComparisonResult(LibretroSkin *first, LibretroSkin *second) {
    NSComparisonResult byName = [first.name localizedStandardCompare:second.name];
    return byName != NSOrderedSame ? byName : [first.installedIdentifier compare:second.installedIdentifier];
  }];
  NSMutableArray<LibretroSkin *> *skins = [NSMutableArray arrayWithObject:_defaultSkin];
  [skins addObjectsFromArray:imported];
  _availableSkins = [skins copy];
  return _availableSkins;
}

- (LibretroSkinRepresentation *)previewRepresentationForSkin:(LibretroSkin *)skin
                                                orientation:(LibretroSkinOrientation)orientation {
  LibretroSize size;
  LibretroInsets insets;
  [self viewSize:&size insets:&insets forOrientation:orientation];
  if (skin == nil || [skin.installedIdentifier isEqualToString:LibretroDefaultSkinIdentifier]) {
    return [self defaultRepresentationForOrientation:orientation viewSize:size safeInsets:insets iPad:_iPad];
  }
  return [skin representationForOrientation:orientation iPad:_iPad edgeToEdge:insets.bottom > 0];
}

- (void)renderPreviewForRepresentation:(LibretroSkinRepresentation *)representation
                                  size:(CGSize)size
                            completion:(void (^)(UIImage *image))completion {
  LibretroSize viewSize;
  LibretroInsets insets;
  [self viewSize:&viewSize insets:&insets forOrientation:representation.orientation];
  // Safe insets in the preview's points.
  double factor = viewSize.w > 0 && size.width > 0 ? size.width / viewSize.w : 1;
  UIEdgeInsets safe = UIEdgeInsetsMake(insets.top * factor, insets.left * factor, insets.bottom * factor,
                                       insets.right * factor);
  CGFloat scale = _controller.view.window.screen.scale;
  NSString *cacheDirectory =
      _configuration.cacheDirectory.length > 0 ? _configuration.cacheDirectory : NSTemporaryDirectory();
  [LibretroSkinRenderer renderPreviewForRepresentation:representation
                                                  size:size
                                                 scale:scale > 0 ? scale : 2
                                            safeInsets:safe
                                        cacheDirectory:cacheDirectory
                                            completion:completion];
}

- (LibretroSkinOrientation)currentOrientation {
  return _currentOrientation;
}

- (LibretroSkin *)currentSkin {
  return _currentSkin ?: _defaultSkin;
}

- (LibretroSkinRepresentation *)currentRepresentation {
  if (_currentRepresentation != nil) return _currentRepresentation;
  return [self defaultRepresentationForOrientation:_currentOrientation
                                          viewSize:_viewSize
                                        safeInsets:_safeInsets
                                              iPad:_iPad];
}

- (double)coreAspectRatio {
  return _presenter != nil ? (double)_presenter.aspectRatio : 0;
}

- (BOOL)screensAndShadersAvailable {
  return _screensAndShadersAvailable;
}

- (BOOL)physicalControllerConnected {
  return _input.hasPhysicalController;
}

- (void)frontendSettingsDidChange {
  [_input setInputMap:_inputMap gamepadRemap:[self gamepadRemap]];
  // Layout, screens, format, touch remaps and opacity are resolved again by
  // the layout pass, which ends with a coalesced redraw.
  [_controller setNeedsSkinLayout];
}

- (void)applyShaderPreset:(NSString *)presetIdentifier
               parameters:(NSDictionary<NSString *, NSNumber *> *)parameters
               completion:(void (^)(BOOL success))completion {
  void (^done)(BOOL) = [completion copy];
  if (!_loaded || !_screensAndShadersAvailable) {
    dispatch_async(dispatch_get_main_queue(), ^{
      done(NO);
    });
    return;
  }
  NSString *identifier = [presetIdentifier copy];
  NSDictionary<NSString *, NSNumber *> *values = [parameters copy];
  __weak LibretroSession *weakSelf = self;
  [self enqueue:^{
    LibretroSession *session = weakSelf;
    BOOL success = NO;
    if (session != nil) {
      success = [session activateShaderPreset:identifier parameters:values];
      [session redrawLastFrameIfPaused];
    }
    dispatch_async(dispatch_get_main_queue(), ^{
      done(success);
    });
  }];
}

- (void)previewShaderParameter:(NSString *)identifier value:(float)value {
  [_presenter setShaderParameter:identifier value:value];
  [self requestRedraw];
}

- (void)measureShaderWithCompletion:(void (^)(double milliseconds))completion {
  void (^done)(double) = [completion copy];
  if (!_loaded || !_screensAndShadersAvailable) {
    dispatch_async(dispatch_get_main_queue(), ^{
      done(0);
    });
    return;
  }
  __weak LibretroSession *weakSelf = self;
  [self enqueue:^{
    LibretroSession *session = weakSelf;
    double milliseconds = session != nil ? [session measureLastFrame] : 0;
    dispatch_async(dispatch_get_main_queue(), ^{
      done(milliseconds);
    });
  }];
}

- (void)beginControlsEditingForGame:(NSString *)gameKey {
  LibretroGameViewController *controller = _controller;
  if (controller == nil || _editingControls) return;
  _editingControls = YES;
  NSString *scopeGame = gameKey.length > 0 ? [gameKey copy] : nil;
  // The overrides belong to the skin and orientation on screen now (the
  // game view keeps the orientation while editing).
  NSString *layoutKey =
      LibretroSettingLayoutKey(self.currentSkin.installedIdentifier, LibretroSkinOrientationName(_currentOrientation));
  // Edited and reset from the chosen scope's own value: at console scope
  // the console's layout, never this game's, so Done keeps the console's
  // other entries and copies nothing from the game.
  LibretroFrontendStore *store = _store;
  NSString *console = [_console copy] ?: @"";
  LibretroControlsOverridesProvider startingOverrides = ^NSDictionary<NSString *, NSDictionary *> * {
    return [LibretroChromeLayout controlsEditorOverridesForKey:layoutKey
                                                         store:store
                                                       console:console
                                                     scopeGame:scopeGame];
  };
  // This game's own layout keeps applying to it over a console-wide edit.
  BOOL gameKeepsLayout = scopeGame == nil && [LibretroChromeLayout game:[self gameScopeKey]
                                                     hasOwnLayoutForKey:layoutKey
                                                                  store:store
                                                                console:console];
  __weak LibretroSession *weakSelf = self;
  dispatch_block_t start = ^{
    LibretroSession *session = weakSelf;
    LibretroGameViewController *view = session != nil ? session->_controller : nil;
    if (view == nil) return;
    [view beginEditingControlsWithDoneTitle:[session text:@"controlsEditDone"]
                                 resetTitle:[session text:@"controlsReset"]
                                       hint:[session text:@"controlsEditHint"]
                          startingOverrides:startingOverrides
                                   finished:^{
                                     [weakSelf finishControlsEditingWithKey:layoutKey game:scopeGame];
                                   }
                                      reset:^{
                                        [weakSelf resetControlsLayoutWithKey:layoutKey game:scopeGame];
                                      }];
    if (gameKeepsLayout) [session showStatus:[session text:@"controlsGameLayoutApplies"]];
  };
  // The menu closes without resuming: the game stays paused while editing.
  UINavigationController *menu = _menu;
  if (menu == nil) {
    start();
    return;
  }
  [menu dismissViewControllerAnimated:YES
                           completion:^{
                             LibretroSession *session = weakSelf;
                             if (session == nil) return;
                             session->_menu = nil;
                             session->_frontendMenu = nil;
                             start();
                           }];
}

- (void)finishControlsEditingWithKey:(NSString *)layoutKey game:(NSString *)gameKey {
  NSDictionary<NSString *, NSDictionary *> *overrides = _controller.overlay.editOverrides;
  if (![_store setValue:overrides.count > 0 ? overrides : nil forKey:layoutKey console:_console game:gameKey]) {
    NSLog(@"[Libretro] controls layout %@ not saved", layoutKey);
  }
  _editingControls = NO;
  [self setMenuPaused:NO];
  if (gameKey == nil && [LibretroChromeLayout game:[self gameScopeKey]
                                hasOwnLayoutForKey:layoutKey
                                             store:_store
                                           console:_console ?: @""]) {
    // Saved for the console, but this game shows its own layout again:
    // said once the editor has closed.
    __weak LibretroSession *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
      LibretroSession *session = weakSelf;
      if (session == nil) return;
      [session showStatus:[session text:@"controlsGameLayoutApplies"]];
    });
  }
}

- (void)resetControlsLayoutWithKey:(NSString *)layoutKey game:(NSString *)gameKey {
  [_store setValue:nil forKey:layoutKey console:_console game:gameKey];
}

- (void)showStatus:(NSString *)message {
  if (NSThread.isMainThread) {
    [_controller showStatus:message];
  } else {
    dispatch_async(dispatch_get_main_queue(), ^{
      [self->_controller showStatus:message];
    });
  }
}

#pragma mark - Shaders (emulation thread)

- (NSDictionary<NSString *, NSNumber *> *)storedShaderParameters {
  NSDictionary *stored = SettingDictionary([self settingValue:LibretroSettingShaderParameters]);
  NSMutableDictionary<NSString *, NSNumber *> *parameters = [NSMutableDictionary dictionary];
  for (id identifier in stored) {
    id value = stored[identifier];
    if ([identifier isKindOfClass:NSString.class] && [value isKindOfClass:NSNumber.class]) parameters[identifier] = value;
  }
  return parameters;
}

/// Shader of the game, else of the console, at load. A preset that cannot
/// be compiled leaves the standard picture and is announced; the stored
/// choice is not changed.
- (void)applyStoredShader {
  id enabled = [self settingValue:LibretroSettingShaderEnabled];
  NSString *identifier = SettingString([self settingValue:LibretroSettingShaderPreset]);
  if (![enabled isKindOfClass:NSNumber.class] || ![enabled boolValue] || identifier == nil) return;
  if (![self activateShaderPreset:identifier parameters:[self storedShaderParameters]]) {
    [self showStatus:[self text:@"shaderFailed"]];
  }
}

- (BOOL)activateShaderPreset:(NSString *)identifier parameters:(NSDictionary<NSString *, NSNumber *> *)parameters {
  LibretroShaderPreset *preset = identifier.length > 0 ? [LibretroShaderLibrary presetWithIdentifier:identifier] : nil;
  NSError *error = nil;
  if (identifier.length > 0 && preset == nil) {
    [_presenter setShaderPreset:nil parameters:nil error:NULL];
    NSLog(@"[Libretro] unknown shader preset %@: standard picture", identifier);
    return NO;
  }
  BOOL success = [_presenter setShaderPreset:preset parameters:parameters error:&error];
  if (!success) NSLog(@"[Libretro] shader preset %@ unavailable: %@", identifier, error.localizedDescription);
  return success;
}

- (double)measureLastFrame {
  [_condition lock];
  BOOL active = !_backgroundPaused && !_stopRequested;
  [_condition unlock];
  if (!active) return 0;
  BOOL gl = _gl != nil;
  if (gl) dispatch_semaphore_wait(_glFrameSemaphore, DISPATCH_TIME_FOREVER);
  double milliseconds = [_presenter measureLastFrameGPUTime:kShaderMeasureIterations];
  if (gl) dispatch_semaphore_signal(_glFrameSemaphore);
  NSLog(@"[Libretro] shader %@: median presenter GPU time %.3f ms over %lu redraws",
        _presenter.activePresetIdentifier ?: @"none", milliseconds, (unsigned long)kShaderMeasureIterations);
  return milliseconds;
}

#pragma mark - Frontend actions (main thread)

/// Skin items and remapped controller buttons: menu, quick save / load,
/// fast forward (held or toggled), swap the DS / 3DS screens.
- (void)performFrontendAction:(LibretroFrontendAction)action pressed:(BOOL)pressed {
  if (action == LibretroFrontendActionFastForward) {
    if (pressed && _loaded && _menu == nil && !_editingControls) {
      _fastForwardHeld = YES;
      [self setFastForward:YES];
    } else if (!pressed && _fastForwardHeld) {
      _fastForwardHeld = NO;
      [self setFastForward:NO];
    }
    return;
  }
  if (!pressed || !_loaded || _menu != nil || _editingControls) return;
  __weak LibretroSession *weakSelf = self;
  switch (action) {
    case LibretroFrontendActionMenu: {
      // Outside the overlay's touch handling, which the menu interrupts.
      dispatch_async(dispatch_get_main_queue(), ^{
        [weakSelf openMenu];
      });
      break;
    }
    case LibretroFrontendActionQuickSave: {
      [self quickState:YES];
      break;
    }
    case LibretroFrontendActionQuickLoad: {
      [self quickState:NO];
      break;
    }
    case LibretroFrontendActionToggleFastForward: {
      BOOL on = !atomic_load(&_fastForward);
      _fastForwardHeld = NO;
      [self setFastForward:on];
      [self showStatus:[self text:on ? @"fastForwardOn" : @"fastForwardOff"]];
      break;
    }
    case LibretroFrontendActionSwapScreens: {
      dispatch_async(dispatch_get_main_queue(), ^{
        [weakSelf swapScreens];
      });
      break;
    }
    default:
      break;
  }
}

- (void)setFastForward:(BOOL)on {
  if (atomic_load(&_fastForward) == (bool)on) return;
  atomic_store(&_fastForward, on);
  LibretroCoreHost *host = _host;
  LibretroAudioOutput *audio = _audio;
  [self enqueue:^{
    host.fastForwarding = on;
    if (!on) [audio clear];
  }];
}

- (void)quickState:(BOOL)saving {
  LibretroCoreHost *host = _host;
  __weak LibretroSession *weakSelf = self;
  [self enqueue:^{
    NSString *key = nil;
    if (!saving && ![NSFileManager.defaultManager fileExistsAtPath:[host statePathForSlot:kQuickSlot]]) {
      key = @"quickMissing";
    } else {
      NSError *error = nil;
      BOOL ok = saving ? [host saveStateToSlot:kQuickSlot error:&error] : [host loadStateFromSlot:kQuickSlot error:&error];
      if (!ok) NSLog(@"[Libretro] quick %@ failed: %@", saving ? @"save" : @"load", error);
      key = ok ? (saving ? @"quickSaved" : @"quickLoaded") : @"stateFailed";
    }
    dispatch_async(dispatch_get_main_queue(), ^{
      LibretroSession *session = weakSelf;
      if (session == nil) return;
      [session showStatus:[session text:key]];
    });
  }];
}

/// DS / 3DS: exchanges the places of the two screens of the default skins,
/// where the value applies (the game's when it has one, else the console's).
/// Only NeoStation's skin places the screens: with an imported skin or the
/// legacy Vulkan picture nothing would change on screen, so nothing is
/// saved (it would show up later with the default skin) and the reason is
/// shown, as on the Screen layout page.
- (void)swapScreens {
  if (![LibretroDefaultSkins isDualScreenConsole:_console]) return;
  if (!_screensAndShadersAvailable) {
    [self showStatus:[self text:@"shaderUnavailable"]];
    return;
  }
  if (!self.currentRepresentation.generated) {
    [self showStatus:[self text:@"arrangementSkinFooter"]];
    return;
  }
  LibretroSettingScope scope = LibretroSettingScopeDefault;
  id stored = [_store valueForKey:LibretroSettingScreensSwapped console:_console game:[self gameScopeKey] scope:&scope];
  BOOL swapped = [stored isKindOfClass:NSNumber.class] && [stored boolValue];
  NSString *game = scope == LibretroSettingScopeGame ? [self gameScopeKey] : nil;
  // @YES / @NO (not @(int)) so the JSON file holds a boolean.
  NSNumber *value = swapped ? @NO : @YES;
  if (![_store setValue:value forKey:LibretroSettingScreensSwapped console:_console game:game]) {
    NSLog(@"[Libretro] screen swap not saved for %@", _console);
  }
  [self frontendSettingsDidChange];
}

#pragma mark - Disks and cheats

- (void)refreshDiskSnapshot {
  unsigned count = _host.supportsDiskControl ? _host.diskCount : 0;
  unsigned index = _host.diskIndex;
  NSMutableArray<NSString *> *labels = [NSMutableArray array];
  for (unsigned disk = 0; disk < count; disk++) {
    NSString *label = [_host labelForDisk:disk];
    [labels addObject:label ?: @""];
  }
  dispatch_async(dispatch_get_main_queue(), ^{
    self->_diskCount = count;
    self->_diskIndex = index;
    self->_diskLabels = labels;
  });
}

- (NSString *)cheatsPath {
  if (_cheatsPath == nil) {
    NSString *core = [_host.libraryName stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
    NSString *name = [_host.contentName ?: @"content" stringByAppendingPathExtension:@"json"];
    _cheatsPath = [[_configuration.cheatsDirectory stringByAppendingPathComponent:core ?: @"core"]
        stringByAppendingPathComponent:name];
  }
  return _cheatsPath;
}

- (void)loadCheats {
  NSData *data = [NSData dataWithContentsOfFile:[self cheatsPath]];
  NSArray *stored = data != nil ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
  NSMutableArray<NSMutableDictionary<NSString *, id> *> *cheats = [NSMutableArray array];
  if ([stored isKindOfClass:NSArray.class]) {
    for (id item in stored) {
      if (![item isKindOfClass:NSDictionary.class]) continue;
      NSString *code = [item[@"code"] isKindOfClass:NSString.class] ? item[@"code"] : @"";
      if (code.length == 0) continue;
      [cheats addObject:[@{
        @"name" : [item[@"name"] isKindOfClass:NSString.class] ? item[@"name"] : code,
        @"code" : code,
        @"enabled" : @([item[@"enabled"] boolValue]),
      } mutableCopy]];
    }
  }
  [_host applyCheats:[self enabledCodesIn:cheats]];
  dispatch_async(dispatch_get_main_queue(), ^{
    self->_cheats = cheats;
  });
}

- (NSArray<NSString *> *)enabledCodesIn:(NSArray<NSDictionary<NSString *, id> *> *)cheats {
  NSMutableArray<NSString *> *codes = [NSMutableArray array];
  for (NSDictionary<NSString *, id> *cheat in cheats) {
    if ([cheat[@"enabled"] boolValue]) [codes addObject:cheat[@"code"]];
  }
  return codes;
}

- (void)saveAndApplyCheats {
  NSArray *snapshot = [[NSArray alloc] initWithArray:_cheats copyItems:YES];
  NSString *path = [self cheatsPath];
  [[NSFileManager defaultManager] createDirectoryAtPath:path.stringByDeletingLastPathComponent
                            withIntermediateDirectories:YES
                                             attributes:nil
                                                  error:nil];
  NSData *data = [NSJSONSerialization dataWithJSONObject:snapshot options:NSJSONWritingPrettyPrinted error:nil];
  [data writeToFile:path atomically:YES];
  NSArray<NSString *> *codes = [self enabledCodesIn:snapshot];
  LibretroCoreHost *host = _host;
  [self enqueue:^{
    [host applyCheats:codes];
  }];
}

#pragma mark - Menu (main thread)

- (void)openMenu {
  if (_menu != nil || !_loaded || _controller == nil || _editingControls) return;
  if (_controller.presentedViewController != nil) return;
  if (_fastForwardHeld) {
    _fastForwardHeld = NO;
    [self setFastForward:NO];
  }
  [_controller.overlay releaseAllTouches];
  [self setMenuPaused:YES];
  [_input reset];
  // Skins are listed again at each opening; the frontend pages live as long
  // as this menu.
  _availableSkins = nil;
  _frontendMenu = [[LibretroFrontendMenu alloc] initWithHost:self];
  __weak LibretroSession *weakSelf = self;
  LibretroMenuPage *root = [[LibretroMenuPage alloc] initWithTitle:_configuration.gameTitle ?: @""
                                                           builder:^NSArray<LibretroMenuSection *> * {
                                                             return [weakSelf rootSections];
                                                           }];
  root.closeTitle = [self text:@"resume"];
  root.closeHandler = ^{
    [weakSelf closeMenu];
  };
  // Follows the game's orientations (portrait and landscape).
  LibretroMenuNavigationController *navigation =
      [[LibretroMenuNavigationController alloc] initWithRootViewController:root];
  navigation.modalPresentationStyle = UIModalPresentationOverFullScreen;
  navigation.modalInPresentation = YES;
  navigation.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
  _menu = navigation;
  [_controller presentViewController:navigation animated:YES completion:nil];
}

- (void)closeMenu {
  UINavigationController *menu = _menu;
  if (menu == nil) return;
  [menu dismissViewControllerAnimated:YES
                           completion:^{
                             self->_menu = nil;
                             self->_frontendMenu = nil;
                             [self setMenuPaused:NO];
                           }];
}

- (NSArray<LibretroMenuSection *> *)rootSections {
  __weak LibretroSession *weakSelf = self;
  NSMutableArray<LibretroMenuSection *> *sections = [NSMutableArray array];

  LibretroMenuRow *resume = [LibretroMenuRow rowWithTitle:[self text:@"resume"]
                                                   action:^(__unused LibretroMenuPage *page) {
                                                     [weakSelf closeMenu];
                                                   }];
  resume.identifier = @"libretro-menu-resume";
  LibretroMenuRow *reset = [LibretroMenuRow
      rowWithTitle:[self text:@"reset"]
            action:^(LibretroMenuPage *page) {
              LibretroSession *session = weakSelf;
              if (session == nil) return;
              [page confirmWithTitle:[session text:@"reset"]
                             message:[session text:@"resetConfirm"]
                              action:[session text:@"reset"]
                         cancelTitle:[session text:@"cancel"]
                         destructive:YES
                             handler:^{
                               LibretroCoreHost *host = session->_host;
                               LibretroAchievements *achievements = session->_achievements;
                               [session enqueue:^{
                                 [host resetContent];
                                 [achievements resetGame];
                               }];
                               [session closeMenu];
                             }];
            }];
  [sections addObject:[LibretroMenuSection sectionWithTitle:nil rows:@[ resume, reset ]]];

  LibretroMenuRow *save = [LibretroMenuRow rowWithTitle:[self text:@"saveState"]
                                                 action:^(LibretroMenuPage *page) {
                                                   [page push:[weakSelf statePage:YES]];
                                                 }];
  save.disclosure = YES;
  LibretroMenuRow *load = [LibretroMenuRow rowWithTitle:[self text:@"loadState"]
                                                 action:^(LibretroMenuPage *page) {
                                                   [page push:[weakSelf statePage:NO]];
                                                 }];
  load.disclosure = YES;
  [sections addObject:[LibretroMenuSection sectionWithTitle:nil rows:@[ save, load ]]];

  if (_diskCount > 1) {
    LibretroMenuRow *disc = [LibretroMenuRow rowWithTitle:[self text:@"changeDisc"]
                                                   action:^(LibretroMenuPage *page) {
                                                     [page push:[weakSelf diskPage]];
                                                   }];
    disc.detail = [self text:@"disc" replacing:@"{number}" with:@(_diskIndex + 1).stringValue];
    disc.disclosure = YES;
    [sections addObject:[LibretroMenuSection sectionWithTitle:nil rows:@[ disc ]]];
  }

  LibretroMenuRow *touch = [LibretroMenuRow toggleWithTitle:[self text:@"touchControls"]
                                                         on:_touchControls
                                                     toggle:^(__unused LibretroMenuPage *page, BOOL on) {
                                                       LibretroSession *session = weakSelf;
                                                       if (session == nil) return;
                                                       session->_touchControls = on;
                                                       session->_controller.touchControlsEnabled = on;
                                                       [NSUserDefaults.standardUserDefaults
                                                           setBool:on
                                                            forKey:@"libretro.touchControls"];
                                                     }];
  LibretroMenuRow *smooth = [LibretroMenuRow toggleWithTitle:[self text:@"smoothing"]
                                                          on:_smooth
                                                      toggle:^(__unused LibretroMenuPage *page, BOOL on) {
                                                        LibretroSession *session = weakSelf;
                                                        if (session == nil) return;
                                                        session->_smooth = on;
                                                        session->_presenter.smooth = on;
                                                        session->_vulkan.smooth = on;
                                                        [NSUserDefaults.standardUserDefaults setBool:on
                                                                                              forKey:@"libretro.smooth"];
                                                        [session requestRedraw];
                                                      }];
  LibretroMenuRow *fast = [LibretroMenuRow toggleWithTitle:[self text:@"fastForward"]
                                                        on:atomic_load(&_fastForward)
                                                    toggle:^(__unused LibretroMenuPage *page, BOOL on) {
                                                      LibretroSession *session = weakSelf;
                                                      if (session == nil) return;
                                                      session->_fastForwardHeld = NO;
                                                      [session setFastForward:on];
                                                    }];
  // Skins, screen format, screen layout (DS / 3DS), shaders and controls
  // first (LibretroFrontendMenu), then the existing display toggles.
  NSMutableArray<LibretroMenuRow *> *displayRows = [NSMutableArray array];
  if (_frontendMenu != nil) [displayRows addObjectsFromArray:[_frontendMenu rootRows]];
  [displayRows addObjectsFromArray:@[ touch, smooth, fast ]];
  LibretroMenuSection *display = [LibretroMenuSection sectionWithTitle:[self text:@"display"] rows:displayRows];
  [sections addObject:display];

  NSMutableArray<LibretroMenuRow *> *extras = [NSMutableArray array];
  if ([self availableSettings].count > 0) {
    LibretroMenuRow *settings = [LibretroMenuRow rowWithTitle:[self text:@"coreSettings"]
                                                       action:^(LibretroMenuPage *page) {
                                                         [page push:[weakSelf settingsPage]];
                                                       }];
    settings.disclosure = YES;
    [extras addObject:settings];
  }
  LibretroMenuRow *cheats = [LibretroMenuRow rowWithTitle:[self text:@"cheats"]
                                                   action:^(LibretroMenuPage *page) {
                                                     [page push:[weakSelf cheatsPage]];
                                                   }];
  cheats.disclosure = YES;
  NSUInteger enabledCheats = [self enabledCodesIn:_cheats].count;
  if (enabledCheats > 0) cheats.detail = @(enabledCheats).stringValue;
  [extras addObject:cheats];
  if (_achievements != nil) {
    LibretroMenuRow *achievements = [LibretroMenuRow rowWithTitle:[self text:@"achievements"]
                                                           action:^(LibretroMenuPage *page) {
                                                             [page push:[weakSelf achievementsPage]];
                                                           }];
    achievements.disclosure = YES;
    if (_achievements.gameLoaded) {
      achievements.detail = [NSString stringWithFormat:@"%u / %u", _achievements.unlockedCount,
                                                       _achievements.totalCount];
    }
    [extras addObject:achievements];
  }
  [sections addObject:[LibretroMenuSection sectionWithTitle:nil rows:extras]];

  LibretroMenuRow *quit = [LibretroMenuRow
      rowWithTitle:[self text:@"quit"]
            action:^(LibretroMenuPage *page) {
              LibretroSession *session = weakSelf;
              if (session == nil) return;
              [page confirmWithTitle:[session text:@"quit"]
                             message:[session text:@"quitConfirm"]
                              action:[session text:@"quit"]
                         cancelTitle:[session text:@"cancel"]
                         destructive:YES
                             handler:^{
                               session->_menu.view.userInteractionEnabled = NO;
                               [session stopWithCompletion:nil];
                             }];
            }];
  quit.destructive = YES;
  quit.identifier = @"libretro-menu-quit";
  [sections addObject:[LibretroMenuSection sectionWithTitle:nil rows:@[ quit ]]];
  return sections;
}

- (LibretroMenuPage *)statePage:(BOOL)saving {
  __weak LibretroSession *weakSelf = self;
  NSString *title = [self text:saving ? @"saveState" : @"loadState"];
  return [[LibretroMenuPage alloc]
      initWithTitle:title
            builder:^NSArray<LibretroMenuSection *> * {
              LibretroSession *session = weakSelf;
              if (session == nil) return @[];
              NSDateFormatter *formatter = [NSDateFormatter new];
              formatter.locale = [NSLocale localeWithLocaleIdentifier:session->_configuration.uiLocale ?: @"en"];
              formatter.dateStyle = NSDateFormatterShortStyle;
              formatter.timeStyle = NSDateFormatterShortStyle;
              NSMutableArray<LibretroMenuRow *> *rows = [NSMutableArray array];
              for (NSInteger slot = 1; slot <= kStateSlots; slot++) {
                NSString *path = [session->_host statePathForSlot:slot];
                NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
                NSDate *date = attributes.fileModificationDate;
                NSString *name = [session text:@"slot" replacing:@"{number}" with:@(slot).stringValue];
                LibretroMenuRow *row = [LibretroMenuRow
                    rowWithTitle:name
                          action:^(__unused LibretroMenuPage *page) {
                            [session performState:saving slot:slot];
                          }];
                row.detail = date != nil ? [formatter stringFromDate:date] : [session text:@"emptySlot"];
                row.enabled = saving || date != nil;
                [rows addObject:row];
              }
              return @[ [LibretroMenuSection sectionWithTitle:nil rows:rows] ];
            }];
}

- (void)performState:(BOOL)saving slot:(NSInteger)slot {
  LibretroCoreHost *host = _host;
  __weak LibretroSession *weakSelf = self;
  [self enqueue:^{
    NSError *error = nil;
    BOOL ok = saving ? [host saveStateToSlot:slot error:&error] : [host loadStateFromSlot:slot error:&error];
    if (!ok) NSLog(@"[Libretro] state %@ slot %ld failed: %@", saving ? @"save" : @"load", (long)slot, error);
    dispatch_async(dispatch_get_main_queue(), ^{
      LibretroSession *session = weakSelf;
      if (session == nil) return;
      NSString *number = @(slot).stringValue;
      NSString *message = ok ? [session text:saving ? @"stateSaved" : @"stateLoaded" replacing:@"{number}" with:number]
                             : [session text:@"stateFailed"];
      [session closeMenu];
      [session showStatus:message];
    });
  }];
}

- (LibretroMenuPage *)diskPage {
  __weak LibretroSession *weakSelf = self;
  return [[LibretroMenuPage alloc]
      initWithTitle:[self text:@"changeDisc"]
            builder:^NSArray<LibretroMenuSection *> * {
              LibretroSession *session = weakSelf;
              if (session == nil) return @[];
              NSMutableArray<LibretroMenuRow *> *rows = [NSMutableArray array];
              for (unsigned disk = 0; disk < session->_diskCount; disk++) {
                NSString *number = @(disk + 1).stringValue;
                NSString *name = [session text:@"disc" replacing:@"{number}" with:number];
                LibretroMenuRow *row = [LibretroMenuRow
                    rowWithTitle:name
                          action:^(__unused LibretroMenuPage *page) {
                            LibretroCoreHost *host = session->_host;
                            [session enqueue:^{
                              BOOL changed = [host selectDisk:disk];
                              [session refreshDiskSnapshot];
                              dispatch_async(dispatch_get_main_queue(), ^{
                                [session closeMenu];
                                if (changed) {
                                  [session showStatus:[session text:@"discChanged"
                                                          replacing:@"{number}"
                                                               with:number]];
                                }
                              });
                            }];
                          }];
                NSString *label = disk < session->_diskLabels.count ? session->_diskLabels[disk] : @"";
                if (label.length > 0) row.detail = label;
                row.checked = disk == session->_diskIndex;
                [rows addObject:row];
              }
              return @[ [LibretroMenuSection sectionWithTitle:nil rows:rows] ];
            }];
}

/// Curated settings the core declares, without the options NeoStation
/// locks for this session (DS / 3DS screen layout and pointer): those are
/// read-only and never offered.
- (NSArray<NSDictionary *> *)availableSettings {
  NSMutableSet<NSString *> *declared = [NSMutableSet set];
  for (LibretroCoreOption *option in _host.options.options) [declared addObject:option.key];
  NSMutableArray<NSDictionary *> *available = [NSMutableArray array];
  for (NSDictionary *setting in _configuration.coreSettings) {
    NSString *key = [setting[@"key"] isKindOfClass:NSString.class] ? setting[@"key"] : nil;
    if (key == nil || ![declared containsObject:key] || [_host.options isLockedKey:key]) continue;
    [available addObject:setting];
  }
  return available;
}

- (NSString *)currentValueForKey:(NSString *)key {
  const char *value = [_host.options valueForKey:key.UTF8String];
  return value != NULL ? [NSString stringWithUTF8String:value] : @"";
}

- (LibretroMenuPage *)settingsPage {
  __weak LibretroSession *weakSelf = self;
  LibretroMenuPage *page = [[LibretroMenuPage alloc]
      initWithTitle:[self text:@"coreSettings"]
            builder:^NSArray<LibretroMenuSection *> * {
              LibretroSession *session = weakSelf;
              if (session == nil) return @[];
              NSMutableArray<LibretroMenuRow *> *rows = [NSMutableArray array];
              for (NSDictionary *setting in [session availableSettings]) {
                NSString *key = setting[@"key"];
                NSString *current = [session currentValueForKey:key];
                NSArray *values = [setting[@"values"] isKindOfClass:NSArray.class] ? setting[@"values"] : @[];
                NSString *detail = current;
                for (NSDictionary *value in values) {
                  if ([value[@"value"] isEqual:current] && [value[@"label"] isKindOfClass:NSString.class]) {
                    detail = value[@"label"];
                  }
                }
                LibretroMenuRow *row = [LibretroMenuRow
                    rowWithTitle:[setting[@"label"] isKindOfClass:NSString.class] ? setting[@"label"] : key
                          action:^(LibretroMenuPage *page) {
                            [page push:[session choicePageForSetting:setting]];
                          }];
                row.detail = detail;
                row.disclosure = YES;
                [rows addObject:row];
              }
              LibretroMenuSection *section = [LibretroMenuSection sectionWithTitle:nil rows:rows];
              section.footer = [session text:@"settingsRestartHint"];
              return @[ section ];
            }];
  return page;
}

- (LibretroMenuPage *)choicePageForSetting:(NSDictionary *)setting {
  __weak LibretroSession *weakSelf = self;
  NSString *key = setting[@"key"];
  NSString *title = [setting[@"label"] isKindOfClass:NSString.class] ? setting[@"label"] : key;
  return [[LibretroMenuPage alloc]
      initWithTitle:title
            builder:^NSArray<LibretroMenuSection *> * {
              LibretroSession *session = weakSelf;
              if (session == nil) return @[];
              NSString *current = [session currentValueForKey:key];
              NSArray *values = [setting[@"values"] isKindOfClass:NSArray.class] ? setting[@"values"] : @[];
              NSMutableArray<LibretroMenuRow *> *rows = [NSMutableArray array];
              for (NSDictionary *value in values) {
                NSString *raw = [value[@"value"] isKindOfClass:NSString.class] ? value[@"value"] : nil;
                if (raw == nil) continue;
                NSString *label = [value[@"label"] isKindOfClass:NSString.class] ? value[@"label"] : raw;
                LibretroMenuRow *row = [LibretroMenuRow
                    rowWithTitle:label
                          action:^(LibretroMenuPage *page) {
                            [session->_host.options setValue:raw forKey:key persist:YES];
                            [page.navigationController popViewControllerAnimated:YES];
                          }];
                row.checked = [raw isEqualToString:current];
                [rows addObject:row];
              }
              return @[ [LibretroMenuSection sectionWithTitle:nil rows:rows] ];
            }];
}

- (LibretroMenuPage *)cheatsPage {
  __weak LibretroSession *weakSelf = self;
  return [[LibretroMenuPage alloc]
      initWithTitle:[self text:@"cheats"]
            builder:^NSArray<LibretroMenuSection *> * {
              LibretroSession *session = weakSelf;
              if (session == nil) return @[];
              NSMutableArray<LibretroMenuRow *> *rows = [NSMutableArray array];
              NSArray *cheats = [session->_cheats copy];
              for (NSUInteger index = 0; index < cheats.count; index++) {
                NSMutableDictionary *cheat = cheats[index];
                LibretroMenuRow *row = [LibretroMenuRow
                    toggleWithTitle:cheat[@"name"]
                                 on:[cheat[@"enabled"] boolValue]
                             toggle:^(__unused LibretroMenuPage *page, BOOL on) {
                               cheat[@"enabled"] = @(on);
                               [session saveAndApplyCheats];
                             }];
                row.detail = cheat[@"code"];
                row.remove = ^(LibretroMenuPage *page) {
                  [session->_cheats removeObjectIdenticalTo:cheat];
                  [session saveAndApplyCheats];
                  [page rebuild];
                };
                [rows addObject:row];
              }
              LibretroMenuSection *list = [LibretroMenuSection sectionWithTitle:nil rows:rows];
              list.footer = [session text:@"cheatsHelp"];
              LibretroMenuRow *add = [LibretroMenuRow
                  rowWithTitle:[session text:@"addCheat"]
                        action:^(LibretroMenuPage *page) {
                          [page askWithTitle:[session text:@"addCheat"]
                                      fields:@[ [session text:@"cheatName"], [session text:@"cheatCode"] ]
                                      secure:@[ @NO, @NO ]
                                      action:[session text:@"add"]
                                 cancelTitle:[session text:@"cancel"]
                                     handler:^(NSArray<NSString *> *values) {
                                       NSString *code = [values.lastObject
                                           stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
                                       if (code.length == 0) return;
                                       NSString *name = [values.firstObject
                                           stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
                                       [session->_cheats addObject:[@{
                                         @"name" : name.length > 0 ? name : code,
                                         @"code" : code,
                                         @"enabled" : @YES,
                                       } mutableCopy]];
                                       [session saveAndApplyCheats];
                                       [page rebuild];
                                     }];
                        }];
              return @[ list, [LibretroMenuSection sectionWithTitle:nil rows:@[ add ]] ];
            }];
}

- (LibretroMenuPage *)achievementsPage {
  __weak LibretroSession *weakSelf = self;
  LibretroMenuPage *page = [[LibretroMenuPage alloc]
      initWithTitle:[self text:@"achievements"]
            builder:^NSArray<LibretroMenuSection *> * {
              LibretroSession *session = weakSelf;
              if (session == nil) return @[];
              LibretroAchievements *achievements = session->_achievements;
              if (achievements == nil) return @[];
              NSMutableArray<LibretroMenuRow *> *rows = [NSMutableArray array];
              [rows addObject:[LibretroMenuRow toggleWithTitle:[session text:@"achievementsEnabled"]
                                                            on:[LibretroAchievements enabled]
                                                        toggle:^(LibretroMenuPage *page, BOOL on) {
                                                          [LibretroAchievements setEnabled:on];
                                                          if (on) {
                                                            NSString *path = session->_configuration.contentPath;
                                                            [session enqueue:^{
                                                              [achievements startWithContentPath:path];
                                                            }];
                                                          }
                                                          [page rebuild];
                                                        }]];
              if (achievements.loggedIn) {
                LibretroMenuRow *user = [LibretroMenuRow
                    rowWithTitle:[session text:@"achievementsLoggedIn"
                                     replacing:@"{user}"
                                          with:achievements.username ?: @""]
                          action:nil];
                if (achievements.gameLoaded) {
                  user.detail = [NSString stringWithFormat:@"%u / %u", achievements.unlockedCount,
                                                           achievements.totalCount];
                } else {
                  user.detail = [session text:@"achievementsNone"];
                }
                [rows addObject:user];
                LibretroMenuRow *logout = [LibretroMenuRow rowWithTitle:[session text:@"achievementsLogout"]
                                                                 action:^(LibretroMenuPage *page) {
                                                                   [achievements logout];
                                                                   [page rebuild];
                                                                 }];
                logout.destructive = YES;
                [rows addObject:logout];
              } else {
                [rows addObject:[LibretroMenuRow
                                    rowWithTitle:[session text:@"achievementsLogin"]
                                          action:^(LibretroMenuPage *page) {
                                            [page askWithTitle:[session text:@"achievementsLogin"]
                                                        fields:@[
                                                          [session text:@"achievementsUser"],
                                                          [session text:@"achievementsPassword"]
                                                        ]
                                                        secure:@[ @NO, @YES ]
                                                        action:[session text:@"achievementsLogin"]
                                                   cancelTitle:[session text:@"cancel"]
                                                       handler:^(NSArray<NSString *> *values) {
                                                         [achievements
                                                             loginWithUsername:values.firstObject ?: @""
                                                                      password:values.lastObject ?: @""
                                                                    completion:^(BOOL success) {
                                                                      if (!success) {
                                                                        [session showStatus:[session
                                                                                                text:@"achievementsLoginFailed"]];
                                                                      }
                                                                      [page rebuild];
                                                                    }];
                                                       }];
                                          }]];
              }
              LibretroMenuSection *section = [LibretroMenuSection sectionWithTitle:nil rows:rows];
              section.footer = [session text:@"achievementsHelp"];
              return @[ section ];
            }];
  return page;
}

@end
