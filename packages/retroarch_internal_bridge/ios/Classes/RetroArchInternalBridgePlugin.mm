#import "RetroArchInternalBridgePlugin.h"
#import "NeoRetroArchCoreAPI.h"
#import "RetroArchSessionMenu.h"
#include "RetroArchRuntimePolicy.h"
#import <UIKit/UIKit.h>
#import <GameController/GameController.h>
#import <QuartzCore/QuartzCore.h>
#import <dlfcn.h>
#include <cstring>
#include <vector>

namespace {
NSString* const kChannel = @"neostation/retroarch_internal";
#ifndef NEO_RETROARCH_FIRST_FRAME_TIMEOUT
#define NEO_RETROARCH_FIRST_FRAME_TIMEOUT 30
#endif
#ifndef NEO_RETROARCH_STOP_TIMEOUT
#define NEO_RETROARCH_STOP_TIMEOUT 15
#endif
constexpr NSTimeInterval kFirstFrameTimeout = NEO_RETROARCH_FIRST_FRAME_TIMEOUT;
constexpr NSTimeInterval kStopTimeout = NEO_RETROARCH_STOP_TIMEOUT;
constexpr size_t kResponseLimit = 1024 * 1024;

void OnMain(dispatch_block_t block) {
  if (NSThread.isMainThread) block();
  else dispatch_async(dispatch_get_main_queue(), block);
}

NSDictionary* Failure(NSString* code, NSString* stage, NSString* detail, BOOL owned) {
  return @{@"success": @NO, @"errorCode": code, @"stage": stage,
           @"detail": detail ?: @"", @"sessionOwned": @(owned)};
}

BOOL Within(NSString* path, NSString* directory) {
  NSString* resolvedPath = path.stringByStandardizingPath.stringByResolvingSymlinksInPath;
  NSString* resolvedDirectory = directory.stringByStandardizingPath.stringByResolvingSymlinksInPath;
  return resolvedPath.length && resolvedDirectory.length &&
      [resolvedPath hasPrefix:[resolvedDirectory stringByAppendingString:@"/"]];
}

NSArray<NSString*>* RequiredLabels() {
  return @[@"menuTitle", @"resumeGame", @"createState", @"loadState", @"coreOptions",
    @"shaders", @"overlays", @"cheats", @"quitGame", @"back", @"slot", @"enabled", @"disabled",
    @"noItems", @"operationFailed", @"loading", @"none", @"cancel", @"confirm", @"addCheat",
    @"importCheats", @"cheatDescription", @"cheatCode", @"deleteCheat", @"filesHelp",
    @"menuAccessibility", @"quitConfirm", @"overwriteState", @"apply", @"unavailable",
    @"savedState", @"emptyState", @"deleteConfirm"];
}
}

@interface NeoRAHostController : UIViewController
@property(nonatomic, copy) dispatch_block_t didAppear;
@end
@implementation NeoRAHostController
- (void)viewDidLoad {
  [super viewDidLoad];
  self.view.backgroundColor = UIColor.blackColor;
  self.modalInPresentation = YES;
}
- (void)viewDidAppear:(BOOL)animated {
  [super viewDidAppear:animated];
  dispatch_block_t callback = self.didAppear;
  self.didAppear = nil;
  if (callback) callback();
}
- (BOOL)prefersStatusBarHidden { return YES; }
- (BOOL)prefersHomeIndicatorAutoHidden { return YES; }
@end

@interface RetroArchInternalBridgePlugin ()
- (void)backendEvent:(uint32_t)event session:(uint64_t)session
              state:(uint32_t)state detail:(NSString*)detail;
@end

static void NeoRAEvent(void* context, uint64_t session, uint32_t event,
                       uint32_t state, const char* detailJSON) {
  RetroArchInternalBridgePlugin* plugin = (__bridge RetroArchInternalBridgePlugin*)context;
  NSString* detail = detailJSON ? [NSString stringWithUTF8String:detailJSON] : @"";
  OnMain(^{ [plugin backendEvent:event session:session state:state detail:detail ?: @""]; });
}

@implementation RetroArchInternalBridgePlugin {
  FlutterMethodChannel* _channel;
  __weak NSObject<FlutterPluginRegistrar>* _registrar;
  const NeoRetroArchCoreAPI* _api;
  void* _runtimeHandle;
  NeoRAHostController* _host;
  UINavigationController* _menu;
  UIButton* _menuButton;
  NSDictionary<NSString*, NSString*>* _labels;
  NSDictionary<NSString*, NSString*>* _paths;
  NSDictionary* _core;
  NSString* _gamePath;
  NSString* _gameTitle;
  NSString* _locale;
  NSString* _runtimePath;
  NSInteger _transaction;
  uint64_t _generation;
  uint32_t _state;
  BOOL _owned;
  BOOL _closing;
  BOOL _finishing;
  BOOL _backendStarted;
  BOOL _resourcesPrepared;
  BOOL _sceneActive;
  FlutterResult _pendingLaunch;
  NSMutableArray<FlutterResult>* _stopResults;
  NSTimer* _startupTimer;
  NSTimer* _stopTimer;
  NSMutableArray<id>* _observers;
}

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar {
  // libretro and RetroArch's global runloop permit exactly one native owner.
  static RetroArchInternalBridgePlugin* instance;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ instance = [[RetroArchInternalBridgePlugin alloc] init]; });
  instance->_registrar = registrar;
  instance->_channel = [FlutterMethodChannel methodChannelWithName:kChannel binaryMessenger:registrar.messenger];
  [registrar addMethodCallDelegate:instance channel:instance->_channel];
}

