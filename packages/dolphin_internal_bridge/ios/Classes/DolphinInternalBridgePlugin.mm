#import "DolphinInternalBridgePlugin.h"
#import "DolphinSessionMenu.h"
#import "DolphinSessionLifecycle.h"
#import <dolphin_internal_bridge/dolphin_internal_bridge-Swift.h>
#import <GameController/GameController.h>

#import <AVFoundation/AVFoundation.h>
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <Security/Security.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <poll.h>
#import <stdio.h>
#import <arpa/inet.h>
#import <netinet/in.h>
#import <sys/socket.h>
#import <sys/types.h>
#import <unistd.h>

#import <atomic>

extern "C" {
char* neostation_dolphin_save_identity(const char* game_path, const char* expected_system);
int32_t neostation_dolphin_initialize(const char* user_directory,
                                      const char* system_directory,
                                      const char* log_path);
int32_t neostation_dolphin_validate_image(const char* game_path,
                                          const char* expected_system,
                                          const char* log_path);
// Bit 0: legacy breakpoint returned. Bit 1: executable probe returned 42.
int32_t neostation_dolphin_prepare_legacy_jit(const char* log_path);
// Bit 0: JITARM64 initialized. Bit 1: Metal presenter initialized.
// Bit 2: game accepted and submitted to the core.
int32_t neostation_dolphin_launch(const char* game_path,
                                  const char* expected_system,
                                  void* metal_layer,
                                  double metal_scale,
                                  const char* log_path);
int32_t neostation_dolphin_is_running(void);
int32_t neostation_dolphin_set_paused(int32_t paused);
int32_t neostation_dolphin_stop(const char* log_path);
char* neostation_dolphin_menu_snapshot(int32_t wii, int32_t slot);
int32_t neostation_dolphin_menu_apply(const char* request_json);
char* neostation_dolphin_state_snapshot(void);
int32_t neostation_dolphin_state_operation(int32_t slot, int32_t load);
int32_t neostation_dolphin_restart(void);
int32_t neostation_dolphin_refresh_controllers(void);
void neostation_dolphin_release_touches(void);

void* SecTaskCreateFromSelf(CFAllocatorRef allocator);
CFTypeRef SecTaskCopyValueForEntitlement(void* task,
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

static NSString* const kDolphinChannel = @"neostation/dolphin_internal";
static NSString* const kDolphinRequestType = @"com.neogamelab.neostation.dolphin-jit-request";
static NSTimeInterval const kHelperLaunchTimeout = 30.0;
static NSTimeInterval const kDebuggerAttachTimeout = 240.0;
static NSTimeInterval const kLegacyCompletionTimeout = 90.0;

static void DOLAppendJSONLog(NSString* path,
                             NSString* stage,
                             NSString* message,
                             NSDictionary* _Nullable details) {
  if (path.length == 0) return;
  @synchronized([DolphinInternalBridgePlugin class]) {
    NSMutableDictionary* entry = [@{
      @"timestamp" : @([[NSDate date] timeIntervalSince1970]),
      @"engine" : @"dolphin_internal",
      @"stage" : stage ?: @"unknown",
      @"message" : message ?: @"",
    } mutableCopy];
    if (details != nil) [entry addEntriesFromDictionary:details];
    NSError* jsonError = nil;
    NSData* data = [NSJSONSerialization dataWithJSONObject:entry options:0 error:&jsonError];
    if (data == nil || jsonError != nil) return;

    NSFileManager* fm = NSFileManager.defaultManager;
    NSString* directory = [path stringByDeletingLastPathComponent];
    [fm createDirectoryAtPath:directory
  withIntermediateDirectories:YES
                   attributes:nil
                        error:nil];
    if (![fm fileExistsAtPath:path]) [fm createFileAtPath:path contents:nil attributes:nil];
    NSFileHandle* handle = [NSFileHandle fileHandleForWritingAtPath:path];
    if (handle == nil) return;
    @try {
      [handle seekToEndOfFile];
      [handle writeData:data];
      [handle writeData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]];
      [handle synchronizeFile];
    } @catch (__unused NSException* exception) {
    }
    [handle closeFile];
  }
}

static BOOL DOLHostHasGetTaskAllow(void) {
  void* task = SecTaskCreateFromSelf(NULL);
  if (task == NULL) return NO;
  CFTypeRef value = SecTaskCopyValueForEntitlement(
      task, CFSTR("get-task-allow"), NULL);
  BOOL result = value == kCFBooleanTrue;
  if (value != NULL) CFRelease(value);
  CFRelease(task);
  return result;
}

static BOOL DOLHostIsDebugged(void) {
  uint32_t flags = 0;
  if (csops(getpid(), CS_OPS_STATUS, &flags, sizeof(flags)) != 0) return NO;
  return (flags & CS_DEBUGGED) != 0;
}

static UIViewController* _Nullable DOLRootViewController(void) {
  UIWindow* keyWindow = nil;
  if (@available(iOS 13.0, *)) {
    for (UIScene* scene in UIApplication.sharedApplication.connectedScenes) {
      if (scene.activationState != UISceneActivationStateForegroundActive ||
          ![scene isKindOfClass:UIWindowScene.class]) {
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
  }
  if (keyWindow == nil) {
    for (UIWindow* window in UIApplication.sharedApplication.windows) {
      if (window.isKeyWindow) {
        keyWindow = window;
        break;
      }
    }
  }
  UIViewController* controller = keyWindow.rootViewController;
  while (controller.presentedViewController != nil) {
    controller = controller.presentedViewController;
  }
  return controller;
}

@interface DOLDolphinViewController : UIViewController
@property(nonatomic, readonly) MTKView* metalView;
@property(nonatomic, copy, nullable) dispatch_block_t closeHandler;
@property(nonatomic, copy, nullable) dispatch_block_t menuHandler;
@property(nonatomic, copy) NSString* menuLabel;
@property(nonatomic, assign) BOOL wii;
@property(nonatomic, strong) DOLTouchOverlay* touchOverlay;
@property(nonatomic, assign) BOOL acceptsTouchInput;
- (void)refreshTouchVisibility;
- (void)suspendTouchInput;
@end

@implementation DOLDolphinViewController {
  MTKView* _metalView;
}

- (instancetype)init {
  self = [super init];
  if (self) {
    self.modalPresentationStyle = UIModalPresentationFullScreen;
    self.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
  }
  return self;
}

- (void)loadView {
  id<MTLDevice> device = MTLCreateSystemDefaultDevice();
  _metalView = [[MTKView alloc] initWithFrame:UIScreen.mainScreen.bounds device:device];
  _metalView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  _metalView.enableSetNeedsDisplay = NO;
  // Dolphin presents directly to CAMetalLayer. MTKView must not run a second
  // display loop or acquire drawables while the emulator owns the surface.
  _metalView.paused = YES;
  _metalView.backgroundColor = UIColor.blackColor;
  self.view = _metalView;

  self.touchOverlay = [[DOLTouchOverlay alloc] initWithWii:self.wii];
  self.touchOverlay.frame = self.view.bounds;
  self.touchOverlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  [self.view addSubview:self.touchOverlay];
  self.acceptsTouchInput = YES;
  for (NSNotificationName name in @[GCControllerDidConnectNotification, GCControllerDidDisconnectNotification])
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(refreshTouchVisibility) name:name object:nil];
  [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(releaseTouchInput)
      name:UIApplicationWillResignActiveNotification object:nil];
  [self refreshTouchVisibility];

  UIButton* close = [UIButton buttonWithType:UIButtonTypeSystem];
  close.translatesAutoresizingMaskIntoConstraints = NO;
  close.accessibilityLabel = self.menuLabel;
  close.layer.cornerRadius = 18.0;
  close.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.55];
  close.tintColor = UIColor.whiteColor;
  UIImage* image = [UIImage systemImageNamed:@"line.3.horizontal"];
  [close setImage:image forState:UIControlStateNormal];
  [close addTarget:self action:@selector(menuPressed:) forControlEvents:UIControlEventTouchUpInside];
  [self.view addSubview:close];
  [NSLayoutConstraint activateConstraints:@[
    [close.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:12.0],
    [close.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:12.0],
    [close.widthAnchor constraintEqualToConstant:44.0],
    [close.heightAnchor constraintEqualToConstant:44.0],
  ]];
}

- (MTKView*)metalView {
  return _metalView;
}

- (void)releaseTouchInput {
  if (self.acceptsTouchInput) neostation_dolphin_release_touches();
}

- (void)suspendTouchInput {
  self.touchOverlay.userInteractionEnabled = NO;
  [self releaseTouchInput];
  self.acceptsTouchInput = NO;
}

- (void)refreshTouchVisibility {
  if (!NSThread.isMainThread) {
    dispatch_async(dispatch_get_main_queue(), ^{ [self refreshTouchVisibility]; });
    return;
  }
  if (!self.acceptsTouchInput) return;
  [self releaseTouchInput];
  self.touchOverlay.hidden = GCController.controllers.count > 0;
}

- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }

