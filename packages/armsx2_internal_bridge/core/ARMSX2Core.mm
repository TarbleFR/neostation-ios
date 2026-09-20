// SPDX-License-Identifier: GPL-3.0-or-later
// NeoStation host adapter for ARMSX2 8b5fad23dc. No application/scene delegate,
// URL, shortcut, VPN, interpreter fallback or detached VM worker is used.
#define SDL_MAIN_HANDLED
#include "ARMSX2CoreABI.h"
#include "ARMSX2GraphicsHacks.h"
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
#include "pcsx2/Patch.h"
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
#include <dispatch/dispatch.h>
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
  // SDL is process-lifetime in the embedded host. ARMSX2Core itself is never
  // dlclosed, so tearing down UIKit's SDL event subsystem between sessions can
  // race controller/render callbacks owned by the loaded core.
  bool sdl_initialized = false;
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
  std::string saves_root; folder(saves_root,r.data,"Saves");
  folder(EmuFolders::Savestates,saves_root,"Savestates");
  folder(EmuFolders::MemoryCards,saves_root,"Memory Cards");
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
  // Preserve RetroAchievements across launches. Previous builds forced this
  // off on every prepare, making the native ARMSX2 account/settings unusable.
  if (!si.ContainsValue("Achievements","Enabled"))
    si.SetBoolValue("Achievements","Enabled",false);
  if (!si.ContainsValue("Achievements","ChallengeMode"))
    si.SetBoolValue("Achievements","ChallengeMode",false);
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
      parameters.fast_boot=(r.kind!=NEO_ARMSX2_BOOT_BIOS);
      // Normal game launches must honor the persisted RA mode. This flag is
      // only for one-off boot flows which intentionally suspend Hardcore.
      parameters.disable_achievements_hardcore_mode=false;
      if (r.kind==NEO_ARMSX2_BOOT_BIOS) {
        // The real PS2 browser/system configuration, with no disc inserted.
        // Shutdown(false) persists the BIOS NVRAM through the upstream path.
        parameters.source_type=CDVD_SourceType::NoDisc;
      } else if (r.kind==NEO_ARMSX2_BOOT_ELF) {
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
      while (true) {
        ARMSX2DrainCPUThreadTasks();
        // Transition the VM to Stopping on its owned CPU thread before
        // VMManager::Shutdown. The old loop exited as soon as the stop flag was
        // raised, skipping the normal state transition used by upstream.
        if (s_requestVMStop.load(std::memory_order_acquire) || stopped()) {
          if (VMManager::HasValidVM()) {
            const VMState current=VMManager::GetState();
            if (current!=VMState::Stopping && current!=VMState::Shutdown)
              VMManager::SetState(VMState::Stopping);
          }
          break;
        }
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
    // HasValidVM deliberately excludes Stopping. A stopped execution loop
    // still owns the VM devices until Shutdown closes them and stores Shutdown.
    // CPUThreadShutdown only releases CPU resources; it cannot replace this.
    if (VMManager::HasValidVM() || VMManager::GetState()==VMState::Stopping)
      VMManager::Shutdown(false);
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
  auto& r=runtime();
  bool initialize_sdl=false;
  { std::lock_guard lock(r.mutex); initialize_sdl=!r.sdl_initialized; }
  if (initialize_sdl) {
    SDL_SetMainReady();
    if (!SDL_InitSubSystem(SDL_INIT_AUDIO|SDL_INIT_GAMEPAD|SDL_INIT_EVENTS)) {
      error_out(std::string("SDL initialization failed: ")+SDL_GetError(),error,capacity); return nullptr;
    }
    std::lock_guard lock(r.mutex); r.sdl_initialized=true;
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
  // Do not SDL_QuitSubSystem here. UIKit/GCController event infrastructure is
  // owned for the process lifetime just like this dlopened Objective-C core.
  if (g_gameRenderView) {
    [g_gameRenderView removeFromSuperview];
    [g_gameRenderView release];
    g_gameRenderView=nil;
  }
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
  const bool bios_only=(kind==NEO_ARMSX2_BOOT_BIOS);
  if (bios_only) {
    if (!path || path[0]!=0)
      return error_out("ARMSX2 BIOS boot must not include a game path.",error,capacity);
  } else if(!path || path[0]!='/' || !FileSystem::FileExists(path) ||
      (kind!=NEO_ARMSX2_BOOT_DISC && kind!=NEO_ARMSX2_BOOT_ELF)) {
    return error_out("ARMSX2 requires an existing absolute ISO/CHD/disc or ELF path.",error,capacity);
  }
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
  auto& r=runtime();
  {
    std::lock_guard lock(r.mutex);
    r.stop=true;
    if (r.phase!=Phase::Empty && r.phase!=Phase::Exited)
      r.phase=Phase::Stopping;
  }
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

bool has_running_game() {
  return s_vmThreadActive.load(std::memory_order_acquire) && VMManager::HasValidVM();
}
float get_upscale_multiplier() {
  if(!has_running_game()) return 1.0f;
  const float global=[ARMSX2Bridge getINIFloat:@"EmuCore/GS" key:@"upscale_multiplier" defaultValue:1.0f];
  return [ARMSX2Bridge getPerGameINIFloat:@"EmuCore/GS" key:@"upscale_multiplier" defaultValue:global forISO:nil];
}
uint32_t aspect_index(NSString* value) {
  if([value isEqualToString:@"4:3"]) return 1;
  if([value isEqualToString:@"16:9"]) return 2;
  if([value isEqualToString:@"10:7"]) return 3;
  if([value isEqualToString:@"Stretch"]) return 4;
  return 0;
}
uint32_t get_aspect_ratio() {
  if(!has_running_game()) return 0;
  NSString* global=[ARMSX2Bridge getINIString:@"EmuCore/GS" key:@"AspectRatio" defaultValue:@"Auto 4:3/3:2"];
  NSString* value=[ARMSX2Bridge getPerGameINIString:@"EmuCore/GS" key:@"AspectRatio" defaultValue:global forISO:nil];
  return aspect_index(value);
}
int get_cheats_enabled() {
  if(!has_running_game()) return 0;
  const BOOL global=[ARMSX2Bridge getINIBool:@"EmuCore" key:@"EnableCheats" defaultValue:NO];
  return [ARMSX2Bridge getPerGameINIBool:@"EmuCore" key:@"EnableCheats" defaultValue:global forISO:nil] ? 1 : 0;
}
int set_upscale_multiplier(float value,char* error,size_t capacity) {
  if(!has_running_game()) return error_out("ARMSX2 game settings require a running game.",error,capacity);
  if(!std::isfinite(value) || value<1.0f || value>8.0f)
    return error_out("ARMSX2 internal resolution must be between 1x and 8x.",error,capacity);
  [ARMSX2Bridge setPerGameINIFloat:@"EmuCore/GS" key:@"upscale_multiplier" value:value forISO:nil];
  [ARMSX2Bridge applyGraphicsSettingsNow];
  return 1;
}
int set_aspect_ratio(uint32_t value,char* error,size_t capacity) {
  if(!has_running_game()) return error_out("ARMSX2 game settings require a running game.",error,capacity);
  static NSString* values[] = {@"Auto 4:3/3:2",@"4:3",@"16:9",@"10:7",@"Stretch"};
  if(value>=5) return error_out("Unsupported ARMSX2 aspect ratio.",error,capacity);
  [ARMSX2Bridge setPerGameINIString:@"EmuCore/GS" key:@"AspectRatio" value:values[value] forISO:nil];
  [ARMSX2Bridge applyGraphicsSettingsNow];
  return 1;
}
int set_cheats_enabled(int enabled,char* error,size_t capacity) {
  if(!has_running_game()) return error_out("ARMSX2 cheats require a running game.",error,capacity);
  [ARMSX2Bridge setPerGameINIBool:@"EmuCore" key:@"EnableCheats" value:enabled!=0 forISO:nil];
  [ARMSX2Bridge reloadPatches];
  return 1;
}
int reload_cheats(char* error,size_t capacity) {
  if(!has_running_game()) return error_out("ARMSX2 cheats require a running game.",error,capacity);
  [ARMSX2Bridge reloadPatches];
  return 1;
}

int get_available_patches_json(char* output,size_t capacity) {
  if(!output || capacity<2 || !has_running_game()) return 0;
  __block NSData* encoded=nil;
  Host::RunOnCPUThread([&]{
    @autoreleasepool {
      const std::string serial=VMManager::GetDiscSerial();
      const u32 crc=VMManager::GetDiscCRC();
      if(serial.empty() || crc==0) return;

      u32 unlabelled=0;
      const std::vector<Patch::PatchInfo> patches=
          Patch::GetPatchInfo(serial,crc,false,false,&unlabelled);
      NSString* section=[NSString stringWithUTF8String:Patch::PATCHES_CONFIG_SECTION];
      NSString* enableKey=[NSString stringWithUTF8String:Patch::PATCH_ENABLE_CONFIG_KEY];
      NSString* disableKey=[NSString stringWithUTF8String:Patch::PATCH_DISABLE_CONFIG_KEY];
      NSSet<NSString*>* enabled=[NSSet setWithArray:
          [ARMSX2Bridge patchEnableListForISO:nil section:section key:enableKey]];
      NSSet<NSString*>* disabled=[NSSet setWithArray:
          [ARMSX2Bridge patchEnableListForISO:nil section:section key:disableKey]];

      NSMutableArray* items=[NSMutableArray arrayWithCapacity:patches.size()];
      for(const Patch::PatchInfo& patch:patches) {
        if(patch.name.empty()) continue;
        NSString* name=[NSString stringWithUTF8String:patch.name.c_str()];
        if(!name.length) continue;
        const BOOL toggleable=Patch::IsGloballyToggleablePatch(patch);
        NSInteger state=0;
        if([enabled containsObject:name]) state=1;
        else if(toggleable && ![disabled containsObject:name]) state=-1;
        NSString* description=patch.description.empty() ? @"" :
            [NSString stringWithUTF8String:patch.description.c_str()];
        NSString* author=patch.author.empty() ? @"" :
            [NSString stringWithUTF8String:patch.author.c_str()];
        [items addObject:@{
          @"name":name,
          @"description":description ?: @"",
          @"author":author ?: @"",
          @"value":@(state),
          @"automatic":@(toggleable),
          @"place":@((int)(patch.place.has_value() ? patch.place.value() : Patch::PPT_END_MARKER)),
        }];
      }

      NSString* serialString=[NSString stringWithUTF8String:serial.c_str()] ?: @"";
      NSDictionary* payload=@{
        @"available":@YES,
        @"serial":serialString,
        @"crc":[NSString stringWithFormat:@"%08X",(unsigned int)crc],
        @"unlabelled":@(unlabelled),
        @"items":items,
      };
      encoded=[[NSJSONSerialization dataWithJSONObject:payload options:0 error:nil] retain];
    }
  },true);
  if(!encoded) return 0;
  const BOOL fits=encoded.length+1<=capacity;
  if(fits) { memcpy(output,encoded.bytes,encoded.length); output[encoded.length]=0; }
  [encoded release];
  return fits ? 1 : 0;
}

int set_patch_state(const char* patch_name,int state,char* error,size_t capacity) {
  if(!patch_name || !patch_name[0] || (state < -1 || state > 1))
    return error_out("Unsupported ARMSX2 patch or state.",error,capacity);
  if(!has_running_game())
    return error_out("ARMSX2 patches require a running game.",error,capacity);

  const std::string wanted(patch_name);
  __block BOOL success=NO;
  __block BOOL unsupportedAutomatic=NO;
  Host::RunOnCPUThread([&]{
    @autoreleasepool {
      const std::string serial=VMManager::GetDiscSerial();
      const u32 crc=VMManager::GetDiscCRC();
      if(serial.empty() || crc==0) return;

      u32 ignored=0;
      const std::vector<Patch::PatchInfo> patches=
          Patch::GetPatchInfo(serial,crc,false,false,&ignored);
      const auto found=std::find_if(patches.begin(),patches.end(),
          [&](const Patch::PatchInfo& patch){return patch.name==wanted;});
      if(found==patches.end()) return;

      const BOOL toggleable=Patch::IsGloballyToggleablePatch(*found);
      if(state==-1 && !toggleable) {
        unsupportedAutomatic=YES;
        return;
      }

      NSString* name=[NSString stringWithUTF8String:wanted.c_str()];
      NSString* section=[NSString stringWithUTF8String:Patch::PATCHES_CONFIG_SECTION];
      NSString* enableKey=[NSString stringWithUTF8String:Patch::PATCH_ENABLE_CONFIG_KEY];
      NSString* disableKey=[NSString stringWithUTF8String:Patch::PATCH_DISABLE_CONFIG_KEY];
      NSMutableArray<NSString*>* enabled=[[
          ARMSX2Bridge patchEnableListForISO:nil section:section key:enableKey] mutableCopy];
      NSMutableArray<NSString*>* disabled=[[
          ARMSX2Bridge patchEnableListForISO:nil section:section key:disableKey] mutableCopy];
      [enabled removeObject:name];
      [disabled removeObject:name];
      if(state==1) [enabled addObject:name];
      else if(state==0 && toggleable) [disabled addObject:name];

      [ARMSX2Bridge setPatchEnableList:enabled forISO:nil section:section key:enableKey];
      [ARMSX2Bridge setPatchEnableList:disabled forISO:nil section:section key:disableKey];
      [enabled release];
      [disabled release];

      // Reload the current revision through the same upstream subsystem which
      // supplied the catalogue. There is no web scrape or guessed PNACH.
      Patch::ReloadPatches(serial,crc,true,true,true,true);
      Patch::UpdateActivePatches(true,true,true,true);
      success=YES;
    }
  },true);
  if(unsupportedAutomatic)
    return error_out("Automatic is only available for globally toggleable ARMSX2 patches.",error,capacity);
  return success ? 1 :
      error_out("ARMSX2 could not update this game's patch.",error,capacity);
}
int has_save_state(uint32_t slot) {
  if(!has_running_game() || slot<1 || slot>10) return 0;
  for(ARMSX2SaveStateSlotInfo* info in [ARMSX2Bridge saveStateSlots])
    if((uint32_t)info.slot==slot) return info.occupied ? 1 : 0;
  return 0;
}
int state_operation(bool load,uint32_t slot,uint32_t timeout,char* error,size_t capacity) {
  if(!has_running_game()) return error_out("ARMSX2 save states require a running game.",error,capacity);
  if(slot<1 || slot>10) return error_out("ARMSX2 save-state slot must be between 1 and 10.",error,capacity);
  __block BOOL success=NO;
  dispatch_semaphore_t done=dispatch_semaphore_create(0);
  ARMSX2SaveStateCompletion completion=^(BOOL ok){
    success=ok;
    dispatch_semaphore_signal(done);
  };
  if(load) [ARMSX2Bridge loadStateFromSlot:(NSInteger)slot completion:completion];
  else [ARMSX2Bridge saveStateToSlot:(NSInteger)slot completion:completion];
  const int64_t nanos=(int64_t)std::max<uint32_t>(timeout,1000u)*NSEC_PER_MSEC;
  if(dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,nanos))!=0)
    return error_out(load ? "ARMSX2 load state timed out." : "ARMSX2 save state timed out.",error,capacity);
  if(!success)
    return error_out(load ? "ARMSX2 could not load the selected state." : "ARMSX2 could not save the selected state.",error,capacity);
  return 1;
}
int save_state(uint32_t slot,uint32_t timeout,char* error,size_t capacity) {
  return state_operation(false,slot,timeout,error,capacity);
}
int load_state(uint32_t slot,uint32_t timeout,char* error,size_t capacity) {
  return state_operation(true,slot,timeout,error,capacity);
}

int get_retroachievements_state_json(char* output,size_t capacity) {
  if(!output || capacity<2 || !has_running_game()) return 0;
  @autoreleasepool {
    NSDictionary* state=[ARMSX2Bridge retroAchievementsState];
    if(![state isKindOfClass:NSDictionary.class] || ![NSJSONSerialization isValidJSONObject:state]) return 0;
    NSData* data=[NSJSONSerialization dataWithJSONObject:state options:0 error:nil];
    if(!data || data.length+1>capacity) return 0;
    memcpy(output,data.bytes,data.length); output[data.length]=0;
    return 1;
  }
}
bool wait_ra_value(NSString* key,bool expected,uint32_t timeout) {
  const auto deadline=std::chrono::steady_clock::now()+std::chrono::milliseconds(std::max<uint32_t>(timeout,250u));
  do {
    @autoreleasepool {
      id value=[ARMSX2Bridge retroAchievementsState][key];
      if([value respondsToSelector:@selector(boolValue)] && [value boolValue]==expected) return true;
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(20));
  } while(std::chrono::steady_clock::now()<deadline);
  return false;
}
int set_retroachievements_option(uint32_t option,int enabled,uint32_t timeout,char* error,size_t capacity) {
  if(!has_running_game()) return error_out("RetroAchievements requires a running ARMSX2 game.",error,capacity);
  const BOOL value=enabled!=0;
  NSString* key=nil;
  switch(option) {
    case NEO_ARMSX2_RA_ENABLED: key=@"enabled"; [ARMSX2Bridge setRetroAchievementsEnabled:value]; break;
    case NEO_ARMSX2_RA_HARDCORE: key=@"hardcorePreference"; [ARMSX2Bridge setRetroAchievementsHardcore:value]; break;
    case NEO_ARMSX2_RA_NOTIFICATIONS: key=@"notifications"; [ARMSX2Bridge setRetroAchievementsNotifications:value]; break;
    case NEO_ARMSX2_RA_LEADERBOARDS: key=@"leaderboardNotifications"; [ARMSX2Bridge setRetroAchievementsLeaderboards:value]; break;
    case NEO_ARMSX2_RA_OVERLAYS: key=@"overlays"; [ARMSX2Bridge setRetroAchievementsOverlays:value]; break;
    default: return error_out("Unsupported RetroAchievements option.",error,capacity);
  }
  return wait_ra_value(key,value,timeout) ? 1 :
      error_out("RetroAchievements setting did not settle before timeout.",error,capacity);
}
int login_retroachievements(const char* username,const char* password,uint32_t timeout,char* error,size_t capacity) {
  if(!has_running_game()) return error_out("RetroAchievements login requires a running ARMSX2 game.",error,capacity);
  if(!username || !password || !username[0] || !password[0])
    return error_out("RetroAchievements username and password are required.",error,capacity);
  if([NSThread isMainThread])
    return error_out("RetroAchievements login must run off the main thread.",error,capacity);
  __block BOOL completed=NO,success=NO;
  dispatch_semaphore_t done=dispatch_semaphore_create(0);
  NSString* user=[NSString stringWithUTF8String:username];
  NSString* pass=[NSString stringWithUTF8String:password];
  if(!user || !pass) return error_out("RetroAchievements credentials are not valid UTF-8.",error,capacity);
  [ARMSX2Bridge loginRetroAchievementsWithUsername:user password:pass completion:^(BOOL ok,NSString* message){
    success=ok; completed=YES; dispatch_semaphore_signal(done);
  }];
  const int64_t nanos=(int64_t)std::max<uint32_t>(timeout,1000u)*NSEC_PER_MSEC;
  if(dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,nanos))!=0 || !completed)
    return error_out("RetroAchievements login timed out.",error,capacity);
  return success ? 1 : error_out("RetroAchievements login failed.",error,capacity);
}
int logout_retroachievements(uint32_t timeout,char* error,size_t capacity) {
  if(!has_running_game()) return error_out("RetroAchievements logout requires a running ARMSX2 game.",error,capacity);
  [ARMSX2Bridge logoutRetroAchievements];
  const auto deadline=std::chrono::steady_clock::now()+std::chrono::milliseconds(std::max<uint32_t>(timeout,250u));
  do {
    @autoreleasepool {
      NSDictionary* state=[ARMSX2Bridge retroAchievementsState];
      const bool logged=[state[@"loggedIn"] boolValue] || [state[@"savedLogin"] boolValue];
      if(!logged) return 1;
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(20));
  } while(std::chrono::steady_clock::now()<deadline);
  return error_out("RetroAchievements logout did not settle before timeout.",error,capacity);
}