- (instancetype)init {
  self = [super init];
  if (!self) return nil;
  _stopResults = [NSMutableArray array];
  _observers = [NSMutableArray array];
  _sceneActive = YES;
  __weak RetroArchInternalBridgePlugin* weakSelf = self;
  for (NSNotificationName name in @[UIApplicationWillResignActiveNotification, UIApplicationDidBecomeActiveNotification,
      GCControllerDidConnectNotification, GCControllerDidDisconnectNotification]) {
    id observer = [NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:NSOperationQueue.mainQueue
      usingBlock:^(NSNotification* note) {
        RetroArchInternalBridgePlugin* plugin = weakSelf;
        if (!plugin) return;
        if ([note.name isEqual:GCControllerDidConnectNotification] || [note.name isEqual:GCControllerDidDisconnectNotification])
          [plugin updateMenuButton];
        else {
          plugin->_sceneActive = [note.name isEqual:UIApplicationDidBecomeActiveNotification];
          [plugin updatePause];
        }
      }];
    [_observers addObject:observer];
  }
  return self;
}

- (void)log:(NSString*)event detail:(NSString*)detail {
  NSString* path = _paths[@"logPath"];
  if (!path.length) return;
  NSString* line = [NSString stringWithFormat:@"time=%.3f transaction=%ld generation=%llu state=%u event=%@ detail=%@\n",
      NSDate.date.timeIntervalSince1970, (long)_transaction, (unsigned long long)_generation, _state,
      event, [(detail ?: @"") stringByReplacingOccurrencesOfString:@"\n" withString:@" "]];
  NSFileManager* manager = NSFileManager.defaultManager;
  if (![manager fileExistsAtPath:path]) [manager createFileAtPath:path contents:nil attributes:nil];
  NSFileHandle* file = [NSFileHandle fileHandleForWritingAtPath:path];
  if (!file) return;
  @try { [file seekToEndOfFile]; [file writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; [file closeFile]; }
  @catch (__unused NSException* exception) { }
}

- (NSDictionary*)folders {
  NSString* documents = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
  NSString* root = [documents stringByAppendingPathComponent:@"RetroArch"];
  if (!Within(root, documents)) return Failure(@"RETROARCH_PATH_INVALID", @"folders", root, _owned);
  NSDictionary* names = @{@"systemPath": @"system", @"savePath": @"saves", @"statePath": @"states",
    @"configPath": @"config", @"shaderPath": @"shaders", @"overlayPath": @"overlays", @"cheatPath": @"cheats",
    @"gamesPath": @"games", @"logsPath": @"logs"};
  NSMutableDictionary* paths = [NSMutableDictionary dictionaryWithDictionary:@{@"rootPath": root}];
  for (NSString* key in names) paths[key] = [root stringByAppendingPathComponent:names[key]];
  for (NSString* path in paths.allValues) {
    if (![path isEqual:root] && !Within(path, root)) return Failure(@"RETROARCH_PATH_INVALID", @"folders", path, _owned);
    NSError* error = nil;
    if (![NSFileManager.defaultManager createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:&error])
      return Failure(@"RETROARCH_FOLDER_FAILED", @"folders", error.localizedDescription, _owned);
  }
  paths[@"logPath"] = [paths[@"logsPath"] stringByAppendingPathComponent:@"neostation-retroarch.log"];
  _paths = paths;
  NSMutableDictionary* response = [paths mutableCopy];
  response[@"success"] = @YES;
  return response;
}

- (NSDictionary*)bootstrapResources {
  if (_resourcesPrepared) return nil;
  NSString* source = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"RetroArchResources"];
  BOOL directory = NO;
  if (![NSFileManager.defaultManager fileExistsAtPath:source isDirectory:&directory] || !directory)
    return Failure(@"RETROARCH_RESOURCES_MISSING", @"resources", source, _owned);
  NSFileManager* manager = NSFileManager.defaultManager;
  __block NSError* enumerationError = nil;
  NSDirectoryEnumerator<NSURL*>* files = [manager enumeratorAtURL:[NSURL fileURLWithPath:source]
      includingPropertiesForKeys:@[NSURLIsDirectoryKey, NSURLIsSymbolicLinkKey]
      options:NSDirectoryEnumerationSkipsHiddenFiles errorHandler:^BOOL(NSURL* url, NSError* error) {
        (void)url;
        enumerationError = error;
        return NO;
      }];
  for (NSURL* url in files) {
    NSNumber* symbolic = nil;
    [url getResourceValue:&symbolic forKey:NSURLIsSymbolicLinkKey error:nil];
    if (symbolic.boolValue || !Within(url.path, source))
      return Failure(@"RETROARCH_RESOURCE_PATH_INVALID", @"resources", url.path, _owned);
    NSString* relative = [url.path substringFromIndex:source.length + 1];
    NSString* destination = [_paths[@"rootPath"] stringByAppendingPathComponent:relative];
    if (!Within(destination, _paths[@"rootPath"]))
      return Failure(@"RETROARCH_RESOURCE_PATH_INVALID", @"resources", relative, _owned);
    NSNumber* isDirectory = nil;
    [url getResourceValue:&isDirectory forKey:NSURLIsDirectoryKey error:nil];
    NSError* error = nil;
    if (isDirectory.boolValue) {
      if (![manager createDirectoryAtPath:destination withIntermediateDirectories:YES attributes:nil error:&error])
        return Failure(@"RETROARCH_RESOURCE_COPY_FAILED", @"resources", error.localizedDescription, _owned);
    } else if (![manager fileExistsAtPath:destination]) {
      if (![manager copyItemAtPath:url.path toPath:destination error:&error])
        return Failure(@"RETROARCH_RESOURCE_COPY_FAILED", @"resources", error.localizedDescription, _owned);
    }
    // Existing user-edited overlays, configs and assets are preserved. In-place
    // core updates never replace BIOS, games, saves or imported cheat files.
  }
  if (enumerationError) return Failure(@"RETROARCH_RESOURCE_COPY_FAILED", @"resources", enumerationError.localizedDescription, _owned);
  _resourcesPrepared = YES;
  return nil;
}

