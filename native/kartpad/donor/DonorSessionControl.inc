// Included inside NeoKartPadDonorCore's anonymous namespace after the checked
// CpuContext helper. This is canonical host code, not a CI-applied patch.
using DonorVoidFn = void (*)();
using DonorPointerFn = uint8_t* (*)(uint32_t, size_t);
struct DonorMemoryRegion { std::string name; uint32_t base; size_t size; };
using DonorDescribeFn = std::vector<DonorMemoryRegion> (*)();
using DonorSetWaitFn = void (*)(void (*)(void));
static neokartpad::SessionCommands commands;
static neokartpad::GuestMemory guestMemory;
static KartPadGuestCpuFn originalRun = nullptr;
static KartPadGuestCpuFn originalExitAfterMain = nullptr;
static KartPadGuestCpuFn setNextSectionFn = nullptr;
static KartPadGuestCpuFn changeSectionFn = nullptr;
static KartPadGuestCpuFn initializeSystemMessagesFn = nullptr;
static DonorVoidFn stopMixWorkerFn = nullptr;
static void* (*audioBackendInstanceFn)() = nullptr;
static void (*destroyAudioStreamFn)(void*) = nullptr;
static void (*quitAudioSubsystemFn)(uint32_t) = nullptr;
static DonorVoidFn cleanSocketsFn = nullptr;
static DonorVoidFn waitFrameWorkerFn = nullptr;
static DonorVoidFn resetMemoryFn = nullptr;
static DonorSetWaitFn setWaitCallbackFn = nullptr;
static DonorDescribeFn describeMemoryFn = nullptr;
static uint8_t** flatGuestBase = nullptr;
static uint8_t* donorDataInitialized = nullptr;
static bool frameGateEntered = false;
static uint64_t firstFrameLoggedForSession = 0;
static bool orderlyRuntimeReturn = false;
static int requestedExitReason = NEO_KARTPAD_EXIT_NONE;
static std::atomic_int lastExitReason{NEO_KARTPAD_EXIT_NONE};
static NSTimer* sessionAlertRetryTimer = nil;
static std::atomic_uint languageWrites{0};
static bool languageWriteFailed = false;
static UIAlertController* ownedSessionAlert = nil;
UIWindow* CurrentDonorWindow();
void ReturnToNeoStation(int reason);

void RunOnUIKitRunLoop(dispatch_block_t block) {
  NeoKartPadPerformRunLoop(block);
}

void PresentSessionAlert(UIAlertController* alert, uint64_t generation,
                         unsigned attempt = 0) {
  if (generation != commands.generation || !session.active() || commands.closing) return;
  UIWindow* window = CurrentDonorWindow();
  UIViewController* root = window.rootViewController;
  // Wait for the actual context-menu presentation to disappear, not an assumed
  // 250ms deadline. Never present over or dismiss another subsystem's alert.
  if (!root || !root.view.window || root.presentedViewController ||
      root.isBeingDismissed || root.isBeingPresented || root.transitionCoordinator) {
    if (attempt >= 60) {
      commands.failed();
      kNeoKartPadMenuActionInFlight.store(false, std::memory_order_release);
      NSLog(@"[NeoKartPad/Session] owned alert presentation unavailable after menu transition");
      return;
    }
    [sessionAlertRetryTimer invalidate];
    sessionAlertRetryTimer = NeoKartPadScheduleRunLoop(0.05, ^{
      PresentSessionAlert(alert, generation, attempt + 1);
    });
    return;
  }
  ownedSessionAlert = alert;
  [root presentViewController:alert animated:YES completion:nil];
}

void ShowSessionFailure(bool closing, const char* diagnostic) {
  NSLog(@"[NeoKartPad/Session] %@ failed: %s", closing ? @"close" : @"language", diagnostic);
  commands.failed();
  session.cancelStop();
  if (settingsButton) settingsButton.enabled = YES;
  kNeoKartPadMenuActionInFlight.store(false, std::memory_order_release);
  UIAlertController* alert = [UIAlertController alertControllerWithTitle:
      UIText(@"KartPad Settings", "settings") message:
      UIText(@"The operation could not be completed. Try again after the current game transition.",
             closing ? "closeFailed" : "languageApplyFailed")
      preferredStyle:UIAlertControllerStyleAlert];
  [alert addAction:[UIAlertAction actionWithTitle:UIText(@"OK", "okay")
      style:UIAlertActionStyleDefault handler:^(__kindof UIAlertAction*) {
    ownedSessionAlert = nil;
  }]];
  const auto generation = commands.generation;
  RunOnUIKitRunLoop(^{ PresentSessionAlert(alert, generation); });
}