- (void)closePressed:(__unused id)sender {
  if (self.closeHandler != nil) self.closeHandler();
}

- (void)menuPressed:(__unused id)sender {
  if (self.menuHandler != nil) self.menuHandler();
}

- (BOOL)prefersHomeIndicatorAutoHidden {
  return YES;
}

- (BOOL)prefersStatusBarHidden {
  return YES;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
  return UIInterfaceOrientationMaskLandscape;
}

@end

@interface DOLHelperSession : NSObject
@property(nonatomic, readonly) uint16_t port;
@property(nonatomic, readonly) NSString* token;
@property(nonatomic, readonly) BOOL connected;
@property(nonatomic, readonly) BOOL finished;
@property(nonatomic, readonly) BOOL success;
@property(nonatomic, readonly) NSString* finalMessage;
@property(nonatomic, readonly) NSArray<NSString*>* logs;
@property(nonatomic, strong, nullable) id extensionObject;
@property(nonatomic, strong, nullable) id requestIdentifier;
- (nullable instancetype)initWithLogPath:(NSString*)logPath error:(NSError**)error;
- (void)startReader;
- (BOOL)waitUntilConnected:(NSTimeInterval)timeout;
- (BOOL)waitUntilFinished:(NSTimeInterval)timeout;
- (void)close;
@end

@implementation DOLHelperSession {
  int _listener;
  int _client;
  uint16_t _port;
  NSString* _token;
  NSString* _logPath;
  NSCondition* _condition;
  BOOL _connected;
  BOOL _finished;
  BOOL _success;
  NSString* _finalMessage;
  NSMutableArray<NSString*>* _mutableLogs;
  dispatch_queue_t _readerQueue;
}

- (nullable instancetype)initWithLogPath:(NSString*)logPath error:(NSError**)error {
  self = [super init];
  if (!self) return nil;

  _listener = socket(AF_INET, SOCK_STREAM, 0);
  _client = -1;
  if (_listener < 0) {
    if (error != NULL) {
      *error = [NSError errorWithDomain:@"NeoStationDolphin"
                                   code:1001
                               userInfo:@{NSLocalizedDescriptionKey : @"Could not create the helper loopback socket."}];
    }
    return nil;
  }

  int reuse = 1;
  setsockopt(_listener, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));
  struct sockaddr_in address = {};
  address.sin_family = AF_INET;
  address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  address.sin_port = 0;
  if (bind(_listener, (struct sockaddr*)&address, sizeof(address)) != 0 ||
      listen(_listener, 1) != 0) {
    close(_listener);
    _listener = -1;
    if (error != NULL) {
      *error = [NSError errorWithDomain:@"NeoStationDolphin"
                                   code:1002
                               userInfo:@{NSLocalizedDescriptionKey : @"Could not bind the helper loopback socket."}];
    }
    return nil;
  }

  socklen_t length = sizeof(address);
  if (getsockname(_listener, (struct sockaddr*)&address, &length) != 0) {
    close(_listener);
    _listener = -1;
    if (error != NULL) {
      *error = [NSError errorWithDomain:@"NeoStationDolphin"
                                   code:1003
                               userInfo:@{NSLocalizedDescriptionKey : @"Could not determine the helper socket port."}];
    }
    return nil;
  }

  _port = ntohs(address.sin_port);
  _token = NSUUID.UUID.UUIDString;
  _logPath = [logPath copy];
  _condition = [[NSCondition alloc] init];
  _mutableLogs = [[NSMutableArray alloc] init];
  _finalMessage = @"";
  _readerQueue = dispatch_queue_create("com.neogamelab.neostation.dolphin.helper-reader", DISPATCH_QUEUE_SERIAL);
  return self;
}

- (uint16_t)port { return _port; }
- (NSString*)token { return _token; }

- (BOOL)connected {
  [_condition lock];
  BOOL value = _connected;
  [_condition unlock];
  return value;
}

- (BOOL)finished {
  [_condition lock];
  BOOL value = _finished;
  [_condition unlock];
  return value;
}

- (BOOL)success {
  [_condition lock];
  BOOL value = _success;
  [_condition unlock];
  return value;
}