- (NSArray<NSDictionary*>*)manifestCores {
  NSString* path = [NSBundle.mainBundle pathForResource:@"retroarch-core-manifest" ofType:@"json"];
  NSData* data = path.length ? [NSData dataWithContentsOfFile:path] : nil;
  id document = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
  id raw = [document isKindOfClass:NSDictionary.class] ? document[@"cores"] : nil;
  NSMutableArray* cores = [NSMutableArray array];
  if ([raw isKindOfClass:NSArray.class])
    for (id core in raw) if ([core isKindOfClass:NSDictionary.class]) [cores addObject:core];
  return cores;
}

- (NSArray<NSString*>*)availableCoreIds {
  NSMutableArray* identifiers = [NSMutableArray array];
  for (NSDictionary* core in [self manifestCores]) {
    NSString* identifier = [core[@"id"] isKindOfClass:NSString.class] ? core[@"id"] : nil;
    NSString* binary = [core[@"binary"] isKindOfClass:NSString.class] ? core[@"binary"] : nil;
    NSString* path = binary.length ? [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:binary] : @"";
    if (identifier.length && Within(path, NSBundle.mainBundle.bundlePath) &&
        [NSFileManager.defaultManager fileExistsAtPath:path]) [identifiers addObject:identifier];
  }
  return identifiers;
}

- (NSDictionary*)diagnostics {
  NSString* path = [self findRuntime];
  NSDictionary* loadError = [self loadRuntime];
  BOOL available = loadError == nil && _api != nullptr;
  NSArray* identifiers = available ? [self availableCoreIds] : @[];
  return @{@"success": @YES, @"hostReady": @YES, @"corePresent": @([NSFileManager.defaultManager fileExistsAtPath:path]),
    @"coreLoaded": @(_api != nullptr), @"corePath": path ?: @"", @"sessionOwned": @(_owned),
    @"backendAvailable": @(available), @"embeddedAvailable": @(available && identifiers.count > 0),
    @"frontendABI": @(available ? NEO_RETROARCH_ABI_VERSION : 0),
    @"availableCoreIds": identifiers, @"availableCoreIdentifiers": identifiers,
    @"backendError": loadError ?: @{},
    @"transaction": @(_transaction), @"state": @(_state), @"abiVersion": @(NEO_RETROARCH_ABI_VERSION),
    @"capabilities": @(_api && _owned ? _api->capabilities(_generation) : 0),
    @"runtimeIdentity": _api ? [NSString stringWithUTF8String:_api->runtime_identity()] : @"",
    @"cores": [self manifestCores], @"logPath": _paths[@"logPath"] ?: @""};
}

- (NSString*)findRuntime {
  NSString* frameworks = NSBundle.mainBundle.privateFrameworksPath;
  for (NSString* filename in @[@"libRetroArchCore.dylib", @"RetroArchCore.framework/RetroArchCore"]) {
    NSString* path = [frameworks stringByAppendingPathComponent:filename];
    if ([NSFileManager.defaultManager fileExistsAtPath:path]) return path;
  }
  return [frameworks stringByAppendingPathComponent:@"libRetroArchCore.dylib"];
}

