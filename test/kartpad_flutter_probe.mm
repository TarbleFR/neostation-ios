// Runs the shipped donor's SDL/Metal window, overlay and teardown under a real
// Flutter engine and UIScene. No game assets or simulated Flutter controller.
#import <Flutter/Flutter.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#include "aurora-probe-api.h"
#include "KartPadHostWindowSelection.h"
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
  UIWindow* _host;
  void* _runtime;
  BOOL _running;
}
+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar {
  ProbePlugin* instance = [ProbePlugin new];
  instance->_registrar = registrar;
  [registrar addMethodCallDelegate:instance channel:[FlutterMethodChannel
      methodChannelWithName:@"probe" binaryMessenger:registrar.messenger]];
  Record(@"registered");
}
- (void)handleMethodCall:(FlutterMethodCall*)call result:(FlutterResult)result {
  Record(call.method, @{@"arguments":call.arguments ?: @{}, @"host":WindowState(_host)});
  if (![call.method isEqualToString:@"cycle"]) { result(WindowState(_host)); return; }
  if (_running) { result([FlutterError errorWithCode:@"double_launch" message:nil details:nil]); return; }
  _host = neokartpad::FindFlutterHostWindow(_registrar.viewController, _host, FlutterViewController.class);
  if (!_host) { result([FlutterError errorWithCode:@"host_missing" message:nil details:nil]); return; }
  _running = YES;
  NeoKartPadScheduleRunLoop(0.001, ^{
    try {
      [self runDonor];
      self->_running = NO;
      Record(@"returned", WindowState(self->_host));
      result(@YES);
    } catch (const std::exception& e) {
      self->_running = NO;
      Record(@"native_failure", @{@"error":@(e.what())});
      result([FlutterError errorWithCode:@"native_failure" message:@(e.what()) details:nil]);
    }
  });
}
- (void)runDonor {
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
  const CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent()+1.0;
  do {
    if (beginFrame()) endFrame();
  } while (CFAbsoluteTimeGetCurrent() < deadline);
  // Aurora's drain waits for EncoderReady, requested by begin_frame. Match
  // the production guest boundary and the native lifecycle regression.
  if (!beginFrame()) throw std::runtime_error("Drain frame preparation failed");
  waitFrame(); uninstall(); stop(); pump(false);
  if (donor != _host) donor.hidden=YES;
  [_host makeKeyAndVisible];
  Record(@"restored", WindowState(_host));
}
@end