- (NSString*)finalMessage {
  [_condition lock];
  NSString* value = [_finalMessage copy];
  [_condition unlock];
  return value;
}

- (NSArray<NSString*>*)logs {
  [_condition lock];
  NSArray<NSString*>* value = [_mutableLogs copy];
  [_condition unlock];
  return value;
}

- (void)startReader {
  __weak DOLHelperSession* weakSelf = self;
  dispatch_async(_readerQueue, ^{
    DOLHelperSession* strongSelf = weakSelf;
    if (strongSelf == nil) return;

    struct pollfd descriptor = {strongSelf->_listener, POLLIN, 0};
    int pollResult = poll(&descriptor, 1, (int)(kHelperLaunchTimeout * 1000.0));
    if (pollResult <= 0) {
      [strongSelf markFinished:NO message:@"The Dolphin JIT helper did not connect to NeoStation."];
      return;
    }

    strongSelf->_client = accept(strongSelf->_listener, NULL, NULL);
    if (strongSelf->_client < 0) {
      [strongSelf markFinished:NO message:@"The Dolphin JIT helper socket could not be accepted."];
      return;
    }

    FILE* stream = fdopen(strongSelf->_client, "r");
    if (stream == NULL) {
      [strongSelf markFinished:NO message:@"The Dolphin JIT helper stream could not be opened."];
      return;
    }
    strongSelf->_client = -1;  // fd is now owned by FILE.

    char buffer[65536];
    while (fgets(buffer, sizeof(buffer), stream) != NULL) {
      @autoreleasepool {
        NSString* line = [[NSString alloc] initWithUTF8String:buffer];
        line = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (line.length == 0) continue;
        NSData* data = [line dataUsingEncoding:NSUTF8StringEncoding];
        NSDictionary* payload = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (![payload isKindOfClass:NSDictionary.class] ||
            ![payload[@"token"] isEqualToString:strongSelf->_token]) {
          continue;
        }
        NSString* event = payload[@"event"];
        NSString* message = [payload[@"message"] isKindOfClass:NSString.class]
                                ? payload[@"message"]
                                : @"";
        DOLAppendJSONLog(strongSelf->_logPath,
                         [@"helper." stringByAppendingString:event ?: @"unknown"],
                         message,
                         nil);

        [strongSelf->_condition lock];
        if ([event isEqualToString:@"helper_connected"]) {
          strongSelf->_connected = YES;
        } else if ([event isEqualToString:@"log"]) {
          if (message.length > 0) [strongSelf->_mutableLogs addObject:message];
        } else if ([event isEqualToString:@"complete"]) {
          strongSelf->_finished = YES;
          strongSelf->_success = [payload[@"success"] boolValue];
          strongSelf->_finalMessage = message ?: @"";
        }
        [strongSelf->_condition broadcast];
        [strongSelf->_condition unlock];
      }
      if (strongSelf.finished) break;
    }
    fclose(stream);
    if (!strongSelf.finished) {
      [strongSelf markFinished:NO message:@"The Dolphin JIT helper disconnected before completing the legacy handshake."];
    }
  });
}

- (void)markFinished:(BOOL)success message:(NSString*)message {
  [_condition lock];
  _finished = YES;
  _success = success;
  _finalMessage = message ?: @"";
  [_condition broadcast];
  [_condition unlock];
  DOLAppendJSONLog(_logPath, @"helper.finished", _finalMessage,
                   @{ @"success" : @(success) });
}

- (BOOL)waitForPredicate:(BOOL (^)(void))predicate timeout:(NSTimeInterval)timeout {
  NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
  [_condition lock];
  while (!predicate()) {
    if (![_condition waitUntilDate:deadline]) break;
  }
  BOOL value = predicate();
  [_condition unlock];
  return value;
}

- (BOOL)waitUntilConnected:(NSTimeInterval)timeout {
  return [self waitForPredicate:^BOOL { return self->_connected || self->_finished; }
                         timeout:timeout] && self.connected;
}

- (BOOL)waitUntilFinished:(NSTimeInterval)timeout {
  return [self waitForPredicate:^BOOL { return self->_finished; }
                         timeout:timeout];
}

- (void)close {
  if (_listener >= 0) {
    shutdown(_listener, SHUT_RDWR);
    close(_listener);
    _listener = -1;
  }
  if (_client >= 0) {
    shutdown(_client, SHUT_RDWR);
    close(_client);
    _client = -1;
  }
}

- (void)dealloc {
  [self close];
}

@end

static NSString* _Nullable DOLFindHelperBundleIdentifier(void) {
  NSURL* plugins = NSBundle.mainBundle.builtInPlugInsURL;
  if (plugins == nil) return nil;
  NSArray<NSURL*>* entries = [NSFileManager.defaultManager
      contentsOfDirectoryAtURL:plugins
    includingPropertiesForKeys:nil
                       options:0
                         error:nil];
  for (NSURL* entry in entries) {
    if (![entry.pathExtension.lowercaseString isEqualToString:@"appex"]) continue;
    NSBundle* bundle = [NSBundle bundleWithURL:entry];
    NSDictionary* extension = [bundle objectForInfoDictionaryKey:@"NSExtension"];
    NSString* point = [extension isKindOfClass:NSDictionary.class]
                          ? extension[@"NSExtensionPointIdentifier"]
                          : nil;
    NSString* marker = [bundle objectForInfoDictionaryKey:@"NeoStationDolphinJITHelper"];
    if ([point isEqualToString:@"com.apple.share-services"] &&
        [marker isEqualToString:@"1"] && bundle.bundleIdentifier.length > 0) {
      return bundle.bundleIdentifier;
    }
  }
  return nil;
}