- (NSDictionary*)loadRuntime {
  if (_api) return nil;
  _runtimePath = [self findRuntime];
  if (![NSFileManager.defaultManager fileExistsAtPath:_runtimePath])
    return Failure(@"RETROARCH_CORE_NOT_READY", @"core_missing", _runtimePath, NO);
  if (!_runtimeHandle) _runtimeHandle = dlopen(_runtimePath.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
  if (!_runtimeHandle) {
    const char* raw = dlerror();
    return Failure(@"RETROARCH_CORE_LOAD_FAILED", @"dlopen", raw ? [NSString stringWithUTF8String:raw] : @"", NO);
  }
  auto getter = reinterpret_cast<NeoRetroArchGetAPIFn>(dlsym(_runtimeHandle, "NeoRetroArch_GetAPI"));
  const NeoRetroArchCoreAPI* candidate = getter ? getter() : nullptr;
  NeoRetroArchAPIValidation validation = NeoRetroArchValidateAPI(candidate);
  if (validation == NEO_RA_API_IDENTITY)
    return Failure(@"RETROARCH_RUNTIME_MISMATCH", @"identity", _runtimePath, NO);
  if (validation != NEO_RA_API_VALID)
    return Failure(@"RETROARCH_ABI_MISMATCH", @"abi", _runtimePath, NO);
  _api = candidate;
  _api->set_event_callback(NeoRAEvent, (__bridge void*)self);
  return nil;
}

- (void)resolveLaunch:(NSDictionary*)response {
  FlutterResult result = _pendingLaunch;
  _pendingLaunch = nil;
  [_startupTimer invalidate];
  _startupTimer = nil;
  if (!result) return;
  NSMutableDictionary* value = [response mutableCopy];
  value[@"transaction"] = @(_transaction);
  value[@"sessionOwned"] = @(_owned);
  value[@"logPath"] = _paths[@"logPath"] ?: @"";
  result(value);
}

- (void)launch:(NSDictionary*)arguments result:(FlutterResult)result {
  if (_owned) { result(Failure(@"RETROARCH_SESSION_ACTIVE", @"session", @"", YES)); return; }
  NSDictionary* labels = [arguments[@"uiText"] isKindOfClass:NSDictionary.class] ? arguments[@"uiText"] : nil;
  for (NSString* key in RequiredLabels()) {
    if (![labels[key] isKindOfClass:NSString.class] || ![labels[key] length]) {
      result(Failure(@"RETROARCH_LOCALIZATION_MISSING", @"localization", key, NO)); return;
    }
  }
  NSString* coreID = [arguments[@"coreId"] isKindOfClass:NSString.class] ? arguments[@"coreId"] : @"";
  NSDictionary* selectedCore = nil;
  for (NSDictionary* core in [self manifestCores])
    if ([core[@"id"] isKindOfClass:NSString.class] && [core[@"id"] isEqual:coreID]) { selectedCore = core; break; }
  NSString* binary = [selectedCore[@"binary"] isKindOfClass:NSString.class] ? selectedCore[@"binary"] : nil;
  NSString* corePath = binary.length ? [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:binary] : @"";
  if (!selectedCore || !Within(corePath, NSBundle.mainBundle.bundlePath) ||
      ![NSFileManager.defaultManager fileExistsAtPath:corePath]) {
    result(Failure(@"RETROARCH_CORE_NOT_ALLOWED", @"core", coreID, NO)); return;
  }
  NSString* game = [arguments[@"gamePath"] isKindOfClass:NSString.class] ? arguments[@"gamePath"] : @"";
  NSString* documents = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
  BOOL directory = NO;
  if (!Within(game, documents) || ![NSFileManager.defaultManager fileExistsAtPath:game isDirectory:&directory] || directory) {
    result(Failure(@"RETROARCH_GAME_PATH_INVALID", @"game", game, NO)); return;
  }
  UIViewController* presenter = _registrar.viewController;
  if (!presenter || !presenter.view.window || presenter.presentedViewController || presenter.isBeingDismissed) {
    result(Failure(@"RETROARCH_HOST_NOT_READY", @"host", @"", NO)); return;
  }
  NSDictionary* folders = [self folders];
  if (![folders[@"success"] boolValue]) { result(folders); return; }
  NSDictionary* loadError = [self loadRuntime];
  if (loadError) { result(loadError); return; }
  NSDictionary* resourceError = [self bootstrapResources];
  if (resourceError) { result(resourceError); return; }
  NeoRetroArchPaths paths = {sizeof(NeoRetroArchPaths), _paths[@"rootPath"].fileSystemRepresentation,
    _paths[@"systemPath"].fileSystemRepresentation, _paths[@"savePath"].fileSystemRepresentation,
    _paths[@"statePath"].fileSystemRepresentation, _paths[@"configPath"].fileSystemRepresentation,
    _paths[@"shaderPath"].fileSystemRepresentation, _paths[@"overlayPath"].fileSystemRepresentation,
    _paths[@"cheatPath"].fileSystemRepresentation, _paths[@"logPath"].fileSystemRepresentation};
  char error[2048] = {};
  if (_api->initialize(&paths, error, sizeof(error)) != 0) {
    result(Failure(@"RETROARCH_INITIALIZE_FAILED", @"initialize", [NSString stringWithUTF8String:error], NO)); return;
  }
  _transaction = [arguments[@"transaction"] integerValue];
  if (_transaction <= 0) { result(Failure(@"RETROARCH_TRANSACTION_INVALID", @"session", @"", NO)); return; }
  _generation += 1;
  _owned = YES;
  _closing = NO;
  _finishing = NO;
  _backendStarted = NO;
  _state = NEO_RA_STARTING;
  _pendingLaunch = result;
  _core = selectedCore;
  _gamePath = game;
  _gameTitle = [arguments[@"gameTitle"] isKindOfClass:NSString.class] ? arguments[@"gameTitle"] : @"RetroArch";
  _locale = [arguments[@"locale"] isKindOfClass:NSString.class] ? arguments[@"locale"] : @"en";
  _labels = labels;
  _host = [NeoRAHostController new];
  _host.modalPresentationStyle = UIModalPresentationFullScreen;
  _host.modalInPresentation = YES;
  const uint64_t generation = _generation;
  __weak RetroArchInternalBridgePlugin* weakSelf = self;
  _host.didAppear = ^{
    RetroArchInternalBridgePlugin* plugin = weakSelf;
    if (!plugin || !plugin->_owned || plugin->_generation != generation || plugin->_closing) return;
    NeoRetroArchLaunch launch = {sizeof(NeoRetroArchLaunch), generation,
      corePath.fileSystemRepresentation, plugin->_gamePath.fileSystemRepresentation,
      plugin->_locale.UTF8String, (__bridge void*)plugin->_host.view};
    char detail[2048] = {};
    [plugin log:@"start" detail:coreID];
    plugin->_backendStarted = YES;
    if (plugin->_api->start(&launch, detail, sizeof(detail)) != 0) {
      [plugin resolveLaunch:Failure(@"RETROARCH_START_FAILED", @"start", [NSString stringWithUTF8String:detail], YES)];
      // The backend's start failure contract has no live core; a state failure
      // callback can also arrive synchronously and is filtered by ownership.
      [plugin finish:NO reason:@"launchFailure" detail:[NSString stringWithUTF8String:detail]];
    } else if (plugin->_owned && !plugin->_closing) {
      [plugin addMenuButton];
      [plugin updatePause];
    }
  };
  _startupTimer = [NSTimer scheduledTimerWithTimeInterval:kFirstFrameTimeout repeats:NO block:^(__unused NSTimer* timer) {
    RetroArchInternalBridgePlugin* plugin = weakSelf;
    if (!plugin || !plugin->_owned || plugin->_generation != generation || !plugin->_pendingLaunch) return;
    [plugin resolveLaunch:Failure(@"RETROARCH_FIRST_FRAME_TIMEOUT", @"first_frame", @"", YES)];
    [plugin requestStop:nil];
  }];
  [presenter presentViewController:_host animated:NO completion:nil];
}

- (void)addMenuButton {
  if (!_host || _closing) return;
  [_menuButton removeFromSuperview];
  _menuButton = [UIButton buttonWithType:UIButtonTypeSystem];
  _menuButton.translatesAutoresizingMaskIntoConstraints = NO;
  [_menuButton setImage:[UIImage systemImageNamed:@"line.3.horizontal.circle.fill"] forState:UIControlStateNormal];
  _menuButton.tintColor = UIColor.whiteColor;
  _menuButton.backgroundColor = [UIColor.blackColor colorWithAlphaComponent:0.45];
  _menuButton.layer.cornerRadius = 22;
  _menuButton.accessibilityLabel = _labels[@"menuAccessibility"];
  [_menuButton addTarget:self action:@selector(openMenu) forControlEvents:UIControlEventTouchUpInside];
  [_host.view addSubview:_menuButton];
  [NSLayoutConstraint activateConstraints:@[
    [_menuButton.widthAnchor constraintEqualToConstant:44], [_menuButton.heightAnchor constraintEqualToConstant:44],
    [_menuButton.trailingAnchor constraintEqualToAnchor:_host.view.safeAreaLayoutGuide.trailingAnchor constant:-12],
    [_menuButton.topAnchor constraintEqualToAnchor:_host.view.safeAreaLayoutGuide.topAnchor constant:8]]];
  [self updateMenuButton];
}

- (void)updateMenuButton {
  BOOL controller = NO;
  for (GCController* gamepad in GCController.controllers) {
    // Keep a touch menu entry for remotes/controllers without the Select+Start
    // pair; their mere connection must not make the session menu inaccessible.
    if (gamepad.extendedGamepad.buttonOptions && gamepad.extendedGamepad.buttonMenu) {
      controller = YES;
      break;
    }
  }
  _menuButton.hidden = controller || _menu != nil || _closing;
  if (_menuButton && _host.view) [_host.view bringSubviewToFront:_menuButton];
}

- (void)updatePause {
  if (!_api || !_owned || _closing || (_state != NEO_RA_RUNNING && _state != NEO_RA_PAUSED)) return;
  BOOL paused = !_sceneActive || _menu != nil;
  if ((_state == NEO_RA_PAUSED) == paused) return;
  char error[2048] = {};
  if (_api->set_paused(_generation, paused ? 1 : 0, error, sizeof(error)) != 0)
    [self log:@"pause_failed" detail:[NSString stringWithUTF8String:error]];
}

- (void)openMenu {
  if (!_owned || _closing || _menu || !_host || (_state != NEO_RA_RUNNING && _state != NEO_RA_PAUSED)) return;
  char error[2048] = {};
  if (_api->set_paused(_generation, 1, error, sizeof(error)) != 0) { [self log:@"menu_pause_failed" detail:[NSString stringWithUTF8String:error]]; return; }
  RetroArchSessionMenu* menu = [RetroArchSessionMenu new];
  menu.labels = _labels;
  menu.gameTitle = _gameTitle;
  menu.capabilities = _api->capabilities(_generation);
  menu.cheatsPath = _paths[@"cheatPath"];
  const uint64_t generation = _generation;
  __weak RetroArchInternalBridgePlugin* weakSelf = self;
  menu.performCommand = ^(NSDictionary* request, void (^completion)(NSDictionary*)) {
    RetroArchInternalBridgePlugin* plugin = weakSelf;
    if (!plugin || plugin->_generation != generation || !plugin->_owned || plugin->_closing) {
      completion(Failure(@"RETROARCH_SESSION_ENDED", @"command", @"", NO)); return;
    }
    completion([plugin command:request]);
  };
  menu.resumeGame = ^{
    RetroArchInternalBridgePlugin* plugin = weakSelf;
    if (plugin && plugin->_generation == generation) [plugin resumeMenu];
  };
  menu.quitGame = ^{
    RetroArchInternalBridgePlugin* plugin = weakSelf;
    if (plugin && plugin->_generation == generation) [plugin requestStop:nil];
  };
  _menu = [[UINavigationController alloc] initWithRootViewController:menu];
  _menu.modalPresentationStyle = UIModalPresentationFormSheet;
  _menu.modalInPresentation = YES;
  [self updateMenuButton];
  [_host presentViewController:_menu animated:YES completion:nil];
}

- (void)resumeMenu {
  if (!_menu) return;
  UINavigationController* menu = _menu;
  __weak RetroArchInternalBridgePlugin* weakSelf = self;
  [menu dismissViewControllerAnimated:YES completion:^{
    RetroArchInternalBridgePlugin* plugin = weakSelf;
    if (!plugin || plugin->_menu != menu) return;
    plugin->_menu = nil;
    [plugin updatePause];
    [plugin updateMenuButton];
  }];
}

- (NSDictionary*)command:(NSDictionary*)request {
  if (!_owned || !_api || _closing || (_state != NEO_RA_RUNNING && _state != NEO_RA_PAUSED))
    return Failure(@"RETROARCH_SESSION_NOT_READY", @"command", @"", _owned);
  NSString* command = [request[@"command"] isKindOfClass:NSString.class] ? request[@"command"] : @"";
  NSDictionary* required = @{@"readStates": @(NEO_RA_CAP_SAVE_STATES), @"saveState": @(NEO_RA_CAP_SAVE_STATES),
    @"loadState": @(NEO_RA_CAP_SAVE_STATES), @"readOptions": @(NEO_RA_CAP_CORE_OPTIONS), @"setOption": @(NEO_RA_CAP_CORE_OPTIONS),
    @"readShaders": @(NEO_RA_CAP_SHADERS), @"applyShader": @(NEO_RA_CAP_SHADERS), @"readOverlays": @(NEO_RA_CAP_OVERLAYS),
    @"applyOverlay": @(NEO_RA_CAP_OVERLAYS), @"readCheats": @(NEO_RA_CAP_CHEATS), @"setCheat": @(NEO_RA_CAP_CHEATS),
    @"addCheat": @(NEO_RA_CAP_CHEATS), @"deleteCheat": @(NEO_RA_CAP_CHEATS), @"importCheats": @(NEO_RA_CAP_CHEATS)};
  NSNumber* capability = required[command];
  if (!capability || !(_api->capabilities(_generation) & capability.unsignedLongLongValue))
    return Failure(@"RETROARCH_COMMAND_UNSUPPORTED", @"command", command, _owned);
  NSDictionary* pathKeys = @{@"applyShader": @"shaderPath", @"applyOverlay": @"overlayPath", @"importCheats": @"cheatPath"};
  if (pathKeys[command]) {
    NSString* path = [request[@"path"] isKindOfClass:NSString.class] ? request[@"path"] : nil;
    BOOL noneAllowed = ![command isEqual:@"importCheats"];
    if (!path || (path.length && !Within(path, _paths[pathKeys[command]])) || (!path.length && !noneAllowed))
      return Failure(@"RETROARCH_COMMAND_PATH_INVALID", @"command", command, _owned);
  }
  NSData* json = [NSJSONSerialization isValidJSONObject:request] ? [NSJSONSerialization dataWithJSONObject:request options:0 error:nil] : nil;
  if (!json || json.length > 128 * 1024) return Failure(@"RETROARCH_COMMAND_INVALID", @"command", command, _owned);
  NSString* jsonString = [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
  std::vector<char> response(kResponseLimit, 0);
  char error[2048] = {};
  int status = _api->command(_generation, jsonString.UTF8String, response.data(), response.size(), error, sizeof(error));
  NSData* responseData = [NSData dataWithBytes:response.data() length:strnlen(response.data(), response.size())];
  id value = [NSJSONSerialization JSONObjectWithData:responseData options:0 error:nil];
  if (status != 0 || ![value isKindOfClass:NSDictionary.class] || ![value[@"success"] boolValue]) {
    [self log:@"command_failed" detail:[NSString stringWithUTF8String:error]];
    return [value isKindOfClass:NSDictionary.class] && ![value[@"success"] boolValue] ? value
        : Failure(@"RETROARCH_COMMAND_FAILED", @"command", [NSString stringWithUTF8String:error], _owned);
  }
  return value;
}

- (void)requestStop:(FlutterResult)result {
  if (!_owned) { if (result) result(@{@"success": @YES, @"sessionOwned": @NO}); return; }
  if (result) [_stopResults addObject:[result copy]];
  if (_closing) return;
  _closing = YES;
  _state = NEO_RA_STOPPING;
  [self updateMenuButton];
  [_startupTimer invalidate];
  _startupTimer = nil;
  [self log:@"stop_requested" detail:@""];
  if (!_backendStarted) {
    // A launch cancelled before the host view appears never entered the backend.
    _host.didAppear = nil;
    [self finish:YES reason:@"userReturn" detail:@""];
    return;
  }
  char error[2048] = {};
  int status = _api->request_stop(_generation, error, sizeof(error));
  if (status != 0) {
    _closing = NO;
    _state = _api->session_state(_generation);
    [self updateMenuButton];
    NSDictionary* failure = Failure(@"RETROARCH_STOP_FAILED", @"stop", [NSString stringWithUTF8String:error], YES);
    [self resolveLaunch:failure];
    NSArray* completions = [_stopResults copy];
    [_stopResults removeAllObjects];
    for (FlutterResult completion in completions) completion(failure);
    return;
  }
  if (!_owned || _finishing) return; // A synchronous STOPPED callback already acknowledged.
  const uint64_t generation = _generation;
  __weak RetroArchInternalBridgePlugin* weakSelf = self;
  _stopTimer = [NSTimer scheduledTimerWithTimeInterval:kStopTimeout repeats:NO block:^(__unused NSTimer* timer) {
    RetroArchInternalBridgePlugin* plugin = weakSelf;
    if (!plugin || !plugin->_owned || plugin->_generation != generation) return;
    NSDictionary* failure = Failure(@"RETROARCH_STOP_TIMEOUT", @"stop", @"", YES);
    [plugin resolveLaunch:failure];
    NSArray* completions = [plugin->_stopResults copy];
    [plugin->_stopResults removeAllObjects];
    for (FlutterResult completion in completions) completion(failure);
    [plugin log:@"stop_timeout" detail:@""];
    // Do not dismiss a renderer still used by the backend or permit another core.
  }];
}

- (void)dismissAcknowledgedHost:(dispatch_block_t)released generation:(uint64_t)generation {
  if (!_owned || !_finishing || _generation != generation) return;
  UIViewController* transitioning = _host.presentedViewController ?: _host;
  if (transitioning.isBeingPresented || transitioning.isBeingDismissed || _host.isBeingPresented || _host.isBeingDismissed) {
    id<UIViewControllerTransitionCoordinator> coordinator = transitioning.transitionCoordinator ?: _host.transitionCoordinator;
    __weak RetroArchInternalBridgePlugin* weakSelf = self;
    if (coordinator && [coordinator animateAlongsideTransition:nil completion:^(__unused id<UIViewControllerTransitionCoordinatorContext> context) {
      [weakSelf dismissAcknowledgedHost:released generation:generation];
    }]) return;
    // UIKit can briefly report an in-flight transition before its coordinator
    // exists. Keep the acknowledged core's host until that transition settles.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
      [weakSelf dismissAcknowledgedHost:released generation:generation];
    });
    return;
  }
  if (_host.presentingViewController) [_host dismissViewControllerAnimated:NO completion:released];
  else released();
}