void ConfirmGameLanguage(NSInteger value, void (^onChange)(void)) {
  if (!session.active() || session.state() == NEO_KARTPAD_STOPPING) return;
  const NSInteger applied = CurrentGameLanguage();
  if (value == applied) {
    if (onChange) onChange();
    return;
  }
  const uint64_t generation = commands.choose(static_cast<uint32_t>(value));
  if (!generation) return;
  bool expected = false;
  if (!kNeoKartPadMenuActionInFlight.compare_exchange_strong(expected, true)) {
    commands.cancel(generation);
    return;
  }

  UIAlertController* alert = [UIAlertController alertControllerWithTitle:
      UIText(@"Restart game?", "restartRequiredTitle")
      message:UIText(@"The game must restart to apply this language. Restart now?",
                     "languageRestartMessage") preferredStyle:UIAlertControllerStyleAlert];
  [alert addAction:[UIAlertAction actionWithTitle:UIText(@"Cancel", "cancel")
      style:UIAlertActionStyleCancel handler:^(__kindof UIAlertAction*) {
    if (!commands.cancel(generation)) return;
    ownedSessionAlert = nil;
    kNeoKartPadMenuActionInFlight.store(false, std::memory_order_release);
    if (onChange) onChange();
  }]];
  [alert addAction:[UIAlertAction actionWithTitle:UIText(@"Restart", "restartGame")
      style:UIAlertActionStyleDefault handler:^(__kindof UIAlertAction*) {
    if (!commands.confirm(generation)) return;
    ownedSessionAlert = nil;

    // Reload the title at the verified guest frame boundary. Re-entering
    // RuntimeMain tears down and recreates process-wide SDL/Aurora state just
    // to change a language; the donor already supports a title transition
    // with checked archive, system-message and SYSCONF updates.
    NSLog(@"[NeoKartPad/Language] confirmed title reload %ld -> %ld transaction=%llu",
          (long)applied, (long)value, (unsigned long long)generation);
  }]];

  // RuntimeMain owns the UIKit thread. GCD main-queue work may not be drained
  // while SDL pumps its nested event loop, so schedule on the actual CFRunLoop.
  RunOnUIKitRunLoop(^{ PresentSessionAlert(alert, generation); });
}

void PersistAcceptedLanguage(uint32_t language) {
  PersistInteger(kNeoKartPadLanguageKey, language);
  languageWriteFailed = false;
  languageWrites.fetch_add(1, std::memory_order_acq_rel);
  dispatch_async(KartPadSettingsIOQueue(), ^{
    NSError* error = nil;
    const bool okay = WriteGameLanguageSysConf(&error);
    // RuntimeMain owns a nested UIKit run loop. A GCD main-queue completion
    // can remain pending until the game exits, leaving languageWrites > 0 and
    // the language menu locked even after the title has reloaded.
    RunOnUIKitRunLoop(^{
      languageWriteFailed |= !okay;
      if (!okay) NSLog(@"[NeoKartPad/Language] Wii IPL.LNG persistence failed: %@", error);
      languageWrites.fetch_sub(1, std::memory_order_acq_rel);
      LogLifecycleBoundary(okay ? "language SYSCONF write completed on UIKit run loop"
                                 : "language SYSCONF write failed on UIKit run loop");
    });
  });
}

