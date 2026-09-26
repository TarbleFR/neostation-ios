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
static DonorVoidFn cleanSocketsFn = nullptr;
static DonorVoidFn waitFrameWorkerFn = nullptr;
static DonorVoidFn resetMemoryFn = nullptr;
static DonorSetWaitFn setWaitCallbackFn = nullptr;
static DonorDescribeFn describeMemoryFn = nullptr;
static uint8_t** flatGuestBase = nullptr;
static bool frameGateEntered = false;
static bool orderlyRuntimeReturn = false;
static bool restartAfterShutdown = false;
static uint32_t restartLanguage = 0;
static std::atomic_uint_fast64_t sessionSerial{0};
static std::atomic_uint languageWrites{0};
static bool languageWriteFailed = false;
static UIAlertController* ownedSessionAlert = nil;
UIWindow* CurrentDonorWindow();
void ReturnToNeoStation();

void RunOnUIKitRunLoop(dispatch_block_t block) {
  if (!block) return;
  CFRunLoopPerformBlock(CFRunLoopGetMain(), kCFRunLoopCommonModes, block);
  CFRunLoopWakeUp(CFRunLoopGetMain());
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
    NSTimer* retry = [NSTimer timerWithTimeInterval:0.05 repeats:NO
        block:^(__unused NSTimer* timer) {
      PresentSessionAlert(alert, generation, attempt + 1);
    }];
    [NSRunLoop.mainRunLoop addTimer:retry forMode:NSRunLoopCommonModes];
    return;
  }
  ownedSessionAlert = alert;
  [root presentViewController:alert animated:YES completion:nil];
}

void ShowSessionFailure(bool closing, const char* diagnostic) {
  NSLog(@"[NeoKartPad/Session] %@ failed: %s", closing ? @"close" : @"language", diagnostic);
  commands.failed();
  session.cancelStop();
  if (returnButton) returnButton.enabled = YES;
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
    ownedSessionAlert = nil;
    commands.cancel(generation);
    kNeoKartPadMenuActionInFlight.store(false, std::memory_order_release);
    if (onChange) onChange();
  }]];
  [alert addAction:[UIAlertAction actionWithTitle:UIText(@"Restart", "restartGame")
      style:UIAlertActionStyleDefault handler:^(__kindof UIAlertAction*) {
    ownedSessionAlert = nil;
    if (!commands.confirm(generation)) return;

    // Persist the desired language before shutdown. The active guest is not
    // patched in place: the confirmed operation is a full shutdown -> cleanup
    // -> fresh RuntimeMain session.
    PersistInteger(kNeoKartPadLanguageKey, value);
    NSError* persistenceError = nil;
    if (!WriteGameLanguageSysConf(&persistenceError)) {
      PersistInteger(kNeoKartPadLanguageKey, applied);
      commands.failed();
      kNeoKartPadMenuActionInFlight.store(false, std::memory_order_release);
      ShowSessionFailure(false, persistenceError.localizedDescription.UTF8String);
      return;
    }
    restartAfterShutdown = true;
    restartLanguage = static_cast<uint32_t>(value);
    NSLog(@"[NeoKartPad/Lifecycle] session=%llu language restart requested %ld -> %ld",
          (unsigned long long)sessionSerial.load(), (long)applied, (long)value);
    ReturnToNeoStation();
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
    dispatch_async(dispatch_get_main_queue(), ^{
      languageWriteFailed |= !okay;
      if (!okay) NSLog(@"[NeoKartPad/Language] Wii IPL.LNG persistence failed: %@", error);
      languageWrites.fetch_sub(1, std::memory_order_acq_rel);
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
    stopMixWorkerFn();          // join AX worker BEFORE guest memory can disappear
    waitFrameWorkerFn();
    cleanSocketsFn();
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
  Dl_info info{};
  if (!dladdr(reinterpret_cast<void*>(runtimeMain), &info) || !info.dli_fbase)
    return Fail(error, errorSize, "KartPad session image base unavailable");
  auto* base = static_cast<uint8_t*>(info.dli_fbase);
  constexpr char marker[] = "NEOKARTPAD-FRAME-RETURN-v1";
  if (std::memcmp(base + 0x8f00, marker, sizeof(marker)) != 0)
    return Fail(error, errorSize, "KartPad checked frame/return bridge missing");
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

void ReleaseTerminalGuestMemory() {
  // This donor has process-lifetime native registries, so a stopped runtime is
  // deliberately terminal (the existing relaunch barrier remains). It is safe
  // to reclaim its guest reservation only AFTER RuntimeMain has shut down all
  // fibers and Aurora. The ObjC/SDL image itself remains loaded: no dlclose.
  if (!orderlyRuntimeReturn || !flatGuestBase || !*flatGuestBase) return;
  struct Range { uintptr_t begin, end; };
  std::vector<Range> ranges;
  const size_t page = static_cast<size_t>(getpagesize());
  const uintptr_t flat = reinterpret_cast<uintptr_t>(*flatGuestBase);
  const size_t flatSize = (size_t{1} << 32) + page;
  try {
    const auto regions = describeMemoryFn();
    for (const auto& region : regions) {
      if (!region.size || region.size > (size_t{1} << 30))
        throw std::runtime_error("invalid terminal guest mapping size");
      const auto begin = reinterpret_cast<uintptr_t>(guestMemory.pointer(region.base, region.size));
      const auto end = begin + ((region.size + page - 1) & ~(page - 1));
      if (!begin || begin % page || end <= begin || (begin < flat + flatSize && flat < end))
        throw std::runtime_error("invalid terminal host alias mapping");
      ranges.push_back({begin, end});
    }
    std::sort(ranges.begin(), ranges.end(), [](const Range& a, const Range& b) { return a.begin < b.begin; });
    std::vector<Range> merged;
    for (const auto& range : ranges) {
      if (!merged.empty() && range.begin <= merged.back().end)
        merged.back().end = std::max(merged.back().end, range.end);
      else merged.push_back(range);
    }
    resetMemoryFn(); // resolves deferred page protections before any munmap
    size_t released = 0;
    for (const auto& range : merged) {
      if (munmap(reinterpret_cast<void*>(range.begin), range.end-range.begin) == 0)
        released += range.end-range.begin;
      else NSLog(@"[NeoKartPad/Session] host alias munmap failed: %d", errno);
    }
    const int result = munmap(reinterpret_cast<void*>(flat), flatSize);
    if (result == 0) *flatGuestBase = nullptr;
    NSLog(@"[NeoKartPad/Session] terminal cleanup host-ram=%zu flat-reservation=%zu result=%d",
          released, flatSize, result);
  } catch (const std::exception& error) {
    NSLog(@"[NeoKartPad/Session] mapping reclaim refused safely: %s", error.what());
  }
}