- (void)finish:(BOOL)success reason:(NSString*)reason detail:(NSString*)detail {
  if (!_owned || _finishing) return;
  _finishing = YES;
  _closing = YES;
  [_startupTimer invalidate]; _startupTimer = nil;
  [_stopTimer invalidate]; _stopTimer = nil;
  _host.didAppear = nil;
  [self resolveLaunch:Failure(@"RETROARCH_ENDED_BEFORE_FIRST_FRAME", @"startup", detail, YES)];
  const NSInteger transaction = _transaction;
  const uint64_t generation = _generation;
  [self log:@"session_ended" detail:detail];
  dispatch_block_t released = ^{
    if (!self->_owned || self->_generation != generation) return;
    self->_owned = NO;
    self->_closing = NO;
    self->_finishing = NO;
    self->_backendStarted = NO;
    self->_host = nil;
    self->_menu = nil;
    self->_menuButton = nil;
    self->_state = success ? NEO_RA_STOPPED : NEO_RA_FAILED;
    NSDictionary* event = @{@"transaction": @(transaction), @"success": @(success), @"exitReason": reason,
      @"detail": detail ?: @"", @"runtimeReleased": @YES, @"sessionOwned": @NO,
      @"logPath": self->_paths[@"logPath"] ?: @""};
    NSArray* completions = [self->_stopResults copy];
    [self->_stopResults removeAllObjects];
    for (FlutterResult completion in completions) completion(@{@"success": @(success), @"sessionOwned": @NO, @"transaction": @(transaction)});
    [self->_channel invokeMethod:@"sessionEnded" arguments:event];
  };
  [self dismissAcknowledgedHost:released generation:generation];
}