static BOOL DOLLaunchHelper(DOLHelperSession* session,
                            NSData* pairingData,
                            NSString* logPath,
                            NSError** error) {
  NSString* helperIdentifier = DOLFindHelperBundleIdentifier();
  if (helperIdentifier.length == 0) {
    if (error != NULL) {
      *error = [NSError errorWithDomain:@"NeoStationDolphin"
                                   code:1101
                               userInfo:@{NSLocalizedDescriptionKey : @"The embedded Dolphin JIT helper extension is missing."}];
    }
    return NO;
  }

  NSDictionary* request = @{
    @"protocolVersion" : @1,
    @"targetPID" : @(getpid()),
    @"port" : @(session.port),
    @"token" : session.token,
    @"pairingData" : [pairingData base64EncodedStringWithOptions:0],
  };
  NSData* requestData = [NSJSONSerialization dataWithJSONObject:request options:0 error:error];
  if (requestData == nil) return NO;

  NSItemProvider* provider = [[NSItemProvider alloc] initWithItem:requestData
                                                   typeIdentifier:kDolphinRequestType];
  NSExtensionItem* item = [[NSExtensionItem alloc] init];
  item.attachments = @[ provider ];

  Class extensionClass = NSClassFromString(@"NSExtension");
  SEL createSelector = NSSelectorFromString(@"extensionWithIdentifier:error:");
  SEL beginSelector = NSSelectorFromString(@"beginExtensionRequestWithInputItems:completion:");
  if (extensionClass == Nil || ![extensionClass respondsToSelector:createSelector]) {
    if (error != NULL) {
      *error = [NSError errorWithDomain:@"NeoStationDolphin"
                                   code:1102
                               userInfo:@{NSLocalizedDescriptionKey : @"This iOS build cannot start the embedded Dolphin JIT helper."}];
    }
    return NO;
  }

  id (*createMessage)(id, SEL, NSString*, NSError**) =
      reinterpret_cast<id (*)(id, SEL, NSString*, NSError**)>(objc_msgSend);
  id extensionObject = createMessage(extensionClass, createSelector, helperIdentifier, error);
  if (extensionObject == nil || ![extensionObject respondsToSelector:beginSelector]) return NO;
  session.extensionObject = extensionObject;

  __weak DOLHelperSession* weakSession = session;
  void (^completion)(id) = ^(id requestIdentifier) {
    DOLHelperSession* strongSession = weakSession;
    strongSession.requestIdentifier = requestIdentifier;
    DOLAppendJSONLog(logPath, @"helper.request_started",
                     @"Embedded Dolphin JIT helper request started.",
                     @{ @"helperBundle" : helperIdentifier });
  };
  void (*beginMessage)(id, SEL, NSArray*, id) =
      reinterpret_cast<void (*)(id, SEL, NSArray*, id)>(objc_msgSend);
  beginMessage(extensionObject, beginSelector, @[ item ], completion);
  return YES;
}

@interface DolphinInternalBridgePlugin ()
@property(nonatomic, strong) FlutterMethodChannel* channel;
@property(atomic, strong, nullable) DOLDolphinViewController* dolphinController;
@property(nonatomic, strong, nullable) DOLHelperSession* helperSession;
@property(nonatomic, strong, nullable) dispatch_source_t runningTimer;
@property(nonatomic, copy, nullable) NSString* activeLogPath;
@property(nonatomic, assign) BOOL launchInProgress;
@property(atomic, assign) BOOL stopInProgress;
@property(nonatomic, assign) BOOL monitorPollInProgress;
@property(nonatomic, strong, nullable) UINavigationController* sessionMenu;
@property(nonatomic, assign) BOOL menuOpening;
@property(nonatomic, assign) BOOL wiiSession;
@property(nonatomic, copy, nullable) NSString* saveSessionToken;
@property(nonatomic, copy) NSDictionary<NSString*, NSString*>* menuLabels;
// These values belong to the Dolphin session, not to the global audio policy.
@property(nonatomic, copy, nullable) NSString* previousAudioCategory;
@property(nonatomic, copy, nullable) NSString* previousAudioMode;
@property(nonatomic, assign) AVAudioSessionCategoryOptions previousAudioOptions;
@property(nonatomic, assign) BOOL audioPolicyCaptured;
@end

@implementation DolphinInternalBridgePlugin {
  dispatch_queue_t _runtimeQueue;
}

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar {
  FlutterMethodChannel* channel = [FlutterMethodChannel methodChannelWithName:kDolphinChannel
                                                              binaryMessenger:registrar.messenger];
  DolphinInternalBridgePlugin* instance = [[DolphinInternalBridgePlugin alloc] init];
  instance.channel = channel;
  [registrar addMethodCallDelegate:instance channel:channel];
}

- (instancetype)init {
  self = [super init];
  if (self) {
    _runtimeQueue = dispatch_queue_create("com.neogamelab.neostation.dolphin.runtime", DISPATCH_QUEUE_SERIAL);
  }
  return self;
}

- (void)handleMethodCall:(FlutterMethodCall*)call result:(FlutterResult)result {
  if ([call.method isEqualToString:@"saveIdentity"]) {
    NSDictionary* args = [call.arguments isKindOfClass:NSDictionary.class] ? call.arguments : @{};
    NSString* gamePath = [args[@"gamePath"] isKindOfClass:NSString.class] ? args[@"gamePath"] : @"";
    NSString* system = [args[@"system"] isKindOfClass:NSString.class] ? args[@"system"] : @"";
    dispatch_async(_runtimeQueue, ^{
      char* json = neostation_dolphin_save_identity(gamePath.fileSystemRepresentation, system.UTF8String);
      NSDictionary* identity = nil;
      if (json) {
        NSData* data = [[NSString stringWithUTF8String:json] dataUsingEncoding:NSUTF8StringEncoding];
        free(json);
        id decoded = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if ([decoded isKindOfClass:NSDictionary.class]) identity = decoded;
      }
      dispatch_async(dispatch_get_main_queue(), ^{ result(identity); });
    });
    return;
  }
  if ([call.method isEqualToString:@"launchGame"]) {
    NSDictionary* arguments = [call.arguments isKindOfClass:NSDictionary.class]
                                  ? call.arguments
                                  : @{};
    dispatch_async(_runtimeQueue, ^{
      NSDictionary* response = [self launchWithArguments:arguments];
      dispatch_async(dispatch_get_main_queue(), ^{ result(response); });
    });
    return;
  }
  if ([call.method isEqualToString:@"stop"]) {
    dispatch_async(_runtimeQueue, ^{
      [self stopRuntimeWithReason:@"user_request"];
      dispatch_async(dispatch_get_main_queue(), ^{ result(@YES); });
    });
    return;
  }
  if ([call.method isEqualToString:@"isRunning"]) {
    result(@(self.launchInProgress || self.stopInProgress || neostation_dolphin_is_running() != 0));
    return;
  }
  result(FlutterMethodNotImplemented);
}