bool BeginTitleTransition(void* cpu, uint32_t language) {
  const uint32_t manager = guestMemory.read32(neokartpad::kSectionManager);
  if (!manager || guestMemory.read32(manager + 0x30) != 0 ||
      guestMemory.read32(manager + 0xc) != 0xffffffffu) return false;
  std::array<uint8_t, 0x34> managerBefore;
  std::memcpy(managerBefore.data(), guestMemory.at(manager, managerBefore.size()), managerBefore.size());
  neokartpad::LanguageState languageBefore;
  neokartpad::SystemMessageState messagesBefore;
  // Validate all destinations before changing any language-related state.
  if (language) {
    languageBefore = neokartpad::LanguageState::inspect(guestMemory);
    messagesBefore = neokartpad::SystemMessageState::inspect(guestMemory);
  }
  try {
    if (language) {
      languageBefore.apply(guestMemory, language);
      if (!SetRuntimeLanguageOverride(language))
        throw std::runtime_error("host language slot unavailable");
      if (!InvokeKartPadGuestPreservingCpu(cpu, initializeSystemMessagesFn,
                                           messagesBefore.holder, 0u, 0u) ||
          !messagesBefore.matches(guestMemory, language))
        throw std::runtime_error("system messages did not rebind to selected language");
    }
    bool accepted = InvokeKartPadGuestPreservingCpu(cpu, setNextSectionFn, manager,
        neokartpad::kTitleFromBoot, 0xffffffffu);
    accepted = accepted && guestMemory.read32(manager + 0xc) == neokartpad::kTitleFromBoot;
    accepted = accepted && InvokeKartPadGuestPreservingCpu(cpu, changeSectionFn, manager, 0u, 0x000000ffu);
    accepted = accepted && guestMemory.read32(manager + 0x30) == 2;
    if (!accepted)
      throw std::runtime_error("title transition rejected; language transaction rolled back");
  } catch (...) {
    std::memcpy(guestMemory.at(manager, managerBefore.size()), managerBefore.data(), managerBefore.size());
    if (language) {
      messagesBefore.rollback(guestMemory);
      languageBefore.rollback(guestMemory);
      SetRuntimeLanguageOverride(languageBefore.requestedLanguage);
    }
    throw;
  }
  if (language) PersistAcceptedLanguage(language);
  commands.accepted();
  NSLog(@"[NeoKartPad/Session] accepted title transition=0x3f language=%u closing=%d (not yet completed)",
        language, commands.closing);
  return true;
}

// Called only after RKSystem::onEndFrame has returned. The gate preserves all
// native registers; any translated helper gets a complete guest CPU snapshot.
uint32_t KartPadFrameBoundary(void* cpu) {
  if (cpu && session.active()) {
    const uint64_t serial = sessionSerial.load(std::memory_order_acquire);
    if (firstFrameLoggedForSession != serial) {
      firstFrameLoggedForSession = serial;
      LogLifecycleBoundary("guest reached first frame boundary");
    }
  }
  if (frameGateEntered || !cpu || commands.phase == neokartpad::SessionCommands::Phase::idle ||
      commands.phase == neokartpad::SessionCommands::Phase::confirming ||
      commands.phase == neokartpad::SessionCommands::Phase::closed) return 0;
  frameGateEntered = true;
  struct Guard { ~Guard() { frameGateEntered = false; } } guard;
  const bool closing = commands.closing;
  try {
    if (++commands.frames > 1800) {
      ShowSessionFailure(closing, "frame-boundary operation timed out; no forced exit"); return 0;
    }
    if (commands.phase == neokartpad::SessionCommands::Phase::queued) {
      BeginTitleTransition(cpu, commands.selected); return 0;
    }
    const auto manager = guestMemory.read32(neokartpad::kSectionManager);
    if (!manager || guestMemory.read32(manager + 0x30) != 0) return 0;
    const auto section = guestMemory.read32(manager);
    if (!section || guestMemory.read32(section) != neokartpad::kTitleFromBoot ||
        guestMemory.read32(manager + 0xc) != 0xffffffffu) return 0;
    if (languageWrites.load(std::memory_order_acquire)) return 0;
    if (!closing) {
      if (!neokartpad::LanguageState::inspect(guestMemory).matches(commands.selected) ||
          !neokartpad::SystemMessageState::inspect(guestMemory).matches(guestMemory, commands.selected))
        throw std::runtime_error("title loaded but SystemManager/archive language verification failed");
      NSLog(@"[NeoKartPad/Language] completed title reload language=%u; cache, system messages and UI/Common suffixes verified",
            commands.selected);
      LogLifecycleBoundary("title and localized resources reloaded in current guest session");
      commands.complete();
      kNeoKartPadMenuActionInFlight.store(false, std::memory_order_release);
      RefreshSettingsMenu();
      if (languageWriteFailed) ShowSessionFailure(false, "language applied but SYSCONF persistence failed");
      return 0;
    }
    // SectionMgr::ExitSection has now run its normal save/network transitions.
    // Do not emit sessionEnded or expose the library until RuntimeMain's own
    // fiber/renderer/window cleanup has returned.
    setWaitCallbackFn(nullptr); // no late VI/guest callbacks while draining GPU
    LogLifecycleBoundary("guest transition complete; AX join begin");
    stopMixWorkerFn();          // join AX worker BEFORE guest memory can disappear
    LogLifecycleBoundary("AX joined; audio stream release begin");
    // Aurora's SDL_Quit destroys SDL streams but cannot reset the persistent
    // C++ AudioBackend. Without this, the next Init returns early with a freed
    // stream, and menu/volume callbacks may touch it during a language restart.
    {
      static_assert(sizeof(std::mutex) == 0x40, "pinned Darwin audio mutex ABI");
      void* backend = audioBackendInstanceFn();
      std::lock_guard<std::mutex> lock(*static_cast<std::mutex*>(backend));
      neokartpad::ReleaseDonorAudioSession(
          backend, destroyAudioStreamFn, quitAudioSubsystemFn);
    }
    NSLog(@"[NeoKartPad/Lifecycle] session=%llu audio stream released and backend reset",
          (unsigned long long)sessionSerial.load());
    LogLifecycleBoundary("audio stream released; GPU drain begin");
    waitFrameWorkerFn();
    cleanSocketsFn();
    LogLifecycleBoundary("GPU and sockets drained; donor cleanup begin");
    commands.complete();
    orderlyRuntimeReturn = true;
    NSLog(@"[NeoKartPad/Session] save transition complete; AX/GPU drained; returning through RuntimeMain cleanup");
    return 1;
  } catch (const std::exception& error) {
    ShowSessionFailure(closing, error.what());
  } catch (...) {
    ShowSessionFailure(closing, "unexpected native exception at frame boundary");
  }
  return 0;
}

