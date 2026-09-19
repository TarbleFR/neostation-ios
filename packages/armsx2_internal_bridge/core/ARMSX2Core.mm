// SPDX-License-Identifier: GPL-3.0-or-later
// NeoStation host adapter for ARMSX2 8b5fad23dc. No application/scene delegate,
// URL, shortcut, VPN, interpreter fallback or detached VM worker is used.
#define SDL_MAIN_HANDLED
#include "ARMSX2CoreABI.h"
#include "IOS/IOSRuntime.h"
#import "IOS/ARMSX2GameView.h"
#import "ARMSX2Bridge.h"
#include "common/Darwin/DarwinMisc.h"
#include "common/Error.h"
#include "common/FileSystem.h"
#include "common/Path.h"
#include "pcsx2/Host.h"
#include "pcsx2/Config.h"
#include "pcsx2/Memory.h"
#include "pcsx2/VMManager.h"
#include "pcsx2/CDVD/CDVDcommon.h"
#include "pcsx2/ps2/BiosTools.h"
#include "pcsx2/vtlb.h"
#include <SDL3/SDL.h>
#include <SDL3/SDL_main.h>
#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstring>
#include <exception>
#include <stdexcept>
#include <vector>
#include <pthread.h>
#include <mutex>
#include <string>
#include <thread>
#include <condition_variable>
#include <signal.h>
#include <setjmp.h>
#include <sys/stat.h>

#ifndef NEO_ARMSX2_SOURCE_REVISION
#error The exact ARMSX2 source revision must be supplied by the build.
#endif