- (NSDictionary*)launchWithArguments:(NSDictionary*)arguments {
  NSMutableDictionary* state = [@{
    @"success" : @NO,
    @"stikjitConnected" : @NO,
    @"pidAttached" : @NO,
    @"legacyHandshakeValidated" : @NO,
    @"executableMemoryValidated" : @NO,
    @"jitArm64Initialized" : @NO,
    @"metalInitialized" : @NO,
    @"imageAccepted" : @NO,
    @"gameSubmitted" : @NO,
    @"logs" : @[],
  } mutableCopy];

  @synchronized(self) {
    if (self.launchInProgress || self.stopInProgress || neostation_dolphin_is_running() != 0) {
      state[@"message"] = @"A Dolphin session is already active.";
      return state;
    }
    self.launchInProgress = YES;
  }

  self.saveSessionToken = [arguments[@"saveSessionToken"] isKindOfClass:NSString.class]
      ? arguments[@"saveSessionToken"] : nil;
  NSString* gamePath = [arguments[@"gamePath"] isKindOfClass:NSString.class]
                           ? arguments[@"gamePath"] : @"";
  NSString* system = [[arguments[@"system"] isKindOfClass:NSString.class]
                          ? arguments[@"system"] : @"" lowercaseString];
  NSString* userDirectory = [arguments[@"userDirectory"] isKindOfClass:NSString.class]
                                ? arguments[@"userDirectory"] : @"";
  NSString* systemDirectory = [arguments[@"systemDirectory"] isKindOfClass:NSString.class]
                                  ? arguments[@"systemDirectory"] : @"";
  NSString* logPath = [arguments[@"logPath"] isKindOfClass:NSString.class]
                          ? arguments[@"logPath"] : @"";
  NSString* pairingPath = [arguments[@"pairingFilePath"] isKindOfClass:NSString.class]
                              ? arguments[@"pairingFilePath"] : @"";
  self.activeLogPath = logPath;

  void (^fail)(NSString*, NSString*) = ^(NSString* stage, NSString* message) {
    state[@"message"] = message;
    state[@"failedStage"] = stage;
    DOLAppendJSONLog(logPath, stage, message, @{ @"authorized" : @NO });
  };

  @try {
    if (![system isEqualToString:@"gc"] && ![system isEqualToString:@"wii"]) {
      fail(@"route.rejected", @"The internal Dolphin engine is restricted to GameCube and Wii.");
      return [self finishFailedLaunch:state];
    }
    if (gamePath.length == 0 || ![NSFileManager.defaultManager fileExistsAtPath:gamePath]) {
      fail(@"image.missing", @"The selected GameCube/Wii image is not readable.");
      return [self finishFailedLaunch:state];
    }
    if (@available(iOS 17.4, *)) {
    } else {
      fail(@"stikjit.unsupported_ios", @"Built-in StikJIT requires iOS 17.4 or newer.");
      return [self finishFailedLaunch:state];
    }
    if (!DOLHostHasGetTaskAllow()) {
      fail(@"stikjit.entitlement_missing",
           @"This NeoStation installation does not preserve get-task-allow; Dolphin JIT is blocked.");
      return [self finishFailedLaunch:state];
    }
    NSData* pairingData = [[NSData alloc] initWithContentsOfFile:pairingPath options:NSDataReadingMappedIfSafe error:nil];
    if (pairingData.length == 0) {
      fail(@"stikjit.pairing_missing", @"Import a readable pairing file before launching Dolphin.");
      return [self finishFailedLaunch:state];
    }

    DOLAppendJSONLog(logPath, @"core.initialize", @"Initializing the embedded Dolphin core.", nil);
    if (neostation_dolphin_initialize(userDirectory.fileSystemRepresentation,
                                     systemDirectory.fileSystemRepresentation,
                                     logPath.fileSystemRepresentation) != 1) {
      fail(@"core.initialize_failed", @"The embedded Dolphin core could not initialize.");
      return [self finishFailedLaunch:state];
    }

    if (neostation_dolphin_validate_image(gamePath.fileSystemRepresentation,
                                          system.UTF8String,
                                          logPath.fileSystemRepresentation) != 1) {
      fail(@"image.rejected", @"Dolphin rejected the selected image or its platform does not match the playlist.");
      return [self finishFailedLaunch:state];
    }
    state[@"imageAccepted"] = @YES;
    DOLAppendJSONLog(logPath, @"image.accepted", @"Dolphin accepted the image for the requested system.", nil);

    NSError* helperError = nil;
    DOLHelperSession* helper = [[DOLHelperSession alloc] initWithLogPath:logPath error:&helperError];
    if (helper == nil) {
      fail(@"stikjit.helper_socket_failed", helperError.localizedDescription ?: @"Could not prepare the Dolphin JIT helper.");
      return [self finishFailedLaunch:state];
    }
    self.helperSession = helper;
    [helper startReader];
    if (!DOLLaunchHelper(helper, pairingData, logPath, &helperError)) {
      fail(@"stikjit.helper_launch_failed", helperError.localizedDescription ?: @"Could not launch the embedded Dolphin JIT helper.");
      return [self finishFailedLaunch:state];
    }
    if (![helper waitUntilConnected:kHelperLaunchTimeout]) {
      fail(@"stikjit.not_connected", helper.finalMessage.length > 0
                                              ? helper.finalMessage
                                              : @"The embedded StikJIT helper did not connect.");
      return [self finishFailedLaunch:state];
    }
    state[@"stikjitConnected"] = @YES;
    DOLAppendJSONLog(logPath, @"stikjit.connected", @"Embedded StikJIT helper connected.", nil);

    NSDate* attachDeadline = [NSDate dateWithTimeIntervalSinceNow:kDebuggerAttachTimeout];
    while (!DOLHostIsDebugged() && [attachDeadline timeIntervalSinceNow] > 0.0) {
      if (helper.finished) break;
      [NSThread sleepForTimeInterval:0.10];
    }
    if (!DOLHostIsDebugged()) {
      NSString* reason = helper.finalMessage.length > 0
                             ? helper.finalMessage
                             : @"StikJIT did not attach to the NeoStation PID before timeout.";
      fail(@"stikjit.pid_attach_failed", reason);
      return [self finishFailedLaunch:state];
    }
    state[@"pidAttached"] = @YES;
    DOLAppendJSONLog(logPath, @"stikjit.pid_attached",
                     @"The Dolphin legacy script is attached to the NeoStation PID.",
                     @{ @"pid" : @(getpid()) });

    int32_t jitFlags = neostation_dolphin_prepare_legacy_jit(logPath.fileSystemRepresentation);
    if ((jitFlags & 0x1) != 0) state[@"legacyHandshakeValidated"] = @YES;
    if ((jitFlags & 0x2) != 0) state[@"executableMemoryValidated"] = @YES;

    if (![helper waitUntilFinished:kLegacyCompletionTimeout] || !helper.success) {
      NSString* reason = helper.finalMessage.length > 0
                             ? helper.finalMessage
                             : @"StikJIT did not complete the legacy breakpoint transaction.";
      fail(@"stikjit.legacy_completion_failed", reason);
      state[@"logs"] = helper.logs;
      return [self finishFailedLaunch:state];
    }
    state[@"logs"] = helper.logs;
    if ((jitFlags & 0x1) == 0) {
      fail(@"stikjit.legacy_handshake_failed", @"The legacy BRK #0x69 handshake did not return successfully.");
      return [self finishFailedLaunch:state];
    }
    if ((jitFlags & 0x2) == 0) {
      fail(@"jit.executable_probe_failed", @"The executable memory probe did not execute the generated ARM64 code.");
      return [self finishFailedLaunch:state];
    }
    DOLAppendJSONLog(logPath, @"jit.executable_probe_passed",
                     @"Executable memory returned the expected ARM64 probe value.", nil);

    __block DOLDolphinViewController* controller = nil;
    dispatch_sync(dispatch_get_main_queue(), ^{
      UIViewController* root = DOLRootViewController();
      if (root == nil) return;
      controller = [[DOLDolphinViewController alloc] init];
      self.wiiSession = [system isEqual:@"wii"];
      controller.wii = self.wiiSession;
      self.menuLabels = [arguments[@"menuLabels"] isKindOfClass:NSDictionary.class]
          ? arguments[@"menuLabels"] : @{};
      controller.menuLabel = self.menuLabels[@"menu"] ?: @"Dolphin";
      __weak DolphinInternalBridgePlugin* weakSelf = self;
      controller.menuHandler = ^{ [weakSelf presentSessionMenu]; };
      controller.closeHandler = ^{
        DolphinInternalBridgePlugin* strongSelf = weakSelf;
        if (strongSelf == nil) return;
        dispatch_async(strongSelf->_runtimeQueue, ^{
          [strongSelf stopRuntimeWithReason:@"overlay_close"];
        });
      };
      [root presentViewController:controller animated:NO completion:nil];
    });
    if (controller == nil || controller.metalView.device == nil ||
        [controller.metalView.device newCommandQueue] == nil) {
      fail(@"metal.preflight_failed", @"Metal could not create a device, view and command queue.");
      return [self finishFailedLaunch:state];
    }
    self.dolphinController = controller;

    // Capture and change shared audio only once this Dolphin session owns a
    // real emulation view. An entitlement/JIT failure must not mute NeoStation.
    dispatch_sync(dispatch_get_main_queue(), ^{
      AVAudioSession* audio = AVAudioSession.sharedInstance;
      self.previousAudioCategory = audio.category;
      self.previousAudioMode = audio.mode;
      self.previousAudioOptions = audio.categoryOptions;
      self.audioPolicyCaptured = YES;
      NSError* audioError = nil;
      [audio setCategory:AVAudioSessionCategoryPlayback
                   mode:AVAudioSessionModeDefault
                options:AVAudioSessionCategoryOptionMixWithOthers
                  error:&audioError];
      if (audioError == nil) [audio setActive:YES error:&audioError];
      if (audioError != nil) {
        DOLAppendJSONLog(logPath, @"audio.warning", audioError.localizedDescription, nil);
      }
    });

    CAMetalLayer* layer = (CAMetalLayer*)controller.metalView.layer;
    int32_t launchFlags = neostation_dolphin_launch(
        gamePath.fileSystemRepresentation,
        system.UTF8String,
        (__bridge void*)layer,
        UIScreen.mainScreen.scale,
        logPath.fileSystemRepresentation);
    if ((launchFlags & 0x1) != 0) state[@"jitArm64Initialized"] = @YES;
    if ((launchFlags & 0x2) != 0) state[@"metalInitialized"] = @YES;
    if ((launchFlags & 0x4) != 0) state[@"gameSubmitted"] = @YES;

    if ((launchFlags & 0x1) == 0) {
      fail(@"jit.jitarm64_failed", @"Dolphin did not initialize JITARM64; interpreter fallback is forbidden.");
      return [self finishFailedLaunch:state];
    }
    if ((launchFlags & 0x2) == 0) {
      fail(@"metal.initialize_failed", @"Dolphin did not initialize its Metal presenter.");
      return [self finishFailedLaunch:state];
    }
    if ((launchFlags & 0x4) == 0) {
      fail(@"core.game_not_submitted", @"The validated image was not submitted to the Dolphin core.");
      return [self finishFailedLaunch:state];
    }

    state[@"success"] = @YES;
    state[@"message"] = @"Dolphin JITARM64 and Metal are ready; the game was submitted.";
    DOLAppendJSONLog(logPath, @"launch.authorized",
                     @"All Dolphin readiness gates passed; launch authorized.",
                     @{ @"system" : system, @"pid" : @(getpid()) });
    [self startRunningMonitor];
    @synchronized(self) { self.launchInProgress = NO; }
    return state;
  } @catch (NSException* exception) {
    fail(@"native.exception", exception.reason ?: @"Unknown native Dolphin exception.");
    return [self finishFailedLaunch:state];
  }
}