- (void)backendEvent:(uint32_t)event session:(uint64_t)session state:(uint32_t)state detail:(NSString*)detail {
  if (!_owned || session != _generation) return;
  if (event == NEO_RA_EVENT_MENU_REQUESTED) { [self openMenu]; return; }
  if (event == NEO_RA_EVENT_DIAGNOSTIC) { [self log:@"backend" detail:detail]; return; }
  if (event == NEO_RA_EVENT_COMMAND_RESULT) {
    NSData* data = [detail dataUsingEncoding:NSUTF8StringEncoding];
    id response = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if ([response isKindOfClass:NSDictionary.class]) {
      UIViewController* page = _menu.topViewController;
      if ([page isKindOfClass:RetroArchSessionMenu.class]) [(RetroArchSessionMenu*)page completePendingOperation:response];
      [_channel invokeMethod:@"sessionEvent" arguments:@{@"transaction": @(_transaction), @"commandResult": response}];
    }
    [self log:@"command_result" detail:detail];
    return;
  }
  if (event != NEO_RA_EVENT_STATE) return;
  _state = state;
  [self log:@"state" detail:detail];
  if (state == NEO_RA_RUNNING && !_closing) {
    [self resolveLaunch:@{@"success": @YES, @"stage": @"first_frame"}];
    [self updatePause];
    [self updateMenuButton];
  } else if (state == NEO_RA_STOPPED || state == NEO_RA_FAILED) {
    [self finish:state == NEO_RA_STOPPED reason:state == NEO_RA_STOPPED ? @"userReturn" : @"runtimeFailure" detail:detail];
    return;
  }
  [_channel invokeMethod:@"sessionEvent" arguments:@{@"transaction": @(_transaction), @"state": @(state), @"detail": detail ?: @""}];
}

