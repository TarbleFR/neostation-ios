#import <UIKit/UIKit.h>
#import "Flutter/Flutter.h"
#import "../ios/Classes/RetroArchInternalBridgePlugin.h"
#import "../ios/Classes/NeoRetroArchCoreAPI.h"
#import <dlfcn.h>
#import <QuartzCore/QuartzCore.h>
#include <stdexcept>

NSObject* const FlutterMethodNotImplemented = [NSObject new];
static NSMutableArray<NSDictionary*>* channelEvents;
@implementation FlutterMethodCall
@end
@implementation FlutterMethodChannel
+ (instancetype)methodChannelWithName:(NSString*)name binaryMessenger:(NSObject<FlutterBinaryMessenger>*)messenger {
  (void)name; (void)messenger;
  return [self new];
}
- (void)invokeMethod:(NSString*)method arguments:(id)arguments {
  [channelEvents addObject:@{@"method": method, @"arguments": arguments ?: @{}}];
}
@end

@interface ProbeRegistrar : NSObject <FlutterPluginRegistrar, FlutterBinaryMessenger>
@property(nonatomic, strong) UIViewController* viewController;
@property(nonatomic, strong) id<FlutterPlugin> delegate;
@end
@implementation ProbeRegistrar
- (NSObject<FlutterBinaryMessenger>*)messenger { return self; }
- (void)addMethodCallDelegate:(id)delegate channel:(FlutterMethodChannel*)channel {
  (void)channel; self.delegate = delegate;
}
@end

typedef void (*ProbeAutomaticFn)(int, int);
typedef void (*ProbeEmitFn)(uint64_t, uint32_t);
typedef uint64_t (*ProbeSessionFn)(void);
typedef int (*ProbeCountFn)(void);

@interface ProbeRunner : NSObject
@property(nonatomic, strong) ProbeRegistrar* registrar;
@property(nonatomic, strong) NSTimer* timer;
@property(nonatomic, copy) NSDictionary* labels;
@property(nonatomic, copy) NSString* gamePath;
@property(nonatomic, strong) NSDictionary* launchResponse;
@property(nonatomic, strong) NSDictionary* stopResponse;
@property(nonatomic, strong) NSDictionary* diagnostic;
@property(nonatomic, assign) NSInteger stage;
@property(nonatomic, assign) NSInteger cycles;
@property(nonatomic, assign) CFTimeInterval deadline;
@property(nonatomic, assign) uint64_t firstSession;
@property(nonatomic, assign) uint64_t secondSession;
@property(nonatomic, assign) NSUInteger stoppedEvents;
@property(nonatomic, assign) ProbeAutomaticFn automatic;
@property(nonatomic, assign) ProbeEmitFn emit;
@property(nonatomic, assign) ProbeSessionFn session;
@property(nonatomic, assign) ProbeCountFn starts;
@property(nonatomic, assign) ProbeCountFn stops;
@property(nonatomic, assign) ProbeCountFn initializes;
@property(nonatomic, assign) ProbeCountFn hostAttached;
@end

static void Require(BOOL condition, const char* message) {
  if (!condition) throw std::runtime_error(message);
}
static NSUInteger EndedEvents() {
  NSUInteger count = 0;
  for (NSDictionary* event in channelEvents)
    if ([event[@"method"] isEqual:@"sessionEnded"]) count++;
  return count;
}
static NSUInteger EndedForTransaction(NSInteger transaction) {
  NSUInteger count = 0;
  for (NSDictionary* event in channelEvents)
    if ([event[@"method"] isEqual:@"sessionEnded"] && [event[@"arguments"][@"transaction"] integerValue] == transaction) count++;
  return count;
}