- (void)presentSessionMenu {
  if (self.launchInProgress || self.stopInProgress || self.menuOpening || self.sessionMenu || !self.dolphinController) return;
  self.menuOpening = YES;
  neostation_dolphin_release_touches();
  self.dolphinController.touchOverlay.userInteractionEnabled = NO;
  DOLAppendJSONLog(self.activeLogPath ?: @"", @"menu.open.begin", @"Opening in-game settings.", nil);
  DOLDolphinViewController* owner = self.dolphinController;
  __weak DolphinInternalBridgePlugin* weakSelf = self;
  dispatch_async(_runtimeQueue, ^{
    const BOOL paused = neostation_dolphin_set_paused(1) != 0;
    dispatch_async(dispatch_get_main_queue(), ^{
      DolphinInternalBridgePlugin* strongSelf = weakSelf;
      if (!strongSelf) return;
      strongSelf.menuOpening = NO;
      if (!paused || strongSelf.stopInProgress || strongSelf.dolphinController != owner) {
        owner.touchOverlay.userInteractionEnabled = YES;
        return;
      }
      @try {
      DolphinSessionMenu* menu = [[DolphinSessionMenu alloc] init];
      menu.labels = strongSelf.menuLabels;
      menu.wii = strongSelf.wiiSession;
      menu.readSettings = ^(BOOL wii, NSInteger slot, void (^completion)(NSDictionary*)) {
        DolphinInternalBridgePlugin* bridge = weakSelf;
        if (!bridge) { completion(nil); return; }
        dispatch_async(bridge->_runtimeQueue, ^{
          @autoreleasepool {
          char* text = neostation_dolphin_menu_snapshot(wii ? 1 : 0, (int32_t)slot);
          NSDictionary* snapshot = nil;
          if (text) {
            NSData* data = [[NSString stringWithUTF8String:text] dataUsingEncoding:NSUTF8StringEncoding];
            free(text);
            id decoded = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if ([decoded isKindOfClass:NSDictionary.class]) snapshot = decoded;
          }
          dispatch_async(dispatch_get_main_queue(), ^{
            if (bridge.stopInProgress || bridge.dolphinController != owner) return;
            if (wii && slot == 0) {
              for (NSDictionary* item in snapshot[@"extensions"])
                if ([item[@"selected"] boolValue]) [owner.touchOverlay updateExtension:item[@"name"]];
            }
            completion(snapshot);
          });
          }
        });
      };
      menu.applySettings = ^(NSDictionary* request, void (^completion)(BOOL)) {
        DolphinInternalBridgePlugin* bridge = weakSelf;
        if (!bridge) { completion(NO); return; }
        dispatch_async(bridge->_runtimeQueue, ^{
          NSData* data = [NSJSONSerialization dataWithJSONObject:request options:0 error:nil];
          NSString* text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
          const BOOL success = text && neostation_dolphin_menu_apply(text.UTF8String) != 0;
          dispatch_async(dispatch_get_main_queue(), ^{
            if (!bridge.stopInProgress && bridge.dolphinController == owner) completion(success);
          });
        });
      };
      menu.readStates = ^(void (^completion)(NSDictionary*)) {
        DolphinInternalBridgePlugin* bridge = weakSelf;
        if (!bridge || bridge.stopInProgress || bridge.dolphinController != owner) { completion(nil); return; }
        dispatch_async(bridge->_runtimeQueue, ^{
          char* text = neostation_dolphin_state_snapshot();
          NSDictionary* snapshot = nil;
          if (text) {
            NSData* data = [[NSString stringWithUTF8String:text] dataUsingEncoding:NSUTF8StringEncoding];
            free(text);
            id decoded = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
            if ([decoded isKindOfClass:NSDictionary.class]) snapshot = decoded;
          }
          dispatch_async(dispatch_get_main_queue(), ^{
            if (!bridge.stopInProgress && bridge.dolphinController == owner) completion(snapshot);
          });
        });
      };
      menu.performStateOperation = ^(NSInteger slot, BOOL load, void (^completion)(BOOL)) {
        DolphinInternalBridgePlugin* bridge = weakSelf;
        if (!bridge || bridge.stopInProgress || bridge.menuOpening || bridge.dolphinController != owner) { completion(NO); return; }
        bridge.menuOpening = YES;
        dispatch_async(bridge->_runtimeQueue, ^{
          const BOOL success = neostation_dolphin_state_operation((int32_t)slot, load ? 1 : 0) != 0;
          dispatch_async(dispatch_get_main_queue(), ^{
            if (bridge.stopInProgress || bridge.dolphinController != owner) return;
            bridge.menuOpening = NO;
            completion(success);
          });
        });
      };
      menu.resumeGame = ^{
        DolphinInternalBridgePlugin* bridge = weakSelf;
        if (!bridge || bridge.stopInProgress || bridge.menuOpening || !bridge.sessionMenu) return;
        bridge.menuOpening = YES;
        [bridge.sessionMenu dismissViewControllerAnimated:YES completion:^{
          bridge.sessionMenu = nil;
          bridge.menuOpening = NO;
          if (bridge.stopInProgress || bridge.dolphinController != owner) return;
          [owner refreshTouchVisibility];
          owner.touchOverlay.userInteractionEnabled = YES;
          dispatch_async(bridge->_runtimeQueue, ^{ neostation_dolphin_set_paused(0); });
        }];
      };
      menu.quitGame = ^{
        DolphinInternalBridgePlugin* bridge = weakSelf;
        if (!bridge || bridge.stopInProgress || bridge.menuOpening) return;
        bridge.stopInProgress = YES;
        bridge.menuOpening = YES;
        bridge.sessionMenu.view.userInteractionEnabled = NO;
        dispatch_async(bridge->_runtimeQueue, ^{ [bridge stopRuntimeWithReason:@"session_menu_quit"]; });
      };
      menu.restartGame = ^{
        DolphinInternalBridgePlugin* bridge = weakSelf;
        if (!bridge || bridge.stopInProgress || bridge.launchInProgress || bridge.menuOpening) return;
        bridge.launchInProgress = YES;
        bridge.menuOpening = YES;
        bridge.sessionMenu.view.userInteractionEnabled = NO;
        dispatch_async(bridge->_runtimeQueue, ^{
          const BOOL restarted = neostation_dolphin_restart() != 0;
          if (!restarted) neostation_dolphin_stop(bridge.activeLogPath.fileSystemRepresentation);
          dispatch_async(dispatch_get_main_queue(), ^{
            if (!restarted) {
              bridge.launchInProgress = NO;
              [bridge cleanupSharedResourcesAndUI];
              UIAlertController* alert = [UIAlertController alertControllerWithTitle:bridge.menuLabels[@"restartFailed"]
                  message:nil preferredStyle:UIAlertControllerStyleAlert];
              [alert addAction:[UIAlertAction actionWithTitle:bridge.menuLabels[@"close"] style:UIAlertActionStyleCancel handler:nil]];
              [DOLRootViewController() presentViewController:alert animated:YES completion:nil];
              return;
            }
            [bridge.sessionMenu dismissViewControllerAnimated:YES completion:^{
              bridge.sessionMenu = nil;
              bridge.menuOpening = NO;
              bridge.launchInProgress = NO;
              [owner refreshTouchVisibility];
              owner.touchOverlay.userInteractionEnabled = YES;
            }];
          });
        });
      };
      UINavigationController* navigation = [[UINavigationController alloc] initWithRootViewController:menu];
      // Keep the CAMetalLayer attached to its window throughout presentation.
      navigation.modalPresentationStyle = UIModalPresentationOverFullScreen;
      navigation.modalInPresentation = YES;
      strongSelf.sessionMenu = navigation;
      [owner presentViewController:navigation animated:YES completion:^{
        DOLAppendJSONLog(strongSelf.activeLogPath ?: @"", @"menu.open.complete", @"In-game menu presented.", nil);
      }];
      } @catch (NSException* exception) {
        strongSelf.sessionMenu = nil;
        owner.touchOverlay.userInteractionEnabled = YES;
        DOLAppendJSONLog(strongSelf.activeLogPath ?: @"", @"menu.presentation_failed", exception.reason ?: @"UIKit presentation failed.", nil);
        dispatch_async(strongSelf->_runtimeQueue, ^{ neostation_dolphin_set_paused(0); });
      }
    });
  });
}