- (void)handleMethodCall:(FlutterMethodCall*)call result:(FlutterResult)result {
  OnMain(^{
    NSDictionary* arguments = [call.arguments isKindOfClass:NSDictionary.class] ? call.arguments : @{};
    if ([call.method isEqual:@"folders"]) { result([self folders]); return; }
    if ([call.method isEqual:@"diagnostics"]) { result([self diagnostics]); return; }
    if ([call.method isEqual:@"launch"]) { [self launch:arguments result:result]; return; }
    if ([call.method isEqual:@"stop"] || [call.method isEqual:@"showMenu"] || [call.method isEqual:@"command"]) {
      if (self->_owned && [arguments[@"transaction"] integerValue] != self->_transaction) {
        result(Failure(@"RETROARCH_STALE_TRANSACTION", @"session", @"", self->_owned)); return;
      }
      if ([call.method isEqual:@"stop"]) { [self requestStop:result]; return; }
      if ([call.method isEqual:@"showMenu"]) {
        [self openMenu];
        result(@{@"success": @(self->_menu != nil), @"sessionOwned": @(self->_owned)}); return;
      }
      NSDictionary* request = [arguments[@"request"] isKindOfClass:NSDictionary.class] ? arguments[@"request"] : @{};
      result([self command:request]); return;
    }
    result(FlutterMethodNotImplemented);
  });
}
@end
