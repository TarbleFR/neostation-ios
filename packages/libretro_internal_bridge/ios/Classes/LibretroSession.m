#import "LibretroSession.h"

#import "LibretroAchievements.h"
#import "LibretroAudioOutput.h"
#import "LibretroCoreHost.h"
#import "LibretroCoreOptions.h"
#import "LibretroGLRenderer.h"
#import "LibretroGameViewController.h"
#import "LibretroInputState.h"
#import "LibretroJit.h"
#import "LibretroMetalPresenter.h"
#import "LibretroSessionMenu.h"
#import "LibretroVulkanRenderer.h"

#include <mach/mach_time.h>
#include <stdatomic.h>

static const NSInteger kStateSlots = 5;

@implementation LibretroSessionConfiguration
@end

@interface LibretroSession () <LibretroCoreHostDelegate>
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
  BOOL _stopRequested;
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
  _controller = [[LibretroGameViewController alloc] initWithProfile:_configuration.profile ?: @"nes" input:_input];
  _controller.title = _configuration.gameTitle;
  _controller.menuAccessibilityLabel = [self text:@"menu"];
  _controller.touchControlsEnabled = _touchControls;
  __weak LibretroSession *weakSelf = self;
  _controller.menuHandler = ^{
    [weakSelf openMenu];
  };
  _controller.activeHandler = ^(BOOL active) {
    [weakSelf applicationActive:active];
  };
  [_controller loadViewIfNeeded];
  _metalLayer = _controller.metalLayer;
  _presenter = [[LibretroMetalPresenter alloc] initWithLayer:_metalLayer];
  if (_presenter == nil) {
    _controller = nil;
    [self finishStartWithResult:@{@"success" : @NO, @"code" : @"LIBRETRO_VIDEO_FAILED", @"message" : @"Metal"}];
    return;
  }
  _presenter.smooth = _smooth;
  LibretroMetalPresenter *metal = _presenter;
  _controller.layoutHandler = ^(CGSize size) {
    [metal setDrawableSize:size];
  };
  _controller.videoRectProvider = ^CGRect {
    LibretroSession *session = weakSelf;
    LibretroVulkanRenderer *vulkan = session != nil ? session->_vulkan : nil;
    return vulkan != nil ? vulkan.normalizedVideoRect : metal.normalizedVideoRect;
  };
  [_controller setLoading:YES];
  [presenter presentViewController:_controller
                          animated:NO
                        completion:^{
                          LibretroSession *session = weakSelf;
                          if (session == nil) return;
                          session->_thread = [[NSThread alloc] initWithTarget:session
                                                                     selector:@selector(threadMain)
                                                                       object:nil];
                          session->_thread.name = @"NeoStation libretro";
                          session->_thread.qualityOfService = NSQualityOfServiceUserInteractive;
                          session->_thread.stackSize = 16 * 1024 * 1024;
                          [session->_thread start];
                        }];
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
  [controller stopInputPolling];
  NSArray<dispatch_block_t> *completions = [_stopCompletions copy];
  [_stopCompletions removeAllObjects];
  BOOL notify = _started;
  _started = NO;
  dispatch_block_t done = ^{
    for (dispatch_block_t completion in completions) completion();
    if (notify && self.endedHandler != nil) self.endedHandler();
  };
  UIViewController *presenter = controller.presentingViewController;
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
  [controller stopInputPolling];
  UIViewController *presenter = controller.presentingViewController;
  dispatch_block_t done = ^{
    [self finishStartWithResult:result];
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
  NSDictionary<NSString *, id> *success = @{
    @"success" : @YES,
    @"code" : @"",
    @"libraryName" : _host.libraryName ?: @"",
    @"libraryVersion" : _host.libraryVersion ?: @"",
    @"hardwareRendering" : _gl != nil ? @"gles" : (_vulkan != nil ? @"vulkan" : @"software"),
    @"jitCapable" : @(LibretroJitUsableByCores()),
  };
  dispatch_async(dispatch_get_main_queue(), ^{
    self->_started = YES;
    [self->_controller setLoading:NO];
    [self finishStartWithResult:success];
  });
  [self runLoop];
  @autoreleasepool {
    [self unloadCore];
  }
  dispatch_async(dispatch_get_main_queue(), ^{
    [self finishStop];
  });
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
  NSError *error = nil;
  if (![_host loadCore:&error]) return [self failureFromError:error];
  if (configuration.optionDefaults.count > 0) [_host.options applyDefaults:configuration.optionDefaults];
  if (!LibretroJitUsableByCores() && configuration.noJitOverrides.count > 0) {
    [_host.options applySessionOverrides:configuration.noJitOverrides];
  }
  if (![_host loadContentAtPath:configuration.contentPath error:&error]) return [self failureFromError:error];
  struct retro_system_av_info av = _host.avInfo;
  [self applyGeometry:av.geometry];
  _presenter.rotation = _host.rotation;
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
      prepared = [_vulkan prepare:&error];
    }
    if (!prepared) return [self failureWithCode:@"LIBRETRO_HARDWARE_RENDER_FAILED" detail:error.localizedDescription];
    [_host hardwareContextReset];
  } else {
    [_presenter presentBlack];
  }
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
  while (YES) {
    @autoreleasepool {
      [_condition lock];
      while ((_menuPaused || _backgroundPaused) && !_stopRequested && _commands.count == 0) {
        [_achievements idle];
        [_condition waitUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.5]];
      }
      NSArray<dispatch_block_t> *commands = [_commands copy];
      [_commands removeAllObjects];
      BOOL stop = _stopRequested || _host.shutdownRequested;
      BOOL paused = _menuPaused || _backgroundPaused;
      [_condition unlock];
      for (dispatch_block_t command in commands) command();
      if (stop) break;
      if (paused) {
        next = mach_absolute_time();
        continue;
      }
      [self runOneFrame];
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
      [_gl prepareWithWidth:av.geometry.max_width height:av.geometry.max_height error:nil];
    }
  }
  [_achievements doFrame];
}

