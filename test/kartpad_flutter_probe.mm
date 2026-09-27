// Runs the shipped donor's SDL/Metal window, overlay and teardown under a real
// Flutter engine and UIScene. No game assets or simulated Flutter controller.
#import <Flutter/Flutter.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#include "aurora-probe-api.h"
#include "KartPadHostWindowSelection.h"
#import "KartPadHostWindowAwaiter.h"
#include "SessionRunLoop.h"
#include <stdexcept>
#include <string>

@interface ProbePlugin : NSObject <FlutterPlugin>
@end

static NSMutableArray* events;
static NSString* ReportPath() {
  return [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject
      stringByAppendingPathComponent:@"flutter-probe.json"];
}
static void Record(NSString* stage, NSDictionary* values = @{}) {
  if (!events) events = [NSMutableArray array];
  [events addObject:@{@"time":@(NSDate.date.timeIntervalSince1970), @"stage":stage, @"values":values}];
  NSData* data = [NSJSONSerialization dataWithJSONObject:events options:NSJSONWritingPrettyPrinted error:nil];
  [data writeToFile:ReportPath() atomically:YES];
  NSLog(@"[FlutterDonorProbe] %@ %@", stage, values);
}
static NSDictionary* WindowState(UIWindow* window) {
  return @{@"window":@((uintptr_t)(__bridge void*)window), @"hidden":@(window.hidden),
      @"alpha":@(window.alpha), @"scene":@(window.windowScene != nil),
      @"activation":@(window.windowScene.activationState), @"key":@(window.keyWindow),
      @"root":window.rootViewController ? NSStringFromClass(window.rootViewController.class) : @"nil"};
}
static void* Required(void* handle, const char* symbol) {
  void* value = dlsym(handle, symbol);
  if (!value) throw std::runtime_error(std::string("Missing donor symbol: ") + symbol);
  return value;
}
@implementation ProbePlugin {
  NSObject<FlutterPluginRegistrar>* _registrar;
  FlutterMethodChannel* _channel;
  UIWindow* _host;
  void* _runtime;
  BOOL _running;
  BOOL _closeRequested;
  NSInteger _cycle;
  NeoKartPadHostWindowAwaiter* _waiter;
}
+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar {
  ProbePlugin* instance = [ProbePlugin new];
  instance->_registrar = registrar;
  instance->_channel = [FlutterMethodChannel methodChannelWithName:@"probe"
      binaryMessenger:registrar.messenger];
  [registrar addMethodCallDelegate:instance channel:instance->_channel];
  Record(@"registered");
}
- (void)handleMethodCall:(FlutterMethodCall*)call result:(FlutterResult)result {
  Record(call.method, @{@"arguments":call.arguments ?: @{}, @"host":WindowState(_host)});
  if ([call.method isEqualToString:@"waiter_contract"]) {
    __block BOOL cancelledCompletion=NO;
    NeoKartPadHostWindowAwaiter* cancelled = [[NeoKartPadHostWindowAwaiter alloc]
        initWithSelection:^UIWindow* { return nil; }
        completion:^(UIWindow*) { cancelledCompletion=YES; }];
    [cancelled start];
    [cancelled cancel];
    const CFTimeInterval began=NSProcessInfo.processInfo.systemUptime;
    _waiter=[[NeoKartPadHostWindowAwaiter alloc]
        initWithSelection:^UIWindow* { return nil; }
        completion:^(UIWindow* timedOut) {
      if (timedOut || cancelledCompletion || NSProcessInfo.processInfo.systemUptime-began<2.9) {
        result([FlutterError errorWithCode:@"waiter_contract" message:@"Cancellation/timeout failed" details:nil]);
        return;
      }
      __block BOOL ready=NO;
      self->_waiter=[[NeoKartPadHostWindowAwaiter alloc]
          initWithSelection:^UIWindow* { return ready ? self->_host : nil; }
          completion:^(UIWindow* window) {
        self->_waiter=nil;
        if (window!=self->_host || cancelledCompletion) {
          result([FlutterError errorWithCode:@"waiter_contract" message:@"Late readiness failed" details:nil]);
          return;
        }
        Record(@"waiter_contract_passed");
        result(@YES);
      }];
      [self->_waiter start];
      NeoKartPadScheduleRunLoop(0.1, ^{ ready=YES; });
    }];
    [_waiter start];
    return;
  }
  if ([call.method isEqualToString:@"async_identity"]) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^{
      dispatch_async(dispatch_get_main_queue(), ^{ result(@YES); });
    });
    return;
  }
  if ([call.method isEqualToString:@"success"] || [call.method isEqualToString:@"failure"]) {
    UILabel* label = [[UILabel alloc] initWithFrame:CGRectMake(20,80,350,80)];
    label.text = call.method;
    label.accessibilityIdentifier = call.method;
    [_host addSubview:label];
  }
  if (![call.method isEqualToString:@"cycle"]) { result(WindowState(_host)); return; }
  if (_running) { result([FlutterError errorWithCode:@"double_launch" message:nil details:nil]); return; }
  _running = YES;
  _cycle = [call.arguments[@"cycle"] integerValue];
  Record(@"host_wait", @{@"snapshot":neokartpad::DescribeFlutterHost(_registrar.viewController,_host)});
  __weak ProbePlugin* weakSelf = self;
  _waiter = [[NeoKartPadHostWindowAwaiter alloc] initWithSelection:^UIWindow* {
    ProbePlugin* owner=weakSelf;
    if (!owner) return nil;
    return neokartpad::FindFlutterHostWindow(owner->_registrar.viewController,
        owner->_host, FlutterViewController.class);
  } completion:^(UIWindow* window) {
    ProbePlugin* owner=weakSelf;
    if (!owner) return;
    owner->_waiter=nil;
    if (!window) {
      owner->_running=NO;
      result([FlutterError errorWithCode:@"host_missing" message:nil details:nil]);
      return;
    }
    owner->_host=window;
    Record(@"host_ready",WindowState(window));
    [owner enterDonor:result];
  }];
  [_waiter start];
}
- (void)enterDonor:(FlutterResult)result {
  NeoKartPadScheduleRunLoop(0.001, ^{
    __block BOOL acknowledged = NO;
    try {
      [self runDonor:^(id value) { acknowledged=YES; result(value); }];
      self->_running = NO;
      Record(@"returned", WindowState(self->_host));
      [self->_channel invokeMethod:@"sessionEnded" arguments:@{@"success":@YES}];
    } catch (const std::exception& e) {
      self->_running = NO;
      Record(@"native_failure", @{@"error":@(e.what())});
      if (!acknowledged) {
        result([FlutterError errorWithCode:@"native_failure" message:@(e.what()) details:nil]);
      } else {
        [self->_channel invokeMethod:@"sessionEnded"
            arguments:@{@"success":@NO, @"error":@(e.what())}];
      }
    }
  });
}
- (void)runDonor:(FlutterResult)started {
  if (!_runtime) {
    NSString* path = [NSBundle.mainBundle.privateFrameworksPath
        stringByAppendingPathComponent:@"KartPadRuntime.framework/KartPadRuntime"];
    _runtime = dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
    if (!_runtime) throw std::runtime_error(dlerror());
  }
  auto ready = reinterpret_cast<void(*)()>(Required(_runtime,"SDL_SetMainReady"));
  auto pump = reinterpret_cast<void(*)(bool)>(Required(_runtime,"SDL_SetiOSEventPump"));
  auto init = reinterpret_cast<AuroraInfo(*)(int,char**,const AuroraConfig*)>(Required(_runtime,"aurora_initialize"));
  auto stop = reinterpret_cast<void(*)()>(Required(_runtime,"aurora_shutdown"));
  auto beginFrame = reinterpret_cast<bool(*)()>(Required(_runtime,"aurora_begin_frame"));
  auto endFrame = reinterpret_cast<void(*)()>(Required(_runtime,"aurora_end_frame"));
  auto waitFrame = reinterpret_cast<void(*)()>(Required(_runtime,"aurora_wait_for_frame_worker"));
  auto install = reinterpret_cast<void(*)(void*)>(Required(_runtime,"KartPadMobileRuntimeHostInstall"));
  auto uninstall = reinterpret_cast<void(*)()>(Required(_runtime,"KartPadMobileRuntimeHostUninstall"));
  auto windows = reinterpret_cast<void**(*)(int*)>(Required(_runtime,"SDL_GetWindows"));
  auto freeSDL = reinterpret_cast<void(*)(void*)>(Required(_runtime,"SDL_free"));
  ready(); pump(true);
  const std::string path = NSTemporaryDirectory().UTF8String;
  AuroraConfig config{};
  config.appName="Flutter Donor Probe";
  config.userPath=path.c_str(); config.cachePath=path.c_str();
  config.resourcesPath=NSBundle.mainBundle.resourcePath.UTF8String;
  config.desiredBackend=BACKEND_METAL;
  config.windowWidth=640; config.windowHeight=480;
  Record(@"initializing", WindowState(_host));
  const AuroraInfo info = init(0,nullptr,&config);
  if (info.initializationStatus != AURORA_INITIALIZATION_SUCCESS)
    throw std::runtime_error(info.initializationError ?: "Aurora failed");
  int count=0;
  void** nativeWindows=windows(&count);
  if (count != 1) throw std::runtime_error("Expected one owned SDL window");
  install(nativeWindows[0]); freeSDL(nativeWindows);
  UIWindow* donor=nil;
  for (UIWindow* window in _host.windowScene.windows)
    if (window != _host && !window.hidden && window.keyWindow) donor=window;
  Record(@"running", @{@"host":WindowState(_host), @"donor":WindowState(donor)});
  // Production acknowledges launch while RuntimeMain still owns the nested
  // SDL run loop, then sends a separate sessionEnded event after restoration.
  started(@YES);
  BOOL menuMode = [NSProcessInfo.processInfo.arguments containsObject:@"--menu-probe"];
  _closeRequested=NO;
  UIButton* gear=nil;
  if (menuMode) {
    gear=[UIButton buttonWithType:UIButtonTypeSystem];
    gear.frame=CGRectMake(40,60,200,60);
    [gear setTitle:@"Settings" forState:UIControlStateNormal];
    gear.accessibilityIdentifier=[NSString stringWithFormat:@"probe.settings.%ld",(long)_cycle];
    gear.showsMenuAsPrimaryAction=YES;
    gear.menu=[UIMenu menuWithTitle:@"" children:@[
      [UIAction actionWithTitle:@"Return to NeoStation" image:nil identifier:nil handler:^(__kindof UIAction*) {
        Record(@"menu_exit_requested", WindowState(self->_host));
        self->_closeRequested=YES;
      }]]];
    [donor.rootViewController.view addSubview:gear];
  }
  const CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent()+1.0;
  const CFAbsoluteTime menuDeadline = CFAbsoluteTimeGetCurrent()+60.0;
  do {
    if (beginFrame()) endFrame();
  } while (menuMode ? (!_closeRequested && CFAbsoluteTimeGetCurrent()<menuDeadline)
                    : CFAbsoluteTimeGetCurrent()<deadline);
  if (menuMode && !_closeRequested) throw std::runtime_error("Menu action not received");
  // Aurora's drain waits for EncoderReady, requested by begin_frame. Match
  // the production guest boundary and the native lifecycle regression.
  if (!beginFrame()) throw std::runtime_error("Drain frame preparation failed");
  waitFrame(); uninstall(); stop(); pump(false);
  [gear removeFromSuperview];
  if (donor != _host) donor.hidden=YES;
  [_host makeKeyAndVisible];
  Record(@"restored", WindowState(_host));
}
@end