- (NSDictionary*)finishFailedLaunch:(NSMutableDictionary*)state {
  self.saveSessionToken = nil;
  [self prepareSessionForStop];
  [self.helperSession close];
  self.helperSession = nil;
  neostation_dolphin_stop(self.activeLogPath.fileSystemRepresentation);
  [self cleanupSharedResourcesAndUI];
  @synchronized(self) { self.launchInProgress = NO; }
  return state;
}

- (void)startRunningMonitor {
  dispatch_async(dispatch_get_main_queue(), ^{
    if (self.runningTimer != nil) {
      dispatch_source_cancel(self.runningTimer);
      self.runningTimer = nil;
    }
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                                     dispatch_get_main_queue());
    self.runningTimer = timer;
    self.monitorPollInProgress = NO;
    dispatch_source_set_timer(timer,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                              (uint64_t)(0.5 * NSEC_PER_SEC),
                              (uint64_t)(0.1 * NSEC_PER_SEC));
    __weak DolphinInternalBridgePlugin* weakSelf = self;
    dispatch_source_set_event_handler(timer, ^{
      DolphinInternalBridgePlugin* strongSelf = weakSelf;
      if (!strongSelf || strongSelf.launchInProgress || strongSelf.stopInProgress ||
          strongSelf.monitorPollInProgress || !strongSelf.dolphinController) return;
      strongSelf.monitorPollInProgress = YES;
      DOLDolphinViewController* owner = strongSelf.dolphinController;
      // Serialize status checks with pause/restart/stop. A false running flag
      // during Core::Shutdown must never detach the surface from the main timer.
      dispatch_async(strongSelf->_runtimeQueue, ^{
        if (strongSelf.stopInProgress || strongSelf.dolphinController != owner) {
          dispatch_async(dispatch_get_main_queue(), ^{
            if (strongSelf.dolphinController == owner) strongSelf.monitorPollInProgress = NO;
          });
          return;
        }
        if (neostation_dolphin_is_running() == 0) {
          [strongSelf stopRuntimeWithReason:@"core_stopped"];
          return;
        }
        const int32_t layout = neostation_dolphin_refresh_controllers();
        dispatch_async(dispatch_get_main_queue(), ^{
          if (strongSelf.dolphinController != owner) return;
          strongSelf.monitorPollInProgress = NO;
          if (strongSelf.stopInProgress) return;
          if (layout && strongSelf.wiiSession)
            [owner.touchOverlay updateExtension:layout == 2 ? @"Classic" : @"Nunchuk"];
        });
      });
    });
    dispatch_resume(timer);
  });
}