// All GS-setting operations use the existing upstream INI and apply paths.
// Never write BIOS bytes, arbitrary INI keys or a global performance preset.
int get_graphics_hacks_json(char* output,size_t capacity) {
  if (!output || capacity<2 || !has_running_game()) return 0;
  NSData* encoded=nil;
  Host::RunOnCPUThread([&]{
    @autoreleasepool {
      const BOOL available=VMManager::HasValidVM() &&
          [ARMSX2Bridge perGameIdentityKeyForCurrentGame].length>0;
      NSMutableArray* entries=[NSMutableArray array];
      if (available) {
        NSDictionary* effective=[ARMSX2Bridge graphicsHackState];
        for (const auto& hack : kNeoARMSX2GraphicsHacks) {
          NSString* key=[NSString stringWithUTF8String:hack.key];
          const BOOL overridden=[ARMSX2Bridge hasPerGameINIValue:@"EmuCore/GS" key:key forISO:nil];
          const int configured=overridden ?
              ([ARMSX2Bridge getPerGameINIBool:@"EmuCore/GS" key:key defaultValue:NO forISO:nil] ? 1 : 0) : -1;
          NSMutableDictionary* entry=[@{
            @"key":key, @"english":[NSString stringWithUTF8String:hack.english],
            @"french":[NSString stringWithUTF8String:hack.french], @"value":@(configured),
          } mutableCopy];
          NSDictionary* state=effective[key];
          if ([state isKindOfClass:NSDictionary.class]) entry[@"runtime"]=state;
          if ([key isEqualToString:@"UserHacks"])
            entry[@"runtime"]=@{@"effective":@(EmuConfig.GS.ManualUserHacks ? 1 : 0), @"reason":@0};
          [entries addObject:entry];
          [entry release];
        }
      }
      // The core is MRC; retain bytes across the CPU thread's autorelease pool.
      encoded=[[NSJSONSerialization dataWithJSONObject:@{
        @"available":@(available), @"items":entries
      } options:0 error:nil] retain];
    }
  },true);
  if (!encoded) return 0;
  const BOOL fits=encoded.length+1<=capacity;
  if (fits) { memcpy(output,encoded.bytes,encoded.length); output[encoded.length]=0; }
  [encoded release];
  return fits ? 1 : 0;
}
int set_graphics_hack(const char* name,int value,char* error,size_t capacity) {
  if (!name || !NeoARMSX2ValidGraphicsHack(name,value))
    return error_out("Unsupported ARMSX2 graphics hack or value.",error,capacity);
  if (!has_running_game())
    return error_out("Graphics hacks require a running game.",error,capacity);
  BOOL success=NO;
  Host::RunOnCPUThread([&]{
    @autoreleasepool {
      if (!VMManager::HasValidVM() || ![ARMSX2Bridge perGameIdentityKeyForCurrentGame].length) return;
      NSString* key=[NSString stringWithUTF8String:name];
      if (value==-1) {
        [ARMSX2Bridge deletePerGameINIValue:@"EmuCore/GS" key:key forISO:nil];
      } else {
        [ARMSX2Bridge setPerGameINIBool:@"EmuCore/GS" key:key value:value!=0 forISO:nil];
      }
      // The upstream per-game writer derives UserHackOverrides from keys
      // present in this game's INI. Its global pin setter is intentionally NOT
      // used here: changing one game must not alter every other game's hacks.
      // The writer also coalesces and queues the native per-game reload.
      const BOOL present=[ARMSX2Bridge hasPerGameINIValue:@"EmuCore/GS" key:key forISO:nil];
      success=value==-1 ? !present : present &&
          [ARMSX2Bridge getPerGameINIBool:@"EmuCore/GS" key:key defaultValue:NO forISO:nil]==(value!=0);
    }
  },true);
  return success ? 1 : error_out("ARMSX2 could not persist this game's graphics hack.",error,capacity);
}

const NeoARMSX2API api={sizeof(NeoARMSX2API),NEO_ARMSX2_ABI_VERSION,NEO_ARMSX2_SOURCE_REVISION,
  create_view,release_view,prepare,request_jit_detach,validate_jit,boot,request_stop,shutdown,paused,button,sticks,
  get_upscale_multiplier,get_aspect_ratio,get_cheats_enabled,set_upscale_multiplier,set_aspect_ratio,
  set_cheats_enabled,reload_cheats,get_available_patches_json,set_patch_state,
  has_save_state,save_state,load_state,
  get_retroachievements_state_json,set_retroachievements_option,
  login_retroachievements,logout_retroachievements,
  get_graphics_hacks_json,set_graphics_hack};
}
extern "C" bool ARMSX2_IsIdleVMPrewarmResolved() { return false; } // No autonomous prewarm in NeoStation.
extern "C" const NeoARMSX2API* NeoARMSX2_GetAPI(uint32_t version) {
  return version==NEO_ARMSX2_ABI_VERSION?&api:nullptr;
}