- (void)unloadCore {
  [_achievements shutdown];
  _achievements = nil;
  [_audio stop];
  _audio = nil;
  LibretroGLRenderer *gl = _gl;
  LibretroVulkanRenderer *vulkan = _vulkan;
  LibretroCoreHost *host = _host;
  [_host unloadWithHardwareTeardown:^{
    if (gl != nil) {
      [gl makeCurrent];
      [host hardwareContextDestroy];
      [gl teardown];
    }
    if (vulkan != nil) {
      [vulkan waitIdle];
      [host hardwareContextDestroy];
      [vulkan teardown];
    }
  }];
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
}

- (void)coreHost:(LibretroCoreHost *)host message:(NSString *)message durationMilliseconds:(unsigned)duration {
  // Core messages are untranslated core text: kept in the diagnostics log only.
}

- (void)coreHostRequestedShutdown:(LibretroCoreHost *)host {
  [_condition lock];
  _stopRequested = YES;
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
}

- (void)setMenuPaused:(BOOL)paused {
  [_condition lock];
  _menuPaused = paused;
  [_condition signal];
  [_condition unlock];
  if (paused && _loaded) {
    LibretroCoreHost *host = _host;
    [self enqueue:^{
      [host flushSaveRAM:nil];
    }];
  }
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
  if (_menu != nil || !_loaded || _controller == nil) return;
  [self setMenuPaused:YES];
  [_input reset];
  __weak LibretroSession *weakSelf = self;
  LibretroMenuPage *root = [[LibretroMenuPage alloc] initWithTitle:_configuration.gameTitle ?: @""
                                                           builder:^NSArray<LibretroMenuSection *> * {
                                                             return [weakSelf rootSections];
                                                           }];
  root.closeTitle = [self text:@"resume"];
  root.closeHandler = ^{
    [weakSelf closeMenu];
  };
  UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:root];
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
                             [self setMenuPaused:NO];
                           }];
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
                                                      }];
  LibretroMenuRow *fast = [LibretroMenuRow toggleWithTitle:[self text:@"fastForward"]
                                                        on:atomic_load(&_fastForward)
                                                    toggle:^(__unused LibretroMenuPage *page, BOOL on) {
                                                      LibretroSession *session = weakSelf;
                                                      if (session == nil) return;
                                                      atomic_store(&session->_fastForward, on);
                                                      LibretroCoreHost *host = session->_host;
                                                      LibretroAudioOutput *audio = session->_audio;
                                                      [session enqueue:^{
                                                        host.fastForwarding = on;
                                                        if (!on) [audio clear];
                                                      }];
                                                    }];
  LibretroMenuSection *display = [LibretroMenuSection sectionWithTitle:[self text:@"display"]
                                                                  rows:@[ touch, smooth, fast ]];
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

- (NSArray<NSDictionary *> *)availableSettings {
  NSMutableSet<NSString *> *declared = [NSMutableSet set];
  for (LibretroCoreOption *option in _host.options.options) [declared addObject:option.key];
  NSMutableArray<NSDictionary *> *available = [NSMutableArray array];
  for (NSDictionary *setting in _configuration.coreSettings) {
    NSString *key = [setting[@"key"] isKindOfClass:NSString.class] ? setting[@"key"] : nil;
    if (key != nil && [declared containsObject:key]) [available addObject:setting];
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