- (void)stopRuntimeWithReason:(NSString*)reason {
  NSString* saveToken = self.saveSessionToken;
  self.saveSessionToken = nil;
  [self prepareSessionForStop];
  NSString* logPath = self.activeLogPath ?: @"";
  DOLAppendJSONLog(logPath, @"session.stop_requested", @"Stopping the Dolphin session.",
                   @{ @"reason" : reason ?: @"unknown" });
  const BOOL savesFlushed = neostation_dolphin_stop(logPath.fileSystemRepresentation) == 1;
  [self.helperSession close];
  self.helperSession = nil;
  [self cleanupSharedResourcesAndUI];
  @synchronized(self) { self.launchInProgress = NO; }
  if (saveToken.length > 0 && savesFlushed) {
    // Core shutdown/joins and resource cleanup above have completed. A mere
    // pause, menu dismissal or app background event must NEVER trigger upload.
    dispatch_async(dispatch_get_main_queue(), ^{
      [self.channel invokeMethod:@"saveSessionStopped" arguments:@{
        @"token": saveToken, @"reason": reason ?: @"unknown", @"savesFlushed": @YES
      }];
    });
  }
}

- (void)prepareSessionForStop {
  // The runtime queue waits only for this short UI operation, before entering
  // any core shutdown locks. Keep the game and its Metal layer attached until
  // the real emulation thread has joined.
  dispatch_block_t prepare = ^{
    self.stopInProgress = YES;
    self.menuOpening = YES;
    if (self.runningTimer) {
      dispatch_source_cancel(self.runningTimer);
      self.runningTimer = nil;
    }
    self.sessionMenu.view.userInteractionEnabled = NO;
    self.dolphinController.menuHandler = nil;
    self.dolphinController.closeHandler = nil;
    [self.dolphinController suspendTouchInput];
  };
  if (NSThread.isMainThread) prepare();
  else dispatch_sync(dispatch_get_main_queue(), prepare);
}

- (void)cleanupSharedResourcesAndUI {
  dispatch_block_t cleanup = ^{
    if (self.runningTimer != nil) {
      dispatch_source_cancel(self.runningTimer);
      self.runningTimer = nil;
    }
    DOLDolphinViewController* controller = self.dolphinController;
    self.dolphinController = nil;
    self.sessionMenu = nil;
    self.menuOpening = NO;
    self.monitorPollInProgress = NO;
    if (controller != nil) {
      controller.closeHandler = nil;
      controller.menuHandler = nil;
      DOLDismissSessionController(controller);
      DOLAppendJSONLog(self.activeLogPath ?: @"", @"session.ui_dismissed",
                       @"Dolphin game and settings dismissed after core shutdown.", nil);
    }
    if (self.audioPolicyCaptured) {
      // Restore the policy used before Dolphin, instead of deactivating the
      // whole application's audio session while the frontend is still active.
      AVAudioSession* audio = AVAudioSession.sharedInstance;
      NSError* error = nil;
      [audio setCategory:self.previousAudioCategory
                    mode:self.previousAudioMode
                 options:self.previousAudioOptions
                   error:&error];
      if (error == nil && UIApplication.sharedApplication.applicationState == UIApplicationStateActive) {
        [audio setActive:YES error:&error];
      }
      DOLAppendJSONLog(self.activeLogPath ?: @"",
                       error == nil ? @"audio.policy_restored" : @"audio.restore_warning",
                       error.localizedDescription ?: @"Pre-Dolphin audio policy restored.", nil);
      self.audioPolicyCaptured = NO;
      self.previousAudioCategory = nil;
      self.previousAudioMode = nil;
    }
    self.activeLogPath = nil;
    self.stopInProgress = NO;
  };
  // Finish releasing the session before allowing a subsequent emulator launch.
  if (NSThread.isMainThread) cleanup();
  else dispatch_sync(dispatch_get_main_queue(), cleanup);
}

@end
