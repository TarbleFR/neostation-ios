// This test app never ships in NeoStation. It loads a platform-adjusted copy
// of the verified ARM64 donor, preserving the original native instructions.
// Besides ABI sizing, it executes the donor's real Memory/GuestFlat code through
// multiple reset/re-init cycles. This specifically guards the relaunch design:
// normal KartPad shutdown must keep GuestFlat's mapping object alive, then
// Memory::Init must zero/reuse it on the next session.
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
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>

struct RuntimeRegionConfig {
  std::string name;
  uint32_t baseAddress = 0;
  size_t sizeBytes = 0;
};
struct RuntimeMemoryConfig {
  std::vector<RuntimeRegionConfig> regions;
};

static void Save(NSDictionary* report) {
  NSString* dir=NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject;
  NSData* data=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil];
  [data writeToFile:[dir stringByAppendingPathComponent:@"probe.json"] atomically:YES];
}
static void* Required(void* handle,const char* symbol) {
  void* value=dlsym(handle,symbol);
  if (!value) throw std::runtime_error(std::string("missing symbol: ")+symbol);
  return value;
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
    try {
      NSString* path=[NSBundle.mainBundle.privateFrameworksPath stringByAppendingPathComponent:@"KartPadRuntime.framework/KartPadRuntime"];
      void* handle=dlopen(path.fileSystemRepresentation,RTLD_NOW|RTLD_LOCAL);
      if (!handle) { Save(@{@"success":@NO,@"error":@(dlerror())}); return; }
      void* entry=Required(handle,"_Z11RuntimeMainiPPc");
      Dl_info info{};
      if (!dladdr(entry,&info)) throw std::runtime_error("entry unavailable");
      auto* base=static_cast<uint8_t*>(info.dli_fbase);
      auto cpu=reinterpret_cast<void*(*)()>(base+0x5bfb0)();
      if (cpu!=base+0x51a9e68) throw std::runtime_error("context ABI drift");

      using DefaultsFn=RuntimeMemoryConfig(*)();
      using InitFn=void(*)(const RuntimeMemoryConfig&);
      using ResetFn=void(*)();
      using GetPointerFn=uint8_t*(*)(uint32_t,size_t);
      auto defaults=reinterpret_cast<DefaultsFn>(
          Required(handle,"_ZN6Memory6Config11WiiDefaultsEv"));
      auto init=reinterpret_cast<InitFn>(
          Required(handle,"_ZN6Memory4InitERKNS_6ConfigE"));
      auto reset=reinterpret_cast<ResetFn>(
          Required(handle,"_ZN6Memory5ResetEv"));
      auto getPointer=reinterpret_cast<GetPointerFn>(
          Required(handle,"_ZN6Memory10GetPointerEjm"));
      auto** flatBase=reinterpret_cast<uint8_t**>(
          Required(handle,"_ZN9GuestFlat14gFlatGuestBaseE"));

      using SelectProfileFn=void(*)(const char*);
      using FinalizeProfileFn=void(*)();
      auto selectProfile=reinterpret_cast<SelectProfileFn>(
          Required(handle,"_ZN26TranslatedFunctionRegistry13SelectProfileEPKc"));
      auto finalizeProfile=reinterpret_cast<FinalizeProfileFn>(
          Required(handle,"_ZN26TranslatedFunctionRegistry8FinalizeEv"));

      // Reproduce RuntimeMain's registry sequence repeatedly. The stock donor
      // throws on the second SelectProfile after Finalize; NeoStation's checked
      // donor patch must make that exact same-profile call idempotent.
      for (int cycle=0; cycle<4; ++cycle) {
        selectProfile("base");
        finalizeProfile();
      }

      RuntimeMemoryConfig config=defaults();
      uintptr_t firstFlat=0;
      bool reused=true;
      bool zeroed=true;
      for (int cycle=0; cycle<4; ++cycle) {
        init(config);
        if (!*flatBase) throw std::runtime_error("flat guest base unavailable");
        if (cycle==0) firstFlat=reinterpret_cast<uintptr_t>(*flatBase);
        reused &= firstFlat==reinterpret_cast<uintptr_t>(*flatBase);
        uint8_t* mem1=getPointer(0x80000000u,64);
        if (!mem1) throw std::runtime_error("MEM1 pointer unavailable");
        if (cycle>0) {
          for (size_t i=0;i<64;++i) zeroed &= mem1[i]==0;
        }
        std::memset(mem1,0x5a,64);
        reset();
      }
      if (!reused || !zeroed) throw std::runtime_error("GuestFlat restart contract failed");

      Save(@{@"success":@YES,@"nativeRuntimeLoaded":@YES,
             @"cpuOffset":@((uint8_t*)cpu-base),
             @"threadSize":@(sizeof(std::thread)),@"mutexSize":@(sizeof(std::mutex)),
             @"vectorSize":@(sizeof(std::vector<int>)),@"dequeSize":@(sizeof(std::deque<int>)),
             @"mapSize":@(sizeof(std::map<int,int>)),@"hashMapSize":@(sizeof(std::unordered_map<int,int>)),
             @"ofstreamSize":@(sizeof(std::ofstream)),@"optionalThreadSize":@(sizeof(std::optional<std::thread::id>)),
             @"profileFinalizeCycles":@4,
             @"guestFlatCycles":@4,@"guestFlatReused":@(reused),@"guestMemoryZeroed":@(zeroed),
             @"guestFlatBase":@(firstFlat)});
    } catch (const std::exception& e) {
      Save(@{@"success":@NO,@"error":@(e.what())});
    }
  }];
  [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
  return YES;
}
@end
int main(int argc,char** argv) {
  @autoreleasepool { return UIApplicationMain(argc,argv,nil,NSStringFromClass(ProbeDelegate.class)); }
}