void KartPadRunWithReturnBoundary(void* cpu) {
  alignas(16) std::array<uint8_t, 464> caller{};
  std::memcpy(caller.data(), cpu, caller.size());
  originalRun(cpu);
  // run originally never returned. Restore the guest caller's r1/LR and
  // callee-saved registers before RKSystem::main's existing guest epilogue.
  std::memcpy(cpu, caller.data(), caller.size());
}

void KartPadExitAfterMain(void* cpu) {
  if (!orderlyRuntimeReturn) {
    // Preserve the donor's real fatal/exit behavior; only our proven, drained
    // shutdown may bypass the program's terminal exit call.
    originalExitAfterMain(cpu);
    return;
  }
  const uint32_t success = 0;
  std::memcpy(static_cast<uint8_t*>(cpu) + 12, &success, sizeof(success));
  NSLog(@"[NeoKartPad/Session] guest main returned; intercepted its terminal exit for host-owned shutdown");
}

bool BindSessionBridge(char* error, size_t errorSize) {
  audioBackendInstanceFn = reinterpret_cast<void* (*)()>(
      dlsym(runtimeHandle, "_ZN12AudioBackend8InstanceEv"));
  destroyAudioStreamFn = reinterpret_cast<void (*)(void*)>(
      dlsym(runtimeHandle, "SDL_DestroyAudioStream"));
  quitAudioSubsystemFn = reinterpret_cast<void (*)(uint32_t)>(
      dlsym(runtimeHandle, "SDL_QuitSubSystem"));
  const void* audioLayout = dlsym(runtimeHandle,
      "_ZN12AudioBackend23EnsureInitializedLockedEjj");
  if (!audioBackendInstanceFn || !destroyAudioStreamFn || !quitAudioSubsystemFn ||
      !audioLayout || std::memcmp(audioLayout, neokartpad::kDonorAudioLayoutWitness,
                                 sizeof(neokartpad::kDonorAudioLayoutWitness)) != 0)
    return Fail(error, errorSize, "KartPad audio session layout/symbols do not match the verified donor.");
  Dl_info info{};
  if (!dladdr(reinterpret_cast<void*>(runtimeMain), &info) || !info.dli_fbase)
    return Fail(error, errorSize, "KartPad session image base unavailable");
  auto* base = static_cast<uint8_t*>(info.dli_fbase);
  constexpr char marker[] = "NEOKARTPAD-FRAME-RETURN-v1";
  if (std::memcmp(base + 0x8f00, marker, sizeof(marker)) != 0)
    return Fail(error, errorSize, "KartPad checked frame/return bridge missing");
  // InitializeDataSections checks g_dataInitialized before loading the DOL's
  // .sdata, including the switch-thread callback at guest 0x80385AE0. This
  // exact pinned instruction sequence and BSS offset are verified together.
  // The symbol is local, so dlsym cannot resolve it in the converted dylib.
  constexpr uint8_t dataInitGuard[] = {
      0x28, 0x85, 0x02, 0xd0, // adrp x8, g_dataInitialized page
      0x09, 0x21, 0x48, 0x39, // ldrb w9, [x8, #0x208]
      0x49, 0x40, 0x00, 0x37, // tbnz w9, #0, skip initialization
      0x29, 0x00, 0x80, 0x52, // mov w9, #1
  };
  if (std::memcmp(base + 0x10c740, dataInitGuard, sizeof(dataInitGuard)) != 0)
    return Fail(error, errorSize, "KartPad data-section initialization guard changed.");
  donorDataInitialized = base + 0x51b2208;
  if (*donorDataInitialized != 0)
    return Fail(error, errorSize, "KartPad data-section guard was already active before launch.");
  guestMemory.pointer = reinterpret_cast<DonorPointerFn>(dlsym(runtimeHandle, "_ZN6Memory10GetPointerEjm"));
  setNextSectionFn = reinterpret_cast<KartPadGuestCpuFn>(dlsym(runtimeHandle,"func_80635A3C"));
  changeSectionFn = reinterpret_cast<KartPadGuestCpuFn>(dlsym(runtimeHandle,"func_80635AC8"));
  initializeSystemMessagesFn = reinterpret_cast<KartPadGuestCpuFn>(dlsym(runtimeHandle,"func_80637A20"));
  stopMixWorkerFn = reinterpret_cast<DonorVoidFn>(dlsym(runtimeHandle,"_ZN8AxDspHle17ShutdownMixWorkerEv"));
  cleanSocketsFn = reinterpret_cast<DonorVoidFn>(dlsym(runtimeHandle,"_ZN10NetworkHle20CleanupAllWiiSocketsEv"));
  waitFrameWorkerFn = reinterpret_cast<DonorVoidFn>(dlsym(runtimeHandle,"aurora_wait_for_frame_worker"));
  setWaitCallbackFn = reinterpret_cast<DonorSetWaitFn>(dlsym(runtimeHandle,"aurora_set_frame_worker_wait_callback"));
  resetMemoryFn = reinterpret_cast<DonorVoidFn>(dlsym(runtimeHandle,"_ZN6Memory5ResetEv"));
  describeMemoryFn = reinterpret_cast<DonorDescribeFn>(dlsym(runtimeHandle,"_ZN6Memory15DescribeRegionsEv"));
  flatGuestBase = reinterpret_cast<uint8_t**>(dlsym(runtimeHandle,"_ZN9GuestFlat14gFlatGuestBaseE"));
  if (!guestMemory.pointer || !setNextSectionFn || !changeSectionFn || !initializeSystemMessagesFn || !stopMixWorkerFn ||
      !cleanSocketsFn || !waitFrameWorkerFn || !setWaitCallbackFn || !resetMemoryFn ||
      !describeMemoryFn || !flatGuestBase)
    return Fail(error, errorSize, "KartPad cooperative cleanup symbols missing");
  originalRun = reinterpret_cast<KartPadGuestCpuFn>(base + 0x8000);
  originalExitAfterMain = reinterpret_cast<KartPadGuestCpuFn>(base + 0x2ec9d8);
  auto** control = reinterpret_cast<void**>(base + 0x534ff80);
  control[0] = reinterpret_cast<void*>(&KartPadRunWithReturnBoundary);
  control[1] = reinterpret_cast<void*>(&KartPadFrameBoundary);
  control[2] = reinterpret_cast<void*>(&KartPadExitAfterMain);
  return true;
}

bool PrepareReusableGuestMemory() {
  // Do NOT munmap GuestFlat's reservation or backing aliases here. The pinned
  // runtime intentionally keeps g_initialized/g_layout/g_sections in native
  // process-lifetime storage; tearing the mappings down behind those objects
  // made the next RuntimeMain dereference stale section.host pointers.
  //
  // Memory::Reset clears translated page tables/deferred reads. On the next
  // GuestFlat::Initialize with the same verified layout, the runtime zeros
  // every backing section before rebuilding Memory regions. This gives each
  // KartPad launch clean guest contents without accumulating mappings.
  if (!orderlyRuntimeReturn) return true;
  if (!resetMemoryFn || !flatGuestBase || !*flatGuestBase) return false;
  resetMemoryFn();
  if (!neokartpad::RearmDonorDataSections(donorDataInitialized)) {
    NSLog(@"[NeoKartPad/Lifecycle] data-section guard could not be rearmed after guest reset");
    return false;
  }
  NSLog(@"[NeoKartPad/Lifecycle] reusable guest reservation retained and page tables reset");
  LogLifecycleBoundary("data-section guard rearmed for next RuntimeMain");
  return true;
}
