// This test app never ships in NeoStation. It loads a platform-adjusted copy
// of the verified ARM64 donor, preserving the original native instructions.
// Besides ABI sizing, it executes the donor's real Memory/GuestFlat code through
// multiple reset/re-init cycles. This specifically guards the relaunch design:
// normal KartPad shutdown must keep GuestFlat's mapping object alive, then
// Memory::Init must zero/reuse it on the next session.
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <AVFAudio/AVFAudio.h>
#include "aurora-probe-api.h"
#include "soloud.h"
#include "miniaudio.h"
#include "../native/kartpad/core/DonorAudioSession.h"
#include "../native/kartpad/core/DonorSessionReset.h"
#include "../native/kartpad/core/UIKitEventPump.h"
#include <fcntl.h>
#include <array>
#include <atomic>
#include <cstdio>
#include <cmath>
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
static void Progress(NSString* stage) {
  NSLog(@"[KartPadProbe] %@",stage);
  NSString* dir=NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject;
  [[stage stringByAppendingString:@"\n"] writeToFile:[dir stringByAppendingPathComponent:@"probe-progress.log"]
      atomically:YES encoding:NSUTF8StringEncoding error:nil];
}
static void* Required(void* handle,const char* symbol) {
  void* value=dlsym(handle,symbol);
  if (!value) throw std::runtime_error(std::string("missing symbol: ")+symbol);
  return value;
}

