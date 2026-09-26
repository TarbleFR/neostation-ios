// This test app never ships in NeoStation. It loads a platform-adjusted copy
// of the verified ARM64 donor, preserving the original native instructions.
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#include <array>
#include <atomic>
#include <cstdio>
#include <cstring>
#include <deque>
#include <fstream>
#include <filesystem>
#include <map>
#include <mutex>
#include <optional>
#include <thread>
#include <unordered_map>
#include <vector>

static void Save(NSDictionary* report) {
  NSString* dir=NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject;
  NSData* data=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil];
  [data writeToFile:[dir stringByAppendingPathComponent:@"probe.json"] atomically:YES];
}
@interface ProbeDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic,strong) UIWindow* window;
@end
@implementation ProbeDelegate
- (BOOL)application:(UIApplication*)app didFinishLaunchingWithOptions:(NSDictionary*)options {
  self.window=[[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
  self.window.rootViewController=[UIViewController new];
  [self.window makeKeyAndVisible];
  NSTimer* timer=[NSTimer timerWithTimeInterval:0.01 repeats:NO block:^(NSTimer*) {
    @try {
      NSString* path=[NSBundle.mainBundle.privateFrameworksPath stringByAppendingPathComponent:@"KartPadRuntime.framework/KartPadRuntime"];
      void* handle=dlopen(path.fileSystemRepresentation,RTLD_NOW|RTLD_LOCAL);
      if (!handle) { Save(@{@"success":@NO,@"error":@(dlerror())}); return; }
      void* entry=dlsym(handle,"_Z11RuntimeMainiPPc");
      Dl_info info{};
      if (!entry || !dladdr(entry,&info)) { Save(@{@"success":@NO,@"error":@"entry unavailable"}); return; }
      auto* base=static_cast<uint8_t*>(info.dli_fbase);
      auto cpu=reinterpret_cast<void*(*)()>(base+0x5bfb0)();
      if (cpu!=base+0x51a9e68) { Save(@{@"success":@NO,@"error":@"context ABI drift"}); return; }
      Save(@{@"success":@YES,@"nativeRuntimeLoaded":@YES,
             @"cpuOffset":@((uint8_t*)cpu-base),
             @"threadSize":@(sizeof(std::thread)),@"mutexSize":@(sizeof(std::mutex)),
             @"vectorSize":@(sizeof(std::vector<int>)),@"dequeSize":@(sizeof(std::deque<int>)),
             @"mapSize":@(sizeof(std::map<int,int>)),@"hashMapSize":@(sizeof(std::unordered_map<int,int>)),
             @"ofstreamSize":@(sizeof(std::ofstream)),@"optionalThreadSize":@(sizeof(std::optional<std::thread::id>))});
    } @catch(NSException* e) { Save(@{@"success":@NO,@"error":e.description}); }
  }];
  [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
  return YES;
}
@end
int main(int argc,char** argv) {
  @autoreleasepool { return UIApplicationMain(argc,argv,nil,NSStringFromClass(ProbeDelegate.class)); }
}