namespace {
enum class Phase { Empty, Preparing, Prepared, Booting, Running, Stopping, Exited };
struct Runtime {
  std::mutex mutex;
  std::condition_variable changed;
  pthread_t worker = {};
  bool worker_owned = false; // Joined before retry; never detached.
  Phase phase = Phase::Empty;
  bool stop = false;
  bool boot_requested = false;
  bool initialized = false;
  std::string failure, data, resources, bios_directory, bios_name, game;
  uint32_t kind = 0;
  uint64_t transaction = 0;
  NeoARMSX2Event event = nullptr;
  void* context = nullptr;
  struct sigaction old_bus = {}, old_segv = {};
  bool signal_snapshot = false;
};
// Intentionally process-lifetime storage. dyld/ObjC frameworks must not be
// unloaded while UIKit/runtime callbacks may still refer to their classes.
Runtime& runtime() { static Runtime* value = new Runtime; return *value; }

int error_out(const std::string& message, char* output, size_t capacity) {
  if (output && capacity) {
    const size_t size = std::min(capacity - 1, message.size());
    memcpy(output, message.data(), size); output[size] = 0;
  }
  return 0;
}
void event(const char* name, const std::string& message = {}) {
  auto& r = runtime();
  if (r.event) r.event(r.context, r.transaction, name, message.c_str());
}
bool stopped() { auto& r=runtime(); std::lock_guard lock(r.mutex); return r.stop; }
bool jit_busy() { return s_vmThreadActive.load(std::memory_order_acquire); }
void fail(const std::string& message) {
  auto& r = runtime();
  { std::lock_guard lock(r.mutex); r.failure = message; r.stop = true; }
  r.changed.notify_all();
  event("failed", message);
}
void folder(std::string& slot, const std::string& root, const char* name) {
  slot = Path::Combine(root, name);
  if (!FileSystem::DirectoryExists(slot.c_str()) && !FileSystem::CreateDirectoryPath(slot.c_str(), false))
    throw std::runtime_error("Cannot create ARMSX2 data directory: " + slot);
}
void initialize_settings() {
  auto& r=runtime();
  EmuFolders::DataRoot = r.data;
  EmuFolders::AppRoot = r.resources;
  EmuFolders::Resources = r.resources;
  folder(EmuFolders::Settings,r.data,"inis");
  folder(EmuFolders::Logs,r.data,"logs");
  folder(EmuFolders::Savestates,r.data,"savestates");
  folder(EmuFolders::MemoryCards,r.data,"memcards");
  folder(EmuFolders::Snapshots,r.data,"snaps");
  folder(EmuFolders::Cheats,r.data,"cheats");
  folder(EmuFolders::Patches,r.data,"patches");
  folder(EmuFolders::Cache,r.data,"cache");
  folder(EmuFolders::Covers,r.data,"covers");
  folder(EmuFolders::GameSettings,r.data,"gamesettings");
  folder(EmuFolders::Textures,r.data,"textures");
  folder(EmuFolders::InputProfiles,r.data,"inputprofiles");
  folder(EmuFolders::UserResources,r.data,"resources");
  std::string bios_state; folder(bios_state,r.data,"bios-state");
  EmuFolders::Bios = r.bios_directory; // Read-only external scope belongs to host.

  s_settings_interface = new INISettingsInterface(Path::Combine(EmuFolders::Settings,"PCSX2.ini"));
  s_settings_interface->Load();
  s_secrets_settings_interface = new INISettingsInterface(Path::Combine(EmuFolders::Settings,"secrets.ini"));
  s_secrets_settings_interface->Load();
  Host::Internal::SetBaseSettingsLayer(s_settings_interface);
  Host::Internal::SetSecretsSettingsLayer(s_secrets_settings_interface);
  g_p44_settings_interface = s_settings_interface;
  auto& si=*s_settings_interface;
  si.SetStringValue("Folders","Bios",r.bios_directory.c_str());
  si.SetStringValue("Folders","MemoryCards",EmuFolders::MemoryCards.c_str());
  si.SetStringValue("Folders","Savestates",EmuFolders::Savestates.c_str());
  si.SetStringValue("SPU2/Output","Backend","SDL");
  si.SetIntValue("EmuCore/GS","Renderer",static_cast<int>(GSRendererType::Metal));
  si.SetBoolValue("Achievements","Enabled",false);
  si.SetBoolValue("PINE","Enabled",false);
  si.SetBoolValue("UI","EnableDiscordPresence",false);
  si.SetStringValue("ARMSX2iOS/JIT","ScriptProtocol","universal");
  ARMSX2EnsureIOSSpeedhackDefaults(&si,"neostation");
  ARMSX2RepairIOSARM64JITSettings(&si,"neostation");
  ARMSX2ApplyIOSMultitapConfig("neostation");
  ARMSX2SanitizeFrameLimiterConfig("neostation");
  DarwinMisc::iPSX2_FORCE_EE_INTERP = 0;
  setenv("ARMSX2_JIT_PROTOCOL","universal",1);

  std::vector<std::string> candidates;
  if (!r.bios_name.empty()) candidates.push_back(r.bios_name);
  else {
    @autoreleasepool {
      NSString* directory=[NSString stringWithUTF8String:r.bios_directory.c_str()];
      NSArray<NSString*>* files=[[NSFileManager defaultManager] contentsOfDirectoryAtPath:directory error:nil];
      for (NSString* file in [files sortedArrayUsingSelector:@selector(compare:)])
        candidates.emplace_back(file.UTF8String);
    }
  }
  bool found=false;
  for (const auto& name:candidates) {
    if (name.empty() || name.find('/')!=std::string::npos) continue;
    u32 version=0,region=0; std::string description,zone;
    const std::string path=Path::Combine(r.bios_directory,name);
    if (IsBIOS(path.c_str(),version,description,region,zone)) {
      r.bios_name=name; si.SetStringValue("Filenames","BIOS",name.c_str());
      EmuConfig.BaseFilenames.Bios=name; found=true; break;
    }
  }
  if (!found) throw std::runtime_error("No valid PS2 BIOS in the selected bios directory.");
  si.Save();
  VMManager::Internal::LoadStartupSettings();
  EmuFolders::Bios=r.bios_directory;
  EmuConfig.BaseFilenames.Bios=r.bios_name;
  EmuConfig.GS.Renderer=GSRendererType::Metal;
  ARMSX2ConfigureImGuiFonts("neostation");
  DarwinMisc::SetJITActivityQuery(&jit_busy);
}

void vm_worker() {
  auto& r=runtime();
  s_cpuThreadId=std::this_thread::get_id();
  { std::lock_guard lock(s_vmMutex); s_vmThreadCreated=true; }
  bool cpu_initialized=false;
  @autoreleasepool {
    try {
      initialize_settings();
      if (stopped()) throw std::runtime_error("ARMSX2 preparation cancelled.");
      if (!DarwinMisc::IsJITAvailable()) throw std::runtime_error("ARMSX2 JIT is unavailable; interpreter fallback is disabled.");
      // SysMemory installs its page-fault handlers. Restore the previous engine's
      // handlers only after every ARMSX2 CPU/GS worker has terminated.
      r.signal_snapshot=(sigaction(SIGBUS,nullptr,&r.old_bus)==0 && sigaction(SIGSEGV,nullptr,&r.old_segv)==0);
      cpu_initialized=VMManager::Internal::CPUThreadInitialize();
      if (!cpu_initialized) throw std::runtime_error("ARMSX2 CPUThreadInitialize failed.");
      if (DarwinMisc::iPSX2_FORCE_EE_INTERP || !SysMemory::HasCodeMemory() ||
          DarwinMisc::g_code_rw_base==0 || DarwinMisc::g_code_rw_size==0)
        throw std::runtime_error("ARMSX2 did not allocate executable JIT memory.");
      {
        std::unique_lock lock(r.mutex);
        r.initialized=true;
        if (!r.stop) r.phase=Phase::Prepared;
        r.changed.notify_all();
        r.changed.wait(lock,[&]{return r.stop || r.boot_requested;});
        if (r.stop) throw std::runtime_error("ARMSX2 launch cancelled before boot.");
        r.phase=Phase::Booting;
      }
      s_vmThreadActive.store(true,std::memory_order_release);
      DarwinMisc::WaitForJITValidation();
      VMBootParameters parameters;
      parameters.fast_boot=true;
      parameters.disable_achievements_hardcore_mode=true;
      if (r.kind==NEO_ARMSX2_BOOT_ELF) {
        parameters.elf_override=r.game;
        parameters.source_type=CDVD_SourceType::NoDisc;
      } else {
        parameters.filename=r.game;
        parameters.source_type=CDVD_SourceType::Iso;
      }
      if (vtlb_FastmemAreaUnavailable()) EmuConfig.Cpu.Recompiler.EnableFastmem=false;
      Error boot_error;
      if (VMManager::Initialize(parameters,&boot_error)!=VMBootResult::StartupSuccess)
        throw std::runtime_error("ARMSX2 boot failed: "+boot_error.GetDescription());
      if (stopped()) throw std::runtime_error("ARMSX2 launch cancelled during boot.");
      VMManager::SetState(VMState::Running);
      if (VMManager::GetState()!=VMState::Running) throw std::runtime_error("ARMSX2 did not enter Running.");
      { std::lock_guard lock(r.mutex); r.phase=Phase::Running; }
      r.changed.notify_all();
      event("running",r.game);
      while (!s_requestVMStop.load(std::memory_order_acquire) && !stopped()) {
        ARMSX2DrainCPUThreadTasks();
        const VMState state=VMManager::GetState();
        if (state==VMState::Running) VMManager::Execute();
        else if (state==VMState::Stopping || state==VMState::Shutdown) break;
        else {
          std::unique_lock lock(s_vmMutex);
          s_vmCV.wait(lock,[]{
            if (s_requestVMStop.load()) return true;
            std::lock_guard tasks(s_cpuTaskMutex); return !s_cpuTasks.empty();
          });
        }
      }
    } catch (const std::exception& e) { fail(e.what()); }
    catch (...) { fail("Unknown ARMSX2 native exception."); }
    if (VMManager::HasValidVM()) VMManager::Shutdown(false);
    s_vmThreadActive.store(false,std::memory_order_release);
    DarwinMisc::WaitForJITValidation();
    if (cpu_initialized) VMManager::Internal::CPUThreadShutdown();
    else SysMemory::Release(); // Allocation failure must not retain a half-arena.
    if (r.signal_snapshot) {
      sigaction(SIGBUS,&r.old_bus,nullptr); sigaction(SIGSEGV,&r.old_segv,nullptr);
      r.signal_snapshot=false;
    }
    Host::Internal::SetBaseSettingsLayer(nullptr);
    Host::Internal::SetSecretsSettingsLayer(nullptr);
    delete s_settings_interface; s_settings_interface=nullptr;
    delete s_secrets_settings_interface; s_secrets_settings_interface=nullptr;
    g_p44_settings_interface=nullptr;
    { std::lock_guard lock(s_vmMutex); s_vmThreadCreated=false; }
    // Complete abandoned CPU tasks so callers cannot remain blocked on teardown.
    { std::lock_guard lock(s_cpuTaskMutex);
      for (auto& task:s_cpuTasks) {
        { std::lock_guard t(task->mutex); task->complete=true; }
        task->cv.notify_all();
      }
      s_cpuTasks.clear();
    }
    { std::lock_guard lock(r.mutex); r.initialized=false; r.phase=Phase::Exited; }
    r.changed.notify_all(); s_vmCV.notify_all(); event("stopped");
  }
}

void* create_view(char* error,size_t capacity) {
  if (![NSThread isMainThread]) { error_out("create_render_view must run on main.",error,capacity); return nullptr; }
  SDL_SetMainReady();
  if (!SDL_InitSubSystem(SDL_INIT_AUDIO|SDL_INIT_GAMEPAD|SDL_INIT_EVENTS)) {
    error_out(std::string("SDL initialization failed: ")+SDL_GetError(),error,capacity); return nullptr;
  }
  // Deliberately do not install the standalone app's persistent GCController
  // dpad handlers: they would steal handlers from NeoStation/other cores.
  [ARMSX2Bridge prepareGameRenderViewForCurrentRenderer];
  return (void*)g_gameRenderView;
}
void release_view() {
  if (![NSThread isMainThread]) return;
  auto& r=runtime();
  { std::lock_guard lock(r.mutex); if(r.phase!=Phase::Empty) return; }
  for(auto& pad:s_gamepads) { if(pad) SDL_CloseGamepad(pad); pad=nullptr; }
  SDL_QuitSubSystem(SDL_INIT_GAMEPAD|SDL_INIT_AUDIO|SDL_INIT_EVENTS);
  [g_gameRenderView removeFromSuperview]; [g_gameRenderView release]; g_gameRenderView=nil;
  memset(g_touchPadState,0,sizeof(g_touchPadState));
}
int prepare(const NeoARMSX2Configuration* config,uint32_t timeout,char* error,size_t capacity) {
  if (!config || config->size<sizeof(*config) || !config->transaction ||
      !config->data_directory || !config->resource_directory || !config->bios_directory ||
      config->data_directory[0]!='/' || config->resource_directory[0]!='/' || config->bios_directory[0]!='/')
    return error_out("Invalid ARMSX2 configuration.",error,capacity);
  auto& r=runtime(); std::unique_lock lock(r.mutex);
  if(r.phase!=Phase::Empty || r.worker_owned) return error_out("ARMSX2 still owns a transaction.",error,capacity);
  r.stop=false; r.boot_requested=false; r.failure.clear(); r.game.clear(); r.kind=0;
  r.data=config->data_directory; r.resources=config->resource_directory;
  r.bios_directory=config->bios_directory; r.bios_name=config->bios_filename?config->bios_filename:"";
  r.transaction=config->transaction; r.event=config->event; r.context=config->context;
  r.phase=Phase::Preparing; s_requestVMStop.store(false);
  pthread_attr_t attributes;
  pthread_attr_init(&attributes);
  const int stack_error=pthread_attr_setstacksize(&attributes,VMManager::EMU_THREAD_STACK_SIZE);
  const int start_error=stack_error ? stack_error : pthread_create(&r.worker,&attributes,
      +[](void*)->void* { vm_worker(); return nullptr; },nullptr);
  pthread_attr_destroy(&attributes);
  if(start_error) { r.phase=Phase::Empty; r.context=nullptr; r.event=nullptr;
    return error_out("Cannot start owned ARMSX2 CPU thread: "+std::to_string(start_error),error,capacity); }
  r.worker_owned=true;
  if (!r.changed.wait_for(lock,std::chrono::milliseconds(timeout),[&]{return r.phase==Phase::Prepared||r.phase==Phase::Exited||!r.failure.empty();})) {
    r.stop=true; r.changed.notify_all();
    return error_out("ARMSX2 memory preparation timed out; cleanup is required before retry.",error,capacity);
  }
  if(r.phase!=Phase::Prepared || !r.failure.empty()) return error_out(r.failure.empty()?"ARMSX2 preparation cancelled.":r.failure,error,capacity);
  return 1;
}
#if defined(__arm64__)
__attribute__((naked, noinline)) static void jit_detach_breakpoint() {
  __asm__("mov x16, #0\n" "brk #0xf00d\n" "ret");
}
#else
static void jit_detach_breakpoint() {}
#endif
int request_jit_detach(char* error,size_t capacity) {
  auto& r=runtime();
  {
    std::lock_guard lock(r.mutex);
    if(r.phase!=Phase::Prepared || !r.initialized || r.stop)
      return error_out("ARMSX2 cannot detach JIT outside Prepared state.",error,capacity);
  }
#if TARGET_OS_IPHONE && !TARGET_OS_SIMULATOR && defined(__arm64__)
  if (DarwinMisc::GetJitMode() == DarwinMisc::JitMode::Legacy)
    return 1;
  // If the debugger disappeared unexpectedly, catch the local SIGTRAP instead
  // of terminating NeoStation. A real helper advances PC and detaches, so this
  // handler is never invoked on the successful path.
  static thread_local sigjmp_buf detach_context;
  static thread_local volatile sig_atomic_t detach_trapped=0;
  struct sigaction old_action={}, action={};
  action.sa_handler=+[](int){ detach_trapped=1; siglongjmp(detach_context,1); };
  sigemptyset(&action.sa_mask);
  if(sigaction(SIGTRAP,&action,&old_action)!=0)
    return error_out("ARMSX2 could not install detach safety handler.",error,capacity);
  detach_trapped=0;
  if(sigsetjmp(detach_context,1)==0) jit_detach_breakpoint();
  sigaction(SIGTRAP,&old_action,nullptr);
  if(detach_trapped)
    return error_out("ARMSX2 debugger detached before the explicit detach handshake.",error,capacity);
#endif
  return 1;
}
int validate_jit(char* error,size_t capacity) {
  auto& r=runtime(); std::lock_guard lock(r.mutex);
  if(r.phase!=Phase::Prepared || !r.initialized || r.stop ||
      !SysMemory::HasCodeMemory() || !DarwinMisc::g_code_rw_base || !DarwinMisc::g_code_rw_size ||
      DarwinMisc::iPSX2_FORCE_EE_INTERP || !DarwinMisc::ValidateJITAlive())
    return error_out("ARMSX2 post-detach JIT canary failed.",error,capacity);
  return 1;
}
int boot(const char* path,uint32_t kind,uint32_t timeout,char* error,size_t capacity) {
  if(!path || path[0]!='/' || !FileSystem::FileExists(path) ||
     (kind!=NEO_ARMSX2_BOOT_DISC && kind!=NEO_ARMSX2_BOOT_ELF))
    return error_out("ARMSX2 requires an existing absolute ISO/CHD/disc or ELF path.",error,capacity);
  auto& r=runtime(); std::unique_lock lock(r.mutex);
  if(r.phase!=Phase::Prepared || r.stop || r.boot_requested) return error_out("ARMSX2 is not ready for exactly one boot.",error,capacity);
  r.game=path; r.kind=kind; r.boot_requested=true; r.changed.notify_all();
  if(!r.changed.wait_for(lock,std::chrono::milliseconds(timeout),[&]{return r.phase==Phase::Running||r.phase==Phase::Exited||!r.failure.empty();})) {
    r.stop=true; s_requestVMStop.store(true); r.changed.notify_all(); s_vmCV.notify_all();
    return error_out("ARMSX2 boot timed out.",error,capacity);
  }
  return r.phase==Phase::Running && r.failure.empty()?1:error_out(r.failure.empty()?"ARMSX2 boot cancelled.":r.failure,error,capacity);
}
void request_stop() {
  auto& r=runtime(); { std::lock_guard lock(r.mutex); r.stop=true; }
  s_requestVMStop.store(true); r.changed.notify_all(); s_vmCV.notify_all();
}
int shutdown(uint32_t timeout,char* error,size_t capacity) {
  auto& r=runtime(); request_stop(); std::unique_lock lock(r.mutex);
  if(r.phase==Phase::Empty) return 1;
  if(!r.changed.wait_for(lock,std::chrono::milliseconds(timeout),[&]{return r.phase==Phase::Exited;}))
    return error_out("ARMSX2 cleanup pending: the old worker must terminate before another launch.",error,capacity);
  lock.unlock(); if(r.worker_owned) pthread_join(r.worker,nullptr); lock.lock();
  r.worker_owned=false;
  r.phase=Phase::Empty; r.initialized=false; r.context=nullptr; r.event=nullptr;
  r.transaction=0; r.failure.clear(); r.stop=false; r.boot_requested=false;
  return 1;
}
void paused(int value) {
  if(!s_vmThreadActive.load()) return;
  Host::RunOnCPUThread([value]{if(VMManager::HasValidVM()) VMManager::SetState(value?VMState::Paused:VMState::Running);},false);
  s_vmCV.notify_all();
}
void button(uint32_t index,int value) {
  if(index>=16 || !s_vmThreadActive.load()) return;
  Host::RunOnCPUThread([index,value]{[ARMSX2Bridge setPadButton:(ARMSX2PadButton)index pressed:value!=0];},false);
  s_vmCV.notify_all();
}
void sticks(float lx,float ly,float rx,float ry) {
  if(!s_vmThreadActive.load() || !std::isfinite(lx)||!std::isfinite(ly)||!std::isfinite(rx)||!std::isfinite(ry))return;
  Host::RunOnCPUThread([=]{[ARMSX2Bridge setLeftStickX:std::clamp(lx,-1.f,1.f) Y:std::clamp(ly,-1.f,1.f)];
    [ARMSX2Bridge setRightStickX:std::clamp(rx,-1.f,1.f) Y:std::clamp(ry,-1.f,1.f)];},false);
  s_vmCV.notify_all();
}
const NeoARMSX2API api={sizeof(NeoARMSX2API),NEO_ARMSX2_ABI_VERSION,NEO_ARMSX2_SOURCE_REVISION,
  create_view,release_view,prepare,request_jit_detach,validate_jit,boot,request_stop,shutdown,paused,button,sticks};
}
extern "C" bool ARMSX2_IsIdleVMPrewarmResolved() { return false; } // No autonomous prewarm in NeoStation.
extern "C" const NeoARMSX2API* NeoARMSX2_GetAPI(uint32_t version) {
  return version==NEO_ARMSX2_ABI_VERSION?&api:nullptr;
}