// Count samples requested by the real CoreAudio output callback. No manual
// mix() calls or null backend can satisfy this assertion.
static std::atomic<uint64_t> frontendFrames{0};
namespace SoLoud { extern ma_device gDevice; }
class ProbeToneInstance final : public SoLoud::AudioSourceInstance {
 public:
  unsigned int getAudio(float* buffer,unsigned int samples,unsigned int) override {
    for (unsigned int i=0;i<samples;++i) buffer[i]=0.02f*std::sin(phase_++*0.0626893772);
    frontendFrames.fetch_add(samples);
    return samples;
  }
  bool hasEnded() override { return false; }
 private:
  uint64_t phase_=0;
};
class ProbeTone final : public SoLoud::AudioSource {
 public:
  ProbeTone() { mChannels=1; mBaseSamplerate=44100; }
  SoLoud::AudioSourceInstance* createInstance() override { return new ProbeToneInstance; }
};
static void VerifyFrontendAudio(SoLoud::Soloud& frontend) {
  if (frontend.getBackendId()!=SoLoud::Soloud::MINIAUDIO ||
      !SoLoud::gDevice.pContext || SoLoud::gDevice.pContext->backend!=ma_backend_coreaudio)
    throw std::runtime_error("frontend did not open the production audio backend");
  ProbeTone source;
  frontendFrames.store(0);
  const auto voice=frontend.play(source);
  const auto deadline=std::chrono::steady_clock::now()+std::chrono::seconds(4);
  while (frontendFrames.load()<2048 && std::chrono::steady_clock::now()<deadline) {
    [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
  }
  if (frontendFrames.load()<2048 || !frontend.isValidVoiceHandle(voice))
    throw std::runtime_error("frontend CoreAudio callback did not resume playback");
  frontend.stop(voice);
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
      Progress(@"loading donor runtime");
      NSString* path=[NSBundle.mainBundle.privateFrameworksPath stringByAppendingPathComponent:@"KartPadRuntime.framework/KartPadRuntime"];
      void* handle=dlopen(path.fileSystemRepresentation,RTLD_NOW|RTLD_LOCAL);
      if (!handle) { Save(@{@"success":@NO,@"error":@(dlerror())}); return; }
      neokartpad::UIKitEventPump uikitPump;
      if (!uikitPump.bind(handle)) throw std::runtime_error("UIKit main-stack binding refused");
      void* entry=Required(handle,"_Z11RuntimeMainiPPc");
      Dl_info info{};
      if (!dladdr(entry,&info)) throw std::runtime_error("entry unavailable");
      auto* base=static_cast<uint8_t*>(info.dli_fbase);
      auto cpu=reinterpret_cast<void*(*)()>(base+0x5bfb0)();
      if (cpu!=base+0x51a9e68) throw std::runtime_error("context ABI drift");

      neokartpad::DonorSessionReset sessionReset;
      if (!sessionReset.bind(base, handle)) throw std::runtime_error("session reset ABI drift");
      Progress(@"native ABI validated");

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
      Progress(@"GuestFlat reset cycles passed");

      using GuestFn=void(*)(void*);
      auto viInit=reinterpret_cast<GuestFn>(Required(handle,"VIInit_HLE_801b94a4"));
      auto viSetPre=reinterpret_cast<GuestFn>(Required(handle,"VISetPreRetraceCallback_HLE_801b90f4"));
      auto viSetPost=reinterpret_cast<GuestFn>(Required(handle,"VISetPostRetraceCallback_HLE_801b9138"));
      auto fiberInit=reinterpret_cast<void(*)()>(Required(handle,"_ZN5Fiber17GuestFiberManager10InitializeEv"));
      auto fiberStop=reinterpret_cast<void(*)()>(Required(handle,"_ZN5Fiber17GuestFiberManager8ShutdownEv"));
      auto sleep=reinterpret_cast<void(*)(uint32_t,uint64_t)>(Required(handle,"_ZN13OsHleInternal18ScheduleSleepTimerEjy"));
      auto* sleepTable=static_cast<std::vector<neokartpad::DonorSessionReset::SleepTimer>*>(
          Required(handle,"_ZN13OsHleInternal12gSleepTimersE"));
      auto* parks=static_cast<std::unordered_set<uint32_t>*>(
          Required(handle,"_ZN13OsHleInternal17gOutstandingParksE"));
      auto sleepPending=[&](uint32_t thread) {
        for (const auto& timer:*sleepTable) if (timer.thread==thread) return true;
        return false;
      };
      auto nandQueue=reinterpret_cast<void(*)(uint32_t,int32_t,uint32_t)>(Required(handle,"_Z20NandQueueIosCallbackjij"));
      auto nandDrain=reinterpret_cast<bool(*)(void*,int)>(Required(handle,"_Z27NandProcessPendingCallbacksP10CpuContexti"));
      auto allocateFd=reinterpret_cast<int32_t(*)(const std::string&,FILE*,int32_t)>(
          Required(handle,"_Z10AllocateFdRKNSt3__112basic_stringIcNS_11char_traitsIcEENS_9allocatorIcEEEEP7__sFILEi"));
      auto setR3=[&](uint32_t value){ std::memcpy(static_cast<uint8_t*>(cpu)+12,&value,4); };
      auto r3=[&](){ uint32_t value; std::memcpy(&value,static_cast<uint8_t*>(cpu)+12,4); return value; };
      init(config);
      fiberInit();
      viInit(cpu);
      setR3(0xdeadbeecu); viSetPre(cpu);
      sleep(0x80010000,1000000000);
      // Reproduce Build 343: fiber/Aurora shutdown + Memory::Reset/Init alone
      // leaves the old VI callback and host timer installed in a fresh guest.
      fiberStop(); reset(); init(config); fiberInit(); viInit(cpu);
      setR3(0); viSetPre(cpu);
      bool reproducedStaleCallback=(r3()==0xdeadbeecu);
      bool reproducedStaleTimer=sleepPending(0x80010000);
      if (!reproducedStaleCallback || !reproducedStaleTimer)
        throw std::runtime_error("failed to reproduce the old second-session state leak");
      fiberStop();
      if (!sessionReset.resetAfterRuntimeReturn()) throw std::runtime_error("initial reset refused");
      reset();
      for (int cycle=0; cycle<20; ++cycle) {
        Progress([NSString stringWithFormat:@"HLE reset cycle %d",cycle]);
        init(config); fiberInit(); viInit(cpu);
        setR3(0); viSetPre(cpu);
        if (r3()!=0 || sleepPending(0x80010000)) throw std::runtime_error("stale guest callback or timer survived reset");
        setR3(0); viSetPost(cpu);
        if (r3()!=0) throw std::runtime_error("stale post-retrace callback survived reset");
        if (nandDrain(cpu,1)) throw std::runtime_error("stale NAND callback survived reset");
        setR3(0xdeadbeecu); viSetPre(cpu);
        setR3(0xdeadbee8u); viSetPost(cpu);
        sleep(0x80010000,1000000000); parks->insert(0x80010000);
        nandQueue(0xdeadbee4u,0,0x80020000);
        FILE* file=tmpfile();
        if (!file) throw std::runtime_error("probe tmpfile failed");
        const int fd=fileno(file);
        allocateFd(std::string("probe file"),file,1);
        // Queued exited-fiber stacks are a separate allocation from s_fibers.
        auto* pending=reinterpret_cast<std::vector<void*>*>(base+0x52061f0);
        void* deferred=::operator new(0x428);
        std::memset(deferred,0,0x428);
        void* stack=::operator new[](4096);
        std::memcpy(static_cast<uint8_t*>(deferred)+0x420,&stack,sizeof(stack));
        pending->push_back(deferred);
        fiberStop();
        if (!sessionReset.resetAfterRuntimeReturn()) throw std::runtime_error("post-runtime reset refused");
        if (fcntl(fd,F_GETFD)!=-1 || errno!=EBADF) throw std::runtime_error("NAND file remained open");
        if (!pending->empty()) throw std::runtime_error("deferred fiber remained allocated");
        reset();
      }

      // Exercise the donor's real SDL/Metal/audio create/destroy paths too.
      // No disc data is needed to initialize a window, device and render frame.
      auto auroraInit=reinterpret_cast<AuroraInfo(*)(int,char**,const AuroraConfig*)>(Required(handle,"aurora_initialize"));
      auto auroraStop=reinterpret_cast<void(*)()>(Required(handle,"aurora_shutdown"));
      auto beginFrame=reinterpret_cast<bool(*)()>(Required(handle,"aurora_begin_frame"));
      auto endFrame=reinterpret_cast<void(*)()>(Required(handle,"aurora_end_frame"));
      auto waitFrame=reinterpret_cast<void(*)()>(Required(handle,"aurora_wait_for_frame_worker"));
      auto audioInstance=reinterpret_cast<void*(*)()>(Required(handle,"_ZN12AudioBackend8InstanceEv"));
      auto audioInit=reinterpret_cast<bool(*)(void*,uint32_t,uint32_t)>(Required(handle,"_ZN12AudioBackend4InitEjj"));
      auto destroyStream=reinterpret_cast<void(*)(void*)>(Required(handle,"SDL_DestroyAudioStream"));
      auto quitAudio=reinterpret_cast<void(*)(uint32_t)>(Required(handle,"SDL_QuitSubSystem"));
      reinterpret_cast<void(*)()>(Required(handle,"SDL_SetMainReady"))();
      // Match RuntimeMainOnUIKitThread: the timer owns the UIKit thread, so
      // SDL must service UIKit while the renderer acquires/presents drawables.
      reinterpret_cast<void(*)(bool)>(Required(handle,"SDL_SetiOSEventPump"))(true);
      const std::string rendererPath=std::string(NSTemporaryDirectory().UTF8String)+"renderer";
      std::filesystem::create_directories(rendererPath);
      SoLoud::Soloud frontend;
      Progress(@"initial CoreAudio playback");
      if (frontend.init(0,SoLoud::Soloud::MINIAUDIO)!=0) throw std::runtime_error("initial frontend audio startup failed");
      VerifyFrontendAudio(frontend);
      for (int cycle=0; cycle<3; ++cycle) {
        Progress([NSString stringWithFormat:@"renderer/audio cycle %d: initialize",cycle]);
        AuroraConfig config{};
        config.appName="KartPad lifecycle probe";
        config.userPath=rendererPath.c_str(); config.cachePath=rendererPath.c_str();
        config.resourcesPath=NSBundle.mainBundle.resourcePath.UTF8String;
        config.desiredBackend=BACKEND_METAL;
        config.windowWidth=640; config.windowHeight=480;
        const AuroraInfo info=auroraInit(0,nullptr,&config);
        if (info.initializationStatus!=AURORA_INITIALIZATION_SUCCESS)
          throw std::runtime_error(info.initializationError ?: "renderer startup failed");
        if (!audioInit(audioInstance(),32000,2)) throw std::runtime_error("SDL audio startup failed");
        Progress([NSString stringWithFormat:@"renderer/audio cycle %d: render frame",cycle]);
        if (!beginFrame()) throw std::runtime_error("Metal begin-frame failed");
        endFrame();
        // Match VI_HLE_PresentFrame's producer protocol: end submits the
        // worker job; the following begin grants prepareAllowed. Waiting for
        // DONE before that begin would deadlock the test's own producer.
        if (!beginFrame()) throw std::runtime_error("Metal next-frame preparation failed");
        Progress([NSString stringWithFormat:@"renderer/audio cycle %d: drain worker",cycle]);
        waitFrame();
        Progress([NSString stringWithFormat:@"renderer/audio cycle %d: release audio",cycle]);
        {
          void* backend=audioInstance();
          std::lock_guard lock(*static_cast<std::mutex*>(backend));
          neokartpad::ReleaseDonorAudioSession(backend,destroyStream,quitAudio);
        }
        auroraStop();
        Progress([NSString stringWithFormat:@"renderer/audio cycle %d: donor stopped",cycle]);
        if (!sessionReset.resetAfterRuntimeReturn()) throw std::runtime_error("post-renderer reset refused");
        [self.window makeKeyAndVisible];
        // The same native device recreation performed by restoreAfterKartPad.
        frontend.deinit();
        if (frontend.init(0,SoLoud::Soloud::MINIAUDIO)!=0) throw std::runtime_error("frontend audio recreation failed");
        NSError* audioError=nil;
        [AVAudioSession.sharedInstance setCategory:AVAudioSessionCategoryAmbient
            mode:AVAudioSessionModeDefault options:AVAudioSessionCategoryOptionMixWithOthers error:&audioError];
        if (audioError || ![AVAudioSession.sharedInstance setActive:YES error:&audioError])
          throw std::runtime_error("host audio session recovery failed");
        VerifyFrontendAudio(frontend);
        Progress([NSString stringWithFormat:@"renderer/audio cycle %d: CoreAudio playback restored",cycle]);
      }
      frontend.deinit();
      if (!uikitPump.counts || !uikitPump.counts[1])
        throw std::runtime_error("UIKit main-stack pump was not exercised");

      Save(@{@"success":@YES,@"nativeRuntimeLoaded":@YES,
             @"uikitStackGuardBound":@YES,@"uikitHostPumps":@(uikitPump.counts[1]),
             @"reproducedStaleCallback":@(reproducedStaleCallback),
             @"reproducedStaleTimer":@(reproducedStaleTimer),@"hleResetCycles":@20,@"rendererAudioCycles":@3,
             @"frontendAudioCycles":@3,@"frontendAudioPackage":@"flutter_soloud 4.0.12",
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