@implementation ProbeRunner
- (NSDictionary*)call:(NSString*)method arguments:(NSDictionary*)arguments {
  __block NSDictionary* response = nil;
  FlutterMethodCall* call = [FlutterMethodCall new];
  call.method = method; call.arguments = arguments ?: @{};
  [self.registrar.delegate handleMethodCall:call result:^(id value) { if ([value isKindOfClass:NSDictionary.class]) response = value; }];
  return response;
}
- (void)launch:(NSInteger)transaction {
  self.launchResponse = nil;
  FlutterMethodCall* call = [FlutterMethodCall new];
  call.method = @"launch";
  call.arguments = @{@"transaction": @(transaction), @"coreId": @"probe", @"gamePath": self.gamePath,
      @"gameTitle": @"Lifecycle probe", @"locale": @"en", @"uiText": self.labels};
  __weak ProbeRunner* owner = self;
  [self.registrar.delegate handleMethodCall:call result:^(id value) { owner.launchResponse = value; }];
}
- (void)stop:(NSInteger)transaction {
  self.stopResponse = nil;
  FlutterMethodCall* call = [FlutterMethodCall new];
  call.method = @"stop"; call.arguments = @{@"transaction": @(transaction)};
  __weak ProbeRunner* owner = self;
  [self.registrar.delegate handleMethodCall:call result:^(id value) { owner.stopResponse = value; }];
}
- (void)save:(BOOL)success detail:(NSString*)detail {
  [self.timer invalidate];
  NSString* documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
  NSDictionary* report = @{@"success": @(success), @"detail": detail, @"stage": @(self.stage), @"cycles": @(self.cycles),
    @"testRuntimeOnly": @YES, @"realRetroArchGameplayValidated": @NO, @"sourceSHA": @PROBE_SOURCE_SHA,
    @"starts": @(self.starts ? self.starts() : 0), @"stops": @(self.stops ? self.stops() : 0),
    @"endedEvents": @(EndedEvents()), @"stopResult": self.stopResponse ?: @{},
    @"sessionDiagnostics": [self call:@"diagnostics" arguments:nil] ?: @{},
    @"rootPresentedController": self.registrar.viewController.presentedViewController
        ? NSStringFromClass(self.registrar.viewController.presentedViewController.class) : @"",
    @"firstFrameTimeoutRetainedOwnership": @(self.stage >= 3),
    @"lateCallbackIgnored": @(self.stage >= 6), @"stopAcknowledgementRequired": @(self.stage >= 7)};
  NSData* data = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil];
  [data writeToFile:[documents stringByAppendingPathComponent:@"retroarch-host-probe.json"] atomically:YES];
  NSLog(@"[RetroArchHostProbe] %@", report);
}
- (void)move:(NSInteger)stage seconds:(double)seconds {
  self.stage = stage; self.deadline = CACurrentMediaTime() + seconds;
}
- (void)begin {
  channelEvents = [NSMutableArray array];
  [RetroArchInternalBridgePlugin registerWithRegistrar:self.registrar];
  NSDictionary* diagnostics = [self call:@"diagnostics" arguments:nil];
  NSString* runtime = [NSBundle.mainBundle.privateFrameworksPath stringByAppendingPathComponent:@"libRetroArchCore.dylib"];
  void* handle = dlopen(runtime.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
  Require(handle != nullptr, "fake backend did not load");
  self.automatic = reinterpret_cast<ProbeAutomaticFn>(dlsym(handle, "NeoRetroArchProbeSetAutomatic"));
  self.emit = reinterpret_cast<ProbeEmitFn>(dlsym(handle, "NeoRetroArchProbeEmit"));
  self.session = reinterpret_cast<ProbeSessionFn>(dlsym(handle, "NeoRetroArchProbeSession"));
  self.starts = reinterpret_cast<ProbeCountFn>(dlsym(handle, "NeoRetroArchProbeStarts"));
  self.stops = reinterpret_cast<ProbeCountFn>(dlsym(handle, "NeoRetroArchProbeStops"));
  self.initializes = reinterpret_cast<ProbeCountFn>(dlsym(handle, "NeoRetroArchProbeInitializes"));
  self.hostAttached = reinterpret_cast<ProbeCountFn>(dlsym(handle, "NeoRetroArchProbeHostAttached"));
  Require(self.automatic && self.emit && self.session && self.starts && self.stops && self.initializes && self.hostAttached,
      "fake runtime control symbols missing");
  Require([diagnostics[@"embeddedAvailable"] boolValue] && ![diagnostics[@"sessionOwned"] boolValue],
      "availability probe misreported frontend availability/ownership");
  Require(self.starts() == 0 && self.initializes() == 0 && self.session() == 0,
      "availability probe initialized or started a stray frontend");
  NSDictionary* folders = [self call:@"folders" arguments:nil];
  Require([folders[@"success"] boolValue], "document folder setup failed");
  NSString* overlay = [folders[@"overlayPath"] stringByAppendingPathComponent:@"probe.cfg"];
  [@"user overlay" writeToFile:overlay atomically:YES encoding:NSUTF8StringEncoding error:nil];
  self.gamePath = [folders[@"gamesPath"] stringByAppendingPathComponent:@"probe.nes"];
  [@"test-only content" writeToFile:self.gamePath atomically:YES encoding:NSUTF8StringEncoding error:nil];
  NSDictionary* allLabels = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:
      [NSBundle.mainBundle pathForResource:@"probe-localizations" ofType:@"json"]] options:0 error:nil];
  self.labels = allLabels[@"en"];
  Require(self.labels.count > 0, "probe labels missing");
  self.automatic(0, 0);
  [self launch:1];
  [self move:1 seconds:3];
  __weak ProbeRunner* owner = self;
  self.timer = [NSTimer scheduledTimerWithTimeInterval:0.02 repeats:YES block:^(__unused NSTimer* timer) {
    [owner tick];
  }];
}
- (void)tick {
  @try {
    try {
      double now = CACurrentMediaTime();
      switch (self.stage) {
        case 1: {
          if (self.starts() == 0) { Require(now < self.deadline, "native host did not start backend"); return; }
          self.firstSession = self.session();
          NSString* overlay = [[self call:@"folders" arguments:nil][@"overlayPath"] stringByAppendingPathComponent:@"probe.cfg"];
          Require([[NSString stringWithContentsOfFile:overlay encoding:NSUTF8StringEncoding error:nil] isEqual:@"user overlay"],
              "bundled resources overwrote user-edited overlay");
          Require(self.hostAttached(), "backend host UIView is not attached to Flutter's scene");
          Require(self.launchResponse == nil, "start acceptance falsely counted as rendered first frame");
          Require([[self call:@"launch" arguments:@{@"transaction": @2}][@"errorCode"] isEqual:@"RETROARCH_SESSION_ACTIVE"],
              "duplicate launch was accepted");
          [self move:2 seconds:2];
          return;
        }
        case 2:
          if (!self.launchResponse) { Require(now < self.deadline, "first-frame deadline did not fire"); return; }
          Require([self.launchResponse[@"errorCode"] isEqual:@"RETROARCH_FIRST_FRAME_TIMEOUT"] && [self.launchResponse[@"sessionOwned"] boolValue],
              "first-frame timeout silently released live runtime");
          Require(self.stops() == 1 && self.hostAttached(), "startup timeout failed to request stop while retaining host");
          [self move:3 seconds:0.45];
          return;
        case 3:
          if (now < self.deadline) return;
          Require([[self call:@"diagnostics" arguments:nil][@"sessionOwned"] boolValue] && EndedEvents() == 0 && self.hostAttached(),
              "stop timeout falsely acknowledged termination");
          self.emit(self.firstSession, NEO_RA_RUNNING); // Too late to rescue a cancelled launch.
          Require([self.launchResponse[@"success"] boolValue] == NO && self.hostAttached(), "late first frame resurrected timed-out launch");
          self.emit(self.firstSession, NEO_RA_STOPPED);
          [self move:4 seconds:3];
          return;
        case 4:
          if ([[self call:@"diagnostics" arguments:nil][@"sessionOwned"] boolValue]) {
            Require(now < self.deadline, "STOP acknowledgement failed to release UI"); return;
          }
          Require(EndedForTransaction(1) == 1 && !self.registrar.viewController.presentedViewController,
              "first session ended before dismissing host or emitted duplicate end");
          self.automatic(1, 0);
          [self launch:2];
          [self move:5 seconds:3];
          return;
        case 5: {
          if (!self.launchResponse) { Require(now < self.deadline, "relaunch did not reach first frame"); return; }
          Require([self.launchResponse[@"success"] boolValue], "relaunch failed");
          self.secondSession = self.session();
          UIViewController* host = self.registrar.viewController.presentedViewController;
          Require([host.view.subviews.lastObject isKindOfClass:UIButton.class],
              "touch menu button was covered by asynchronously attached renderer");
          Require(self.secondSession != self.firstSession && self.hostAttached(), "relaunch reused a stale native session boundary");
          self.emit(self.firstSession, NEO_RA_STOPPED);
          Require([[self call:@"diagnostics" arguments:nil][@"sessionOwned"] boolValue] && EndedForTransaction(2) == 0,
              "stale callback released newer runtime");
          Require([[self call:@"showMenu" arguments:@{@"transaction": @2}][@"success"] boolValue], "native game menu failed to open");
          [self move:6 seconds:0.15];
          return;
        }
        case 6:
          if (now < self.deadline) return;
          [self stop:2];
          Require(!self.stopResponse && self.hostAttached(), "stop returned before backend acknowledgement");
          [self move:7 seconds:0.06];
          return;
        case 7:
          if (now < self.deadline) return;
          Require(!self.stopResponse && self.hostAttached(), "paused menu caused premature runtime release");
          self.emit(self.secondSession, NEO_RA_STOPPED);
          [self move:8 seconds:3];
          return;
        case 8:
          if (!self.stopResponse) { Require(now < self.deadline, "acknowledged stop result missing"); return; }
          Require([self.stopResponse[@"success"] boolValue] && ![self.stopResponse[@"sessionOwned"] boolValue] &&
              EndedForTransaction(2) == 1 && !self.registrar.viewController.presentedViewController,
              "stop acknowledged without full host UI release");
          self.automatic(1, 1);
          self.cycles = 0;
          [self launch:3];
          [self move:9 seconds:3];
          return;
        case 9:
          if (!self.launchResponse) { Require(now < self.deadline, "cycle launch stalled"); return; }
          Require([self.launchResponse[@"success"] boolValue] && self.hostAttached(), "cycle first frame failed");
          [self stop:self.cycles + 3];
          [self move:10 seconds:3];
          return;
        case 10:
          if (!self.stopResponse) { Require(now < self.deadline, "synchronous STOP callback stalled"); return; }
          Require([self.stopResponse[@"success"] boolValue] && ![self.stopResponse[@"sessionOwned"] boolValue],
              "synchronous stop lost acknowledged release");
          self.cycles++;
          if (self.cycles >= 10) {
            Require(EndedEvents() == 12 && self.starts() == 12 && self.stops() == 12, "duplicate or missing final lifecycle events");
            [self save:YES detail:@"Real UIKit host: duplicate launch, readiness timeout, late callbacks, stop acknowledgement, menu and 10 relaunch cycles passed."];
            return;
          }
          [self launch:self.cycles + 3];
          [self move:9 seconds:3];
          return;
      }
    } catch (const std::exception& failure) {
      [self save:NO detail:[NSString stringWithUTF8String:failure.what()]];
    }
  } @catch (NSException* exception) {
    [self save:NO detail:exception.reason ?: @"Objective-C exception"];
  }
}
@end

@interface ProbeSceneDelegate : UIResponder <UIWindowSceneDelegate>
@property(nonatomic, strong) UIWindow* window;
@property(nonatomic, strong) ProbeRunner* runner;
@end
@implementation ProbeSceneDelegate
- (void)scene:(UIScene*)scene willConnectToSession:(UISceneSession*)session options:(UISceneConnectionOptions*)options {
  (void)session; (void)options;
  self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene*)scene];
  self.window.rootViewController = [UIViewController new];
  self.window.rootViewController.view.backgroundColor = UIColor.systemBackgroundColor;
  [self.window makeKeyAndVisible];
  self.runner = [ProbeRunner new];
  self.runner.registrar = [ProbeRegistrar new];
  self.runner.registrar.viewController = self.window.rootViewController;
  __block NSUInteger attempts = 0;
  [NSTimer scheduledTimerWithTimeInterval:0.05 repeats:YES block:^(NSTimer* timer) {
    if (scene.activationState != UISceneActivationStateForegroundActive) {
      if (++attempts < 100) return;
      [timer invalidate];
      [self.runner save:NO detail:@"Simulator scene did not enter the foreground."];
      return;
    }
    [timer invalidate];
    try { [self.runner begin]; }
    catch (const std::exception& error) { [self.runner save:NO detail:[NSString stringWithUTF8String:error.what()]]; }
  }];
}
@end
@interface ProbeAppDelegate : UIResponder <UIApplicationDelegate>
@end
@implementation ProbeAppDelegate
@end
int main(int argc, char** argv) {
  @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(ProbeAppDelegate.class)); }
}
