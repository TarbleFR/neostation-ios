#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>

#include "KartPadCoreABI.h"
#include "../core/SessionState.h"
#include "../core/GuestLanguageState.h"
#include <algorithm>
#include <array>
#include <vector>
#include <stdexcept>
#include <sys/mman.h>

#include <atomic>
#include <cerrno>
#include <cstring>
#include <sys/stat.h>
#include <unistd.h>
#include <cstdio>
#include <cstdlib>
#include <functional>
#include <mutex>
#include <string>
#include <thread>
#include <unordered_map>

struct SDL_Window;

namespace {
NeoKartPadSessionState session;
NeoKartPadEventFn callback = nullptr;
void* callbackContext = nullptr;

using RuntimeMainFn = int (*)(int, char**);
using SDLGetWindowsFn = SDL_Window** (*)(int*);
using SDLWindowVisibilityFn = bool (*)(SDL_Window*);
using SDLFreeFn = void (*)(void*);
using SDLSetMainReadyFn = void (*)(void);
using SDLiOSEventPumpFn = void (*)(bool);
using SDLGetErrorFn = const char* (*)(void);

void* runtimeHandle = nullptr;
RuntimeMainFn runtimeMain = nullptr;
SDLGetWindowsFn sdlGetWindows = nullptr;
SDLWindowVisibilityFn sdlHideWindow = nullptr;
SDLWindowVisibilityFn sdlShowWindow = nullptr;
SDLFreeFn sdlFree = nullptr;
SDLSetMainReadyFn sdlSetMainReady = nullptr;
SDLiOSEventPumpFn sdlSetiOSEventPump = nullptr;
SDLGetErrorFn sdlGetError = nullptr;

std::atomic_bool runtimeThreadActive{false};
std::string supportPath;
std::string cachePath;
std::string gamePath;
UIWindow* neoStationWindow = nil;
UIWindow* donorWindow = nil;
UIButton* returnButton = nil;
UIButton* settingsButton = nil;

std::mutex uiTextMutex;
std::unordered_map<std::string, std::string> uiText;

int Fail(char* error, size_t errorSize, const char* message) {
  if (error && errorSize) std::snprintf(error, errorSize, "%s", message);
  NSLog(@"[NeoKartPad/Donor] %s", message);
  return 0;
}

void Emit(const char* message) {
  NSLog(@"[NeoKartPad/Donor] state=%d %s", session.state(),
        message ? message : "");
  if (callback) callback(callbackContext, session.state(), message ? message : "");
}

NSString* RuntimePath() {
  NSString* frameworks = NSBundle.mainBundle.privateFrameworksPath;
  return [frameworks stringByAppendingPathComponent:
      @"KartPadRuntime.framework/KartPadRuntime"];
}

NSString* UIText(NSString* fallback, const char* key) {
  std::lock_guard lock(uiTextMutex);
  const auto it = uiText.find(key ? std::string(key) : std::string());
  if (it == uiText.end() || it->second.empty()) return fallback;
  return [NSString stringWithUTF8String:it->second.c_str()];
}

static NSString* const kNeoKartPadLanguageKey = @"NeoKartPadGameLanguage";
static NSString* const kKartPadRequestedRuntimeProfileKey =
    @"KartPadRequestedRuntimeProfile";
static NSString* const kKartPadPreferredGameKey =
    @"KartPadPreferredGame";
static NSString* const kNeoKartPadRuntimeLanguageMenuIdentifier =
    @"com.neostation.kartpad.runtime-language";
static NSString* const kNeoKartPadAdvancedGraphicsMenuIdentifier =
    @"com.neostation.kartpad.advanced-graphics";
static NSString* const kNeoKartPadReturnToGameIdentifier =
    @"com.neostation.kartpad.return-to-game";
static NSString* const kKartPadAutoAccelerateKey =
    @"KartPadAutoAccelerate";
static char kNeoKartPadPatchedMenuKey;
static std::atomic_bool kNeoKartPadMenuPatchInProgress{false};
static std::atomic_bool kNeoKartPadMenuActionInFlight{false};
static std::atomic_uint_fast64_t kNeoKartPadMenuRefreshGeneration{0};

NSInteger CurrentGameLanguage() {
  NSInteger value = [NSUserDefaults.standardUserDefaults integerForKey:kNeoKartPadLanguageKey];
  return value >= 1 && value <= 6 ? value : 1;
}

bool WriteGameLanguageSysConf(NSError** error) {
  if (supportPath.empty()) return true;
  NSString* support = [NSString stringWithUTF8String:supportPath.c_str()];
  NSString* directory =
      [support stringByAppendingPathComponent:@"Saves/NAND/shared2/sys"];
  NSFileManager* files = NSFileManager.defaultManager;
  if (![files createDirectoryAtPath:directory withIntermediateDirectories:YES
                         attributes:nil error:error]) {
    return false;
  }
  NSString* filePath = [directory stringByAppendingPathComponent:@"SYSCONF"];
  NSMutableData* data = nil;
  NSData* existing = [NSData dataWithContentsOfFile:filePath options:0 error:nil];
  if (existing.length == 0x4000) {
    const uint8_t* raw = static_cast<const uint8_t*>(existing.bytes);
    if (memcmp(raw, "SCv0", 4) == 0 &&
        memcmp(raw + 0x3ffc, "SCed", 4) == 0) {
      data = [existing mutableCopy];
      uint8_t* bytes = static_cast<uint8_t*>(data.mutableBytes);
      const uint16_t count =
          (static_cast<uint16_t>(bytes[4]) << 8) | bytes[5];
      bool patched = false;
      for (uint16_t index = 0; index < count; ++index) {
        const size_t table = 6 + static_cast<size_t>(index) * 2;
        if (table + 1 >= data.length) break;
        const uint16_t offset =
            (static_cast<uint16_t>(bytes[table]) << 8) | bytes[table + 1];
        if (offset + 1 >= data.length) continue;
        const uint8_t description = bytes[offset];
        const uint8_t type = (description & 0xe0u) >> 5;
        const size_t nameLength = (description & 0x1fu) + 1u;
        if (offset + 1 + nameLength >= data.length) continue;
        if (type == 3 && nameLength == 7 &&
            memcmp(bytes + offset + 1, "IPL.LNG", 7) == 0) {
          bytes[offset + 1 + nameLength] =
              static_cast<uint8_t>(CurrentGameLanguage());
          patched = true;
          break;
        }
      }
      if (patched) {
        return [data writeToFile:filePath options:NSDataWritingAtomic error:error];
      }
      // Preserve any valid existing SYSCONF that we do not understand rather
      // than destroying unrelated virtual-console settings.
      return true;
    }
  }

  data = [NSMutableData dataWithLength:0x4000];
  uint8_t* bytes = static_cast<uint8_t*>(data.mutableBytes);
  memcpy(bytes, "SCv0", 4);
  bytes[4] = 0;
  bytes[5] = 1;       // one entry
  bytes[6] = 0;
  bytes[7] = 10;      // IPL.LNG entry offset
  bytes[8] = 0;
  bytes[9] = 19;      // dummy past-the-end offset
  bytes[10] = static_cast<uint8_t>((3u << 5) | 6u); // Byte + 7-char name
  memcpy(bytes + 11, "IPL.LNG", 7);
  bytes[18] = static_cast<uint8_t>(CurrentGameLanguage());
  memcpy(bytes + 0x3ffc, "SCed", 4);
  return [data writeToFile:filePath options:NSDataWritingAtomic error:error];
}

void PersistInteger(NSString* key, NSInteger value) {
  // NSUserDefaults is already asynchronously persisted by Foundation. Calling
  // synchronize from a UIKit menu action can block the main thread on storage.
  [NSUserDefaults.standardUserDefaults setInteger:value forKey:key];
}

void PersistBool(NSString* key, BOOL value) {
  [NSUserDefaults.standardUserDefaults setBool:value forKey:key];
}

NSString* KartPadConfigPath() {
  if (supportPath.empty()) return nil;
  NSString* support = [NSString stringWithUTF8String:supportPath.c_str()];
  return [support stringByAppendingPathComponent:@"Config/Config.toml"];
}

NSString* ReadVideoSetting(NSString* key, NSString* fallback) {
  NSString* path = KartPadConfigPath();
  if (path.length == 0) return fallback;
  NSString* config = [NSString stringWithContentsOfFile:path
                                              encoding:NSUTF8StringEncoding
                                                 error:nil];
  if (config.length == 0) return fallback;
  BOOL inVideo = NO;
  NSCharacterSet* whitespace =
      NSCharacterSet.whitespaceAndNewlineCharacterSet;
  for (NSString* line in [config componentsSeparatedByString:@"\n"]) {
    NSString* trimmed = [line stringByTrimmingCharactersInSet:whitespace];
    if ([trimmed hasPrefix:@"["] && [trimmed hasSuffix:@"]"]) {
      inVideo = [trimmed isEqualToString:@"[video]"];
      continue;
    }
    if (!inVideo || trimmed.length == 0 || [trimmed hasPrefix:@"#"]) continue;
    NSRange equal = [trimmed rangeOfString:@"="];
    if (equal.location == NSNotFound) continue;
    NSString* lhs = [[trimmed substringToIndex:equal.location]
        stringByTrimmingCharactersInSet:whitespace];
    if (![lhs isEqualToString:key]) continue;
    NSString* rhs = [[trimmed substringFromIndex:equal.location + 1]
        stringByTrimmingCharactersInSet:whitespace];
    NSRange comment = [rhs rangeOfString:@"#"];
    if (comment.location != NSNotFound) {
      rhs = [[rhs substringToIndex:comment.location]
          stringByTrimmingCharactersInSet:whitespace];
    }
    return rhs.length ? rhs : fallback;
  }
  return fallback;
}

BOOL ReadVideoBool(NSString* key, BOOL fallback) {
  NSString* raw = [ReadVideoSetting(key, fallback ? @"true" : @"false")
      lowercaseString];
  if ([raw isEqualToString:@"true"]) return YES;
  if ([raw isEqualToString:@"false"]) return NO;
  return fallback;
}

NSInteger ReadVideoInteger(NSString* key, NSInteger fallback) {
  NSString* raw = ReadVideoSetting(
      key, [NSString stringWithFormat:@"%ld", (long)fallback]);
  NSScanner* scanner = [NSScanner scannerWithString:raw];
  NSInteger value = fallback;
  return [scanner scanInteger:&value] ? value : fallback;
}

bool WriteVideoSetting(NSString* key, NSString* value, NSError** error) {
  NSString* path = KartPadConfigPath();
  if (path.length == 0) return false;
  NSFileManager* files = NSFileManager.defaultManager;
  if (![files createDirectoryAtPath:path.stringByDeletingLastPathComponent
        withIntermediateDirectories:YES attributes:nil error:error]) {
    return false;
  }
  NSString* config = [NSString stringWithContentsOfFile:path
                                                encoding:NSUTF8StringEncoding
                                                   error:nil] ?: @"";
  NSMutableArray<NSString*>* lines =
      [[config componentsSeparatedByString:@"\n"] mutableCopy];
  NSCharacterSet* whitespace =
      NSCharacterSet.whitespaceAndNewlineCharacterSet;
  NSInteger videoHeader = -1;
  NSInteger nextSection = lines.count;
  NSInteger keyLine = -1;
  BOOL inVideo = NO;
  for (NSInteger index = 0; index < (NSInteger)lines.count; ++index) {
    NSString* trimmed = [lines[index]
        stringByTrimmingCharactersInSet:whitespace];
    if ([trimmed hasPrefix:@"["] && [trimmed hasSuffix:@"]"]) {
      if (inVideo && nextSection == (NSInteger)lines.count) {
        nextSection = index;
      }
      inVideo = [trimmed isEqualToString:@"[video]"];
      if (inVideo) videoHeader = index;
      continue;
    }
    if (!inVideo || trimmed.length == 0 || [trimmed hasPrefix:@"#"]) continue;
    NSRange equal = [trimmed rangeOfString:@"="];
    if (equal.location == NSNotFound) continue;
    NSString* lhs = [[trimmed substringToIndex:equal.location]
        stringByTrimmingCharactersInSet:whitespace];
    if ([lhs isEqualToString:key]) {
      keyLine = index;
      break;
    }
  }
  NSString* setting = [NSString stringWithFormat:@"%@ = %@", key, value];
  if (videoHeader < 0) {
    if (lines.count && [lines.lastObject length] != 0) [lines addObject:@""];
    [lines addObject:@"[video]"];
    [lines addObject:setting];
  } else if (keyLine >= 0) {
    lines[keyLine] = setting;
  } else {
    [lines insertObject:setting atIndex:MIN(nextSection, (NSInteger)lines.count)];
  }
  NSString* updated = [lines componentsJoinedByString:@"\n"];
  if (![updated hasSuffix:@"\n"]) updated = [updated stringByAppendingString:@"\n"];
  return [updated writeToFile:path atomically:YES
                      encoding:NSUTF8StringEncoding error:error];
}

dispatch_queue_t KartPadSettingsIOQueue() {
  static dispatch_queue_t queue;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    queue = dispatch_queue_create(
        "com.neostation.kartpad.settings-io", DISPATCH_QUEUE_SERIAL);
  });
  return queue;
}

UIMenu* BuildNeoKartPadSettingsMenu();
void PatchKartPadRuntimeMenuButton(UIButton* menuButton);

void RefreshSettingsMenu() {
  // Never replace a UIMenu while UIKit is dismissing that same menu. The old
  // implementation did this synchronously from UIAction handlers, which could
  // leave context-menu transitions focused/frozen on physical devices.
  dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)),
      dispatch_get_main_queue(), ^{
    if (settingsButton) settingsButton.menu = BuildNeoKartPadSettingsMenu();
  });
}

void ScheduleNativeMenuRefresh(UIButton* button) {
  if (!button) return;
  const uint64_t generation =
      kNeoKartPadMenuRefreshGeneration.fetch_add(1, std::memory_order_acq_rel) + 1;
  __weak UIButton* weakButton = button;
  dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)),
      dispatch_get_main_queue(), ^{
    if (generation !=
        kNeoKartPadMenuRefreshGeneration.load(std::memory_order_acquire)) {
      return;
    }
    UIButton* strongButton = weakButton;
    if (!strongButton) return;
    objc_setAssociatedObject(
        strongButton, &kNeoKartPadPatchedMenuKey, nil,
        OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    PatchKartPadRuntimeMenuButton(strongButton);
  });
}

bool SetRuntimeLanguageOverride(NSInteger language) {
  if (!runtimeHandle || language < 1 || language > 6) return false;

  // patch_donor_language_bridge.py makes the donor's translated
  // func_801B1D0C (SCGetLanguage) load one byte from the alignment slot
  // immediately after g_dynamicAspectRatioEnabled. Resolve the anchor through
  // dyld so this remains ASLR-safe and never guesses a process address.
  void* aspect = dlsym(runtimeHandle, "g_dynamicAspectRatioEnabled");
  if (!aspect) {
    NSLog(@"[NeoKartPad/Language] host language anchor is unavailable: %s",
          dlerror() ?: "unknown dlsym error");
    return false;
  }
  auto* slot = reinterpret_cast<volatile uint8_t*>(aspect) + 1;
  *slot = static_cast<uint8_t>(language);
  NSLog(@"[NeoKartPad/Language] live SCGetLanguage override=%ld", (long)language);
  return true;
}

using KartPadGuestCpuFn = void (*)(void*);
using KartPadGetCpuFn = void* (*)(void);
using KartPadGuestRead32Fn = uint32_t (*)(uint32_t);

bool InvokeKartPadGuestPreservingCpu(
    void* cpu, KartPadGuestCpuFn fn,
    uint32_t r3, uint32_t r4, uint32_t r5,
    uint32_t* resultR3 = nullptr) {
  if (!cpu || !fn) return false;

  // The pinned WiiCompiled runtime has static_assert(sizeof(CpuContext) == 464).
  // The frame gate calls this only after onEndFrame returns. Preserve every
  // translated register; only the requested guest-side transition survives.
  alignas(16) uint8_t snapshot[464];
  std::memcpy(snapshot, cpu, sizeof(snapshot));
  auto* gpr = static_cast<uint32_t*>(cpu);
  gpr[3] = r3;
  gpr[4] = r4;
  gpr[5] = r5;
  try {
    fn(cpu);
    if (resultR3) *resultR3 = gpr[3];
  } catch (...) {
    std::memcpy(cpu, snapshot, sizeof(snapshot));
    NSLog(@"[NeoKartPad/Language] translated guest helper threw unexpectedly.");
    return false;
  }
  std::memcpy(cpu, snapshot, sizeof(snapshot));
  return true;
}

#include "DonorSessionControl.inc"

void QueueVideoSetting(
    NSString* key, NSString* value, void (^onChange)(void)) {
  bool expected = false;
  if (!kNeoKartPadMenuActionInFlight.compare_exchange_strong(
          expected, true, std::memory_order_acq_rel)) {
    return;
  }
  dispatch_async(KartPadSettingsIOQueue(), ^{
    NSError* error = nil;
    const bool ok = WriteVideoSetting(key, value, &error);
    dispatch_async(dispatch_get_main_queue(), ^{
      if (!ok) {
        NSLog(@"[NeoKartPad/Settings] video setting %@ write failed: %@", key, error);
      } else if (onChange) {
        onChange();
      }
      RefreshSettingsMenu();
      dispatch_after(
          dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)),
          dispatch_get_main_queue(), ^{
        kNeoKartPadMenuActionInFlight.store(false, std::memory_order_release);
      });
    });
  });
}

void ApplyNeoStationKartPadInputPolicy() {
  [NSUserDefaults.standardUserDefaults setBool:NO
                                       forKey:kKartPadAutoAccelerateKey];
}


UIMenu* BuildGameLanguageMenu(void (^onChange)(void)) {
  NSArray<NSNumber*>* languages = @[@1, @2, @3, @4, @5, @6];
  NSArray<NSString*>* languageKeys = @[
    @"languageEnglish", @"languageGerman", @"languageFrench",
    @"languageSpanish", @"languageItalian", @"languageDutch"
  ];
  NSArray<NSString*>* languageFallbacks = @[
    @"English", @"German", @"French", @"Spanish", @"Italian", @"Dutch"
  ];
  const NSInteger currentLanguage = CurrentGameLanguage();
  const NSUInteger currentLanguageIndex =
      currentLanguage >= 1 && currentLanguage <= 6
          ? static_cast<NSUInteger>(currentLanguage - 1)
          : 0;
  NSString* currentLanguageName =
      UIText(languageFallbacks[currentLanguageIndex],
             languageKeys[currentLanguageIndex].UTF8String);
  NSMutableArray<UIMenuElement*>* languageItems = [NSMutableArray array];
  for (NSUInteger index = 0; index < languages.count; ++index) {
    const NSInteger value = languages[index].integerValue;
    UIAction* action = [UIAction actionWithTitle:
        UIText(languageFallbacks[index], languageKeys[index].UTF8String)
        image:nil identifier:nil handler:^(__kindof UIAction*) {
      ConfirmGameLanguage(value, onChange);
    }];
    action.state =
        currentLanguage == value ? UIMenuElementStateOn : UIMenuElementStateOff;
    [languageItems addObject:action];
  }

  NSString* title = [NSString stringWithFormat:@"%@ — %@",
      UIText(@"Game Language", "gameLanguage"), currentLanguageName];
  return [UIMenu menuWithTitle:title
                         image:[UIImage systemImageNamed:@"globe"]
                    identifier:kNeoKartPadRuntimeLanguageMenuIdentifier
                       options:0
                      children:languageItems];
}

UIAction* BuildReturnToNeoStationAction() {
  return [UIAction actionWithTitle:UIText(@"Return to NeoStation", "returnToLibrary")
      image:[UIImage systemImageNamed:@"arrow.uturn.backward.circle.fill"]
      identifier:@"com.neostation.kartpad.return-to-neostation"
      handler:^(__kindof UIAction*) { ReturnToNeoStation(); }];
}

UIMenu* BuildNeoKartPadSettingsMenu() {
  NSUserDefaults* defaults = NSUserDefaults.standardUserDefaults;

  UIAction* returnToGameAction = [UIAction actionWithTitle:
      UIText(@"Return to Game", "returnToGame")
      image:[UIImage systemImageNamed:@"play.fill"] identifier:nil
      handler:^(__kindof UIAction*) {}];

  UIMenu* languageMenu = BuildGameLanguageMenu(nil);

  NSInteger renderScale = [defaults integerForKey:@"SunPadRenderScale"];
  if (renderScale < 1 || renderScale > 4) renderScale = 1;
  NSMutableArray<UIMenuElement*>* resolutionItems = [NSMutableArray array];
  for (NSInteger scale = 1; scale <= 4; ++scale) {
    NSString* title = [NSString stringWithFormat:@"%ld×", (long)scale];
    UIAction* action = [UIAction actionWithTitle:title image:nil identifier:nil
        handler:^(__kindof UIAction*) {
      PersistInteger(@"SunPadRenderScale", scale);
      RefreshSettingsMenu();
    }];
    action.state = renderScale == scale ? UIMenuElementStateOn : UIMenuElementStateOff;
    [resolutionItems addObject:action];
  }
  UIMenu* resolutionMenu = [UIMenu menuWithTitle:
      UIText(@"Render Resolution", "renderResolution")
      image:[UIImage systemImageNamed:@"sparkles.rectangle.stack"]
      identifier:@"com.neostation.kartpad.resolution" options:0
      children:resolutionItems];

  NSInteger aspect = [defaults integerForKey:@"SunPadAspectRatioMode"];
  if (aspect < 0 || aspect > 2) aspect = 0;
  NSArray<NSString*>* aspectKeys =
      @[@"aspectOriginal", @"aspectWidescreen", @"aspectFill"];
  NSArray<NSString*>* aspectFallbacks = @[@"4:3", @"16:9", @"Fill Screen"];
  NSMutableArray<UIMenuElement*>* aspectItems = [NSMutableArray array];
  for (NSInteger mode = 0; mode < 3; ++mode) {
    UIAction* action = [UIAction actionWithTitle:
        UIText(aspectFallbacks[mode], aspectKeys[mode].UTF8String)
        image:nil identifier:nil handler:^(__kindof UIAction*) {
      PersistInteger(@"SunPadAspectRatioMode", mode);
      RefreshSettingsMenu();
    }];
    action.state = aspect == mode ? UIMenuElementStateOn : UIMenuElementStateOff;
    [aspectItems addObject:action];
  }
  UIMenu* aspectMenu = [UIMenu menuWithTitle:
      UIText(@"Aspect Ratio", "aspectRatio")
      image:[UIImage systemImageNamed:@"rectangle.arrowtriangle.2.outward"]
      identifier:@"com.neostation.kartpad.aspect" options:0
      children:aspectItems];

  BOOL fps = [defaults boolForKey:@"SunPadShowFPSCounter"];
  UIAction* fpsAction = [UIAction actionWithTitle:
      UIText(@"Show FPS Counter", "fpsCounter")
      image:[UIImage systemImageNamed:@"speedometer"] identifier:nil
      handler:^(__kindof UIAction*) {
    PersistBool(@"SunPadShowFPSCounter",
                ![NSUserDefaults.standardUserDefaults boolForKey:@"SunPadShowFPSCounter"]);
    RefreshSettingsMenu();
  }];
  fpsAction.state = fps ? UIMenuElementStateOn : UIMenuElementStateOff;

  UIMenu* graphicsMenu = [UIMenu menuWithTitle:
      UIText(@"Graphics", "graphics")
      image:[UIImage systemImageNamed:@"display"]
      identifier:@"com.neostation.kartpad.graphics" options:0
      children:@[resolutionMenu, aspectMenu, fpsAction]];

  UIAction* hint = [UIAction actionWithTitle:
      UIText(@"Restart NeoStation to apply language and graphics changes.",
             "settingsRestartHint")
      image:[UIImage systemImageNamed:@"info.circle"] identifier:nil
      handler:^(__kindof UIAction*) {}];
  hint.attributes = UIMenuElementAttributesDisabled;

  return [UIMenu menuWithTitle:UIText(@"KartPad Settings", "settings")
                         image:[UIImage systemImageNamed:@"gearshape"]
                    identifier:@"com.neostation.kartpad.settings"
                       options:0
                      children:@[returnToGameAction, BuildReturnToNeoStationAction(), languageMenu, graphicsMenu, hint]];
}

UIMenu* BuildAdvancedGraphicsMenu(void (^onChange)(void)) {
  const BOOL sharperPicture = ReadVideoBool(@"disable_copy_filter", YES);
  const BOOL skipShaders = ReadVideoBool(@"skip_unready_pipelines", YES);
  const NSInteger postMask =
      ReadVideoInteger(@"disabled_post_processing_paths", 0);
  const BOOL disableBloom = (postMask & 0x10) != 0;
  const NSInteger interpolation =
      ReadVideoInteger(@"frame_interpolation_fps", 0);

  UIAction* sharp = [UIAction actionWithTitle:
      UIText(@"Sharper picture", "sharperPicture")
      image:[UIImage systemImageNamed:@"wand.and.stars"] identifier:nil
      handler:^(__kindof UIAction*) {
    QueueVideoSetting(
        @"disable_copy_filter", sharperPicture ? @"false" : @"true", onChange);
  }];
  sharp.state = sharperPicture ? UIMenuElementStateOn : UIMenuElementStateOff;

  UIAction* bloom = [UIAction actionWithTitle:
      UIText(@"Disable bloom", "disableBloom")
      image:[UIImage systemImageNamed:@"sun.max"] identifier:nil
      handler:^(__kindof UIAction*) {
    const NSInteger next =
        disableBloom ? (postMask & ~0x10) : (postMask | 0x10);
    QueueVideoSetting(
        @"disabled_post_processing_paths",
        [NSString stringWithFormat:@"%ld", (long)next], onChange);
  }];
  bloom.state = disableBloom ? UIMenuElementStateOn : UIMenuElementStateOff;

  UIAction* skip = [UIAction actionWithTitle:
      UIText(@"Skip draws while shaders compile", "skipShaders")
      image:[UIImage systemImageNamed:@"bolt"] identifier:nil
      handler:^(__kindof UIAction*) {
    QueueVideoSetting(
        @"skip_unready_pipelines", skipShaders ? @"false" : @"true", onChange);
  }];
  skip.state = skipShaders ? UIMenuElementStateOn : UIMenuElementStateOff;

  NSArray<NSNumber*>* interpolationValues = @[@0, @120, @180];
  NSArray<NSString*>* interpolationKeys = @[
    @"frameInterpolationOff", @"frameInterpolation120", @"frameInterpolation180"
  ];
  NSArray<NSString*>* interpolationFallbacks = @[
    @"Off (60 FPS)", @"120 FPS (experimental)", @"180 FPS (experimental)"
  ];
  NSMutableArray<UIMenuElement*>* interpolationItems = [NSMutableArray array];
  for (NSUInteger index = 0; index < interpolationValues.count; ++index) {
    const NSInteger value = interpolationValues[index].integerValue;
    UIAction* action = [UIAction actionWithTitle:
        UIText(interpolationFallbacks[index],
               interpolationKeys[index].UTF8String)
        image:nil identifier:nil handler:^(__kindof UIAction*) {
      QueueVideoSetting(
          @"frame_interpolation_fps",
          [NSString stringWithFormat:@"%ld", (long)value], onChange);
    }];
    action.state =
        interpolation == value ? UIMenuElementStateOn : UIMenuElementStateOff;
    [interpolationItems addObject:action];
  }
  UIMenu* frameInterpolation = [UIMenu menuWithTitle:
      UIText(@"Frame interpolation", "frameInterpolation")
      image:[UIImage systemImageNamed:@"square.stack.3d.up"]
      identifier:@"com.neostation.kartpad.frame-interpolation"
      options:0 children:interpolationItems];

  return [UIMenu menuWithTitle:UIText(@"Advanced graphics", "advancedGraphics")
                         image:[UIImage systemImageNamed:@"slider.horizontal.3"]
                    identifier:kNeoKartPadAdvancedGraphicsMenuIdentifier
                       options:0
                      children:@[sharp, bloom, skip, frameInterpolation]];
}

UIButton* FindButtonWithAccessibilityLabel(UIView* root, NSString* label) {
  if ([root isKindOfClass:UIButton.class] &&
      [root.accessibilityLabel isEqualToString:label]) {
    return (UIButton*)root;
  }
  for (UIView* child in root.subviews) {
    UIButton* found = FindButtonWithAccessibilityLabel(child, label);
    if (found) return found;
  }
  return nil;
}

void PatchKartPadRuntimeMenuButton(UIButton* menuButton) {
  if (!menuButton || !menuButton.menu) return;

  // layoutSubviews can run every frame. An already patched immutable UIMenu is
  // therefore an O(1) no-op: no plist reads, no tree walk, no allocation.
  UIMenu* lastPatched =
      objc_getAssociatedObject(menuButton, &kNeoKartPadPatchedMenuKey);
  if (lastPatched && menuButton.menu == lastPatched) return;

  bool expected = false;
  if (!kNeoKartPadMenuPatchInProgress.compare_exchange_strong(
          expected, true, std::memory_order_acq_rel)) {
    return;
  }

  UIMenu* source = menuButton.menu;
  __weak UIButton* weakButton = menuButton;
  UIAction* returnToGame = [UIAction
      actionWithTitle:UIText(@"Return to Game", "returnToGame")
      image:[UIImage systemImageNamed:@"play.fill"]
      identifier:kNeoKartPadReturnToGameIdentifier
      handler:^(__kindof UIAction*) {
    // Selecting a UIMenu action dismisses the menu. Do not rebuild or present
    // anything from this handler; simply clear transient UIKit button state on
    // the next run-loop turn so gameplay input resumes immediately.
    dispatch_async(dispatch_get_main_queue(), ^{
      UIButton* strongButton = weakButton;
      if (!strongButton) return;
      strongButton.selected = NO;
      strongButton.highlighted = NO;
    });
  }];
  UIMenu* languageMenu = BuildGameLanguageMenu(^{
    ScheduleNativeMenuRefresh(weakButton);
  });
  UIMenu* advancedMenu = BuildAdvancedGraphicsMenu(^{
    ScheduleNativeMenuRefresh(weakButton);
  });

  NSMutableArray<UIMenuElement*>* children = [NSMutableArray array];
  BOOL foundDisplay = NO;
  for (UIMenuElement* child in source.children) {
    if ([child isKindOfClass:UIAction.class]) {
      NSString* identifier = ((UIAction*)child).identifier;
      if ([identifier isEqualToString:@"dev.kartpad.main-menu"] ||
          [identifier isEqualToString:@"com.neostation.kartpad.return-to-neostation"]) continue;
    }
    if ([child isKindOfClass:UIAction.class]) {
      UIAction* action = (UIAction*)child;
      if ([action.identifier isEqualToString:kNeoKartPadReturnToGameIdentifier]) {
        continue;
      }
    }
    if ([child isKindOfClass:UIMenu.class]) {
      UIMenu* menu = (UIMenu*)child;

      // Strip every previous NeoStation injection before rebuilding. This
      // prevents nested copies after KartPad refreshMenuButton/backgrounding.
      if ([menu.identifier isEqualToString:kNeoKartPadRuntimeLanguageMenuIdentifier] ||
          [menu.identifier isEqualToString:kNeoKartPadAdvancedGraphicsMenuIdentifier]) {
        continue;
      }

      if ([menu.identifier isEqualToString:@"dev.kartpad.display"]) {
        foundDisplay = YES;
        NSMutableArray<UIMenuElement*>* displayChildren = [NSMutableArray array];
        for (UIMenuElement* item in menu.children) {
          if ([item isKindOfClass:UIMenu.class]) {
            UIMenu* submenu = (UIMenu*)item;
            if ([submenu.identifier
                    isEqualToString:kNeoKartPadRuntimeLanguageMenuIdentifier] ||
                [submenu.identifier
                    isEqualToString:kNeoKartPadAdvancedGraphicsMenuIdentifier]) {
              continue;
            }
          }
          [displayChildren addObject:item];
        }
        [displayChildren insertObject:advancedMenu atIndex:0];
        [children addObject:[menu menuByReplacingChildren:displayChildren]];
        continue;
      }
    }
    [children addObject:child];
  }

  // Always expose an explicit translated Return to Game at the very top of
  // KartPad's native three-dot menu. It is a pure dismissal action and therefore
  // cannot recursively rebuild the menu or block guest execution.
  [children insertObject:returnToGame atIndex:0];

  // This action terminates the embedded session, never the standalone menu.
  [children insertObject:BuildReturnToNeoStationAction() atIndex:1];
  NSUInteger languageIndex = 2;
  [children insertObject:languageMenu
                 atIndex:MIN(languageIndex, children.count)];
  if (!foundDisplay) {
    [children insertObject:advancedMenu
                   atIndex:MIN(languageIndex + 1, children.count)];
  }

  UIMenu* patched = [source menuByReplacingChildren:children];
  menuButton.menu = patched;
  menuButton.showsMenuAsPrimaryAction = YES;
  objc_setAssociatedObject(
      menuButton, &kNeoKartPadPatchedMenuKey, patched,
      OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  kNeoKartPadMenuPatchInProgress.store(false, std::memory_order_release);
}

using OverlayLayoutSubviewsFn = void (*)(id, SEL);
OverlayLayoutSubviewsFn originalKartPadOverlayLayoutSubviews = nullptr;

void NeoStationKartPadOverlayLayoutSubviews(id receiver, SEL selector) {
  if (originalKartPadOverlayLayoutSubviews) {
    originalKartPadOverlayLayoutSubviews(receiver, selector);
  }
  if (![receiver isKindOfClass:UIView.class]) return;
  UIButton* menuButton =
      FindButtonWithAccessibilityLabel((UIView*)receiver, @"Menu");
  if (!menuButton) return;
  UIMenu* patched =
      objc_getAssociatedObject(menuButton, &kNeoKartPadPatchedMenuKey);
  if (patched && menuButton.menu == patched) return;
  PatchKartPadRuntimeMenuButton(menuButton);
}

using AutoAccelerateChangedFn = void (*)(id, SEL, UISwitch*);
AutoAccelerateChangedFn originalKartPadAutoAccelerateChanged = nullptr;

void NeoStationKartPadAutoAccelerateChanged(
    id receiver, SEL selector, UISwitch* sender) {
  ApplyNeoStationKartPadInputPolicy();
  if (sender) sender.on = NO;
  if (originalKartPadAutoAccelerateChanged) {
    originalKartPadAutoAccelerateChanged(receiver, selector, sender);
  }
  NSLog(@"[NeoKartPad/Input] auto-accelerate lock forced off to prevent stuck A.");
}

using ViewDidLoadFn = void (*)(id, SEL);
ViewDidLoadFn originalKartPadFirstLaunchViewDidLoad = nullptr;

void UpdateKartPadFirstLaunchPreference(id receiver) {
  [NSUserDefaults.standardUserDefaults setObject:@"base"
                                         forKey:kKartPadPreferredGameKey];
  [NSUserDefaults.standardUserDefaults synchronize];
  SEL update = NSSelectorFromString(@"updatePreferenceTitle");
  if ([receiver respondsToSelector:update]) {
    ((void (*)(id, SEL))objc_msgSend)(receiver, update);
  }
}

void NeoStationKartPadFirstLaunchViewDidLoad(id receiver, SEL selector) {
  if (originalKartPadFirstLaunchViewDidLoad) {
    originalKartPadFirstLaunchViewDidLoad(receiver, selector);
  }
  UpdateKartPadFirstLaunchPreference(receiver);
  @try {
    id rawButton = [receiver valueForKey:@"preferenceButton"];
    if ([rawButton isKindOfClass:UIButton.class]) {
      UIButton* button = (UIButton*)rawButton;
      button.enabled = NO;
      button.userInteractionEnabled = NO;
      button.accessibilityHint =
          @"NeoStation manages Mario Kart Wii directly.";
    }
  } @catch (NSException* exception) {
    NSLog(@"[NeoKartPad/Donor] could not disable On Launch control: %@",
          exception.reason);
  }
}

void NeoStationKartPadShowLaunchPreference(id receiver, SEL selector) {
  (void)selector;
  UpdateKartPadFirstLaunchPreference(receiver);
  NSLog(@"[NeoKartPad/Donor] ignored KartPad On Launch chooser; NeoStation owns RMCP01.");
}

bool EnsureSymlink(NSString* linkPath, NSString* targetPath, NSError** error) {
  NSFileManager* files = NSFileManager.defaultManager;
  NSString* current = [files destinationOfSymbolicLinkAtPath:linkPath error:nil];
  if ([current isEqualToString:targetPath]) return true;
  if (current != nil || [files fileExistsAtPath:linkPath]) {
    if (![files removeItemAtPath:linkPath error:error]) return false;
  }
  return [files createSymbolicLinkAtPath:linkPath
                     withDestinationPath:targetPath
                                   error:error];
}

bool PrepareRuntimeStorage(char* error, size_t errorSize) {
  NSFileManager* files = NSFileManager.defaultManager;
  NSString* support = [NSString stringWithUTF8String:supportPath.c_str()];
  NSString* defaultRoot =
      [[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support"]
          stringByAppendingPathComponent:@"KartPad"];
  NSError* failure = nil;
  if (![files createDirectoryAtPath:defaultRoot withIntermediateDirectories:YES
                         attributes:nil error:&failure]) {
    return Fail(error, errorSize, failure.localizedDescription.UTF8String);
  }
  NSArray<NSArray<NSString*>*>* mappings = @[
    @[[defaultRoot stringByAppendingPathComponent:@"NAND"],
      [support stringByAppendingPathComponent:@"Saves/NAND"]],
    @[[defaultRoot stringByAppendingPathComponent:@"Config.toml"],
      [support stringByAppendingPathComponent:@"Config/Config.toml"]],
    @[[defaultRoot stringByAppendingPathComponent:@"Logs"],
      [support stringByAppendingPathComponent:@"Logs"]],
    @[[defaultRoot stringByAppendingPathComponent:@"texture_replacements"],
      [support stringByAppendingPathComponent:@"Mods/texture_replacements"]],
    @[[defaultRoot stringByAppendingPathComponent:@"GameData"],
      [support stringByAppendingPathComponent:@"Runtime/GameData"]],
  ];
  for (NSArray<NSString*>* pair in mappings) {
    NSString* target = pair[1];
    NSString* parent = target.stringByDeletingLastPathComponent;
    if (![files createDirectoryAtPath:parent withIntermediateDirectories:YES
                           attributes:nil error:&failure]) {
      return Fail(error, errorSize, failure.localizedDescription.UTF8String);
    }
    if (!EnsureSymlink(pair[0], target, &failure)) {
      return Fail(error, errorSize, failure.localizedDescription.UTF8String);
    }
  }

  NSString* defaultCache =
      [[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Caches"]
          stringByAppendingPathComponent:@"KartPad"];
  NSString* cacheParent = defaultCache.stringByDeletingLastPathComponent;
  if (![files createDirectoryAtPath:cacheParent
        withIntermediateDirectories:YES attributes:nil error:&failure]) {
    const std::string detail =
        "KartPad cache parent could not be prepared: " +
        std::string(failure.localizedDescription.UTF8String ?: "unknown error");
    return Fail(error, errorSize, detail.c_str());
  }

  // Build 328 still reproduced the same Foundation EEXIST-style failure on
  // device. Do not rely on NSFileManager's high-level symlink queries here:
  // a dangling link can be reported as a missing item by fileExistsAtPath,
  // while mkdir then fails because the directory entry still exists.
  //
  // lstat observes the directory entry itself. Remove only a stale symlink or
  // a non-directory object named Library/Caches/KartPad, preserve a real cache
  // directory, and recreate the canonical directory only when it truly does
  // not exist.
  const char* cacheFs = defaultCache.fileSystemRepresentation;
  struct stat cacheStat {};
  if (::lstat(cacheFs, &cacheStat) == 0) {
    if (S_ISLNK(cacheStat.st_mode)) {
      if (::unlink(cacheFs) != 0) {
        const std::string detail =
            "KartPad stale cache symlink could not be removed: " +
            std::string(std::strerror(errno));
        return Fail(error, errorSize, detail.c_str());
      }
      NSLog(@"[NeoKartPad/Donor] removed stale cache symlink at %@", defaultCache);
    } else if (!S_ISDIR(cacheStat.st_mode)) {
      if (![files removeItemAtPath:defaultCache error:&failure]) {
        const std::string detail =
            "KartPad cache path is not a directory and could not be removed: " +
            std::string(failure.localizedDescription.UTF8String ?: "unknown error");
        return Fail(error, errorSize, detail.c_str());
      }
      NSLog(@"[NeoKartPad/Donor] removed non-directory cache object at %@", defaultCache);
    }
  } else if (errno != ENOENT) {
    const std::string detail =
        "KartPad cache path could not be inspected: " +
        std::string(std::strerror(errno));
    return Fail(error, errorSize, detail.c_str());
  }

  if (::lstat(cacheFs, &cacheStat) != 0) {
    if (errno != ENOENT) {
      const std::string detail =
          "KartPad cache path could not be rechecked: " +
          std::string(std::strerror(errno));
      return Fail(error, errorSize, detail.c_str());
    }
    failure = nil;
    if (![files createDirectoryAtPath:defaultCache
          withIntermediateDirectories:YES attributes:nil error:&failure]) {
      const std::string detail =
          "KartPad canonical cache directory could not be created: " +
          std::string(failure.localizedDescription.UTF8String ?: "unknown error");
      return Fail(error, errorSize, detail.c_str());
    }
  } else if (!S_ISDIR(cacheStat.st_mode)) {
    return Fail(error, errorSize,
                "KartPad cache path still exists but is not a directory.");
  }

  // Verify actual write access now, before loading the donor runtime. This
  // turns any remaining sandbox/path problem into a precise error rather than
  // the generic Foundation 'couldn't be saved in Caches' message.
  NSString* probe =
      [defaultCache stringByAppendingPathComponent:@".neostation-kartpad-probe"];
  NSData* probeData = [@"ok" dataUsingEncoding:NSUTF8StringEncoding];
  failure = nil;
  if (![probeData writeToFile:probe options:NSDataWritingAtomic error:&failure]) {
    const std::string detail =
        "KartPad canonical cache is not writable: " +
        std::string(failure.localizedDescription.UTF8String ?: "unknown error");
    return Fail(error, errorSize, detail.c_str());
  }
  [files removeItemAtPath:probe error:nil];

  cachePath = defaultCache.fileSystemRepresentation;
  NSLog(@"[NeoKartPad/Donor] canonical cache verified writable at %@", defaultCache);
  if (!WriteGameLanguageSysConf(&failure)) {
    return Fail(error, errorSize, failure.localizedDescription.UTF8String);
  }
  return true;
}

bool LoadRuntime(char* error, size_t errorSize);

bool PrepareUserGameDiscovery(char* error, size_t errorSize) {
  NSString* source = [NSString stringWithUTF8String:gamePath.c_str()];
  NSString* documents = NSSearchPathForDirectoriesInDomains(
      NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
  if (documents.length == 0) {
    return Fail(error, errorSize, "NeoStation Documents directory is unavailable.");
  }
  NSString* extension = source.pathExtension.lowercaseString;
  NSString* link = [documents stringByAppendingPathComponent:
      [NSString stringWithFormat:@"NeoStation-Mario-Kart-Wii.%@", extension]];
  NSError* failure = nil;
  if (!EnsureSymlink(link, source, &failure)) {
    return Fail(error, errorSize, failure.localizedDescription.UTF8String);
  }
  return true;
}

bool EmbeddedPreparedGameDataReady() {
  if (supportPath.empty()) return false;
  NSString* support = [NSString stringWithUTF8String:supportPath.c_str()];
  NSString* root = [support stringByAppendingPathComponent:@"Runtime/GameData"];
  NSFileManager* files = NSFileManager.defaultManager;
  NSArray<NSString*>* required = @[
    @"sys/boot.bin", @"sys/bi2.bin", @"sys/apploader.img", @"sys/fst.bin",
    @"sys/main.dol", @"files/rel/StaticR.rel",
  ];
  for (NSString* relative in required) {
    if (![files isReadableFileAtPath:[root stringByAppendingPathComponent:relative]]) {
      return false;
    }
  }

  NSData* boot = [NSData dataWithContentsOfFile:
      [root stringByAppendingPathComponent:@"sys/boot.bin"] options:0 error:nil];
  if (boot.length < 0x20) return false;
  const uint8_t* bytes = static_cast<const uint8_t*>(boot.bytes);
  return memcmp(bytes, "RMCP01", 6) == 0 && bytes[6] == 0 && bytes[7] == 0;
}

bool EnsureEmbeddedDvdRootConfig(char* error, size_t errorSize) {
  if (supportPath.empty()) {
    return Fail(error, errorSize, "KartPad support directory is unavailable.");
  }
  NSString* support = [NSString stringWithUTF8String:supportPath.c_str()];
  NSString* configPath = [support stringByAppendingPathComponent:@"Config/Config.toml"];
  NSFileManager* files = NSFileManager.defaultManager;
  NSError* failure = nil;
  if (![files createDirectoryAtPath:configPath.stringByDeletingLastPathComponent
        withIntermediateDirectories:YES attributes:nil error:&failure]) {
    return Fail(error, errorSize, failure.localizedDescription.UTF8String);
  }

  NSString* config = [NSString stringWithContentsOfFile:configPath
                                                encoding:NSUTF8StringEncoding
                                                   error:&failure];
  if (config == nil) {
    if ([files fileExistsAtPath:configPath]) {
      return Fail(error, errorSize,
                  (failure.localizedDescription ?: @"KartPad Config.toml is unreadable.")
                      .UTF8String);
    }
    config = @"";
    failure = nil;
  }

  NSRegularExpression* dvdLine = [NSRegularExpression
      regularExpressionWithPattern:@"(?m)^\\s*#?\\s*dvd_root\\s*=.*$"
                           options:0 error:&failure];
  if (!dvdLine) {
    return Fail(error, errorSize, failure.localizedDescription.UTF8String);
  }
  config = [dvdLine stringByReplacingMatchesInString:config options:0
      range:NSMakeRange(0, config.length) withTemplate:@""];

  NSRegularExpression* paths = [NSRegularExpression
      regularExpressionWithPattern:@"(?m)^\\s*\\[paths\\]\\s*$"
                           options:0 error:&failure];
  if (!paths) {
    return Fail(error, errorSize, failure.localizedDescription.UTF8String);
  }
  NSTextCheckingResult* match =
      [paths firstMatchInString:config options:0 range:NSMakeRange(0, config.length)];
  if (match) {
    const NSUInteger insertion = NSMaxRange(match.range);
    config = [config stringByReplacingCharactersInRange:NSMakeRange(insertion, 0)
                                              withString:@"\ndvd_root = \"GameData\""];
  } else {
    config = [config stringByAppendingString:
        @"\n\n[paths]\ndvd_root = \"GameData\"\n"];
  }
  if (![config writeToFile:configPath atomically:YES
                  encoding:NSUTF8StringEncoding error:&failure]) {
    return Fail(error, errorSize,
                (failure.localizedDescription ?: @"KartPad Config.toml could not be updated.")
                    .UTF8String);
  }
  return true;
}

bool PrepareEmbeddedRuntimeBootstrap(char* error, size_t errorSize) {
  NSString* resources = NSBundle.mainBundle.resourcePath;
  if (resources.length == 0) {
    return Fail(error, errorSize, "NeoStation bundle resources are unavailable.");
  }

  NSFileManager* files = NSFileManager.defaultManager;
  NSArray<NSString*>* requiredResources = @[
    @"dsp_coef.bin",
    @"initial_pipeline_cache.db",
    @"wii_bootstrap/shared2/wc24/misc.bin",
  ];
  for (NSString* relative in requiredResources) {
    NSString* candidate = [resources stringByAppendingPathComponent:relative];
    if (![files isReadableFileAtPath:candidate]) {
      NSString* detail = [NSString stringWithFormat:
          @"KartPad runtime resource is missing: %@", relative];
      return Fail(error, errorSize, detail.UTF8String);
    }
  }

  // SDL's official iOS SceneDelegate performs this before calling RuntimeMain.
  // The embedded donor does not own UIApplication, so NeoStation must reproduce
  // that exact resource-root contract before the runtime or Aurora starts.
  if (![files changeCurrentDirectoryPath:resources]) {
    return Fail(error, errorSize,
                "KartPad could not switch to NeoStation's bundle resource directory.");
  }

  // NeoStation's Ports entry already selected the base game. Preserve the
  // donor's normal startup contract without exposing its standalone chooser.
  [NSUserDefaults.standardUserDefaults
      setObject:@"base" forKey:kKartPadRequestedRuntimeProfileKey];
  [NSUserDefaults.standardUserDefaults
      setObject:@"base" forKey:kKartPadPreferredGameKey];
  [NSUserDefaults.standardUserDefaults synchronize];

  if (EmbeddedPreparedGameDataReady() &&
      !EnsureEmbeddedDvdRootConfig(error, errorSize)) {
    return false;
  }

  NSLog(@"[NeoKartPad/Donor] SDL embedded bootstrap ready cwd=%@ preparedGame=%d",
        resources, EmbeddedPreparedGameDataReady() ? 1 : 0);
  return true;
}

bool EnsureDonorRuntimeLoadedOnMain(char* error, size_t errorSize) {
  if (NSThread.isMainThread) return LoadRuntime(error, errorSize);
  __block bool loaded = false;
  dispatch_sync(dispatch_get_main_queue(), ^{
    loaded = LoadRuntime(error, errorSize);
  });
  return loaded;
}

int PrepareCompressedGameData(const char* game,
                              const char* support,
                              const char* cache,
                              char* error,
                              size_t errorSize) {
  if (!game || !*game || !support || !*support || !cache || !*cache) {
    return Fail(error, errorSize, "KartPad RVZ preparation paths are incomplete.");
  }
  if (runtimeThreadActive.load(std::memory_order_acquire) || session.active()) {
    return Fail(error, errorSize, "KartPad cannot prepare RVZ while its runtime is active.");
  }
  supportPath = support;
  cachePath = cache;
  gamePath = game;
  if (!PrepareRuntimeStorage(error, errorSize)) return 0;
  if (!EnsureDonorRuntimeLoadedOnMain(error, errorSize)) return 0;

  Class extractor = NSClassFromString(@"KartPadDiscExtractor");
  SEL selector = NSSelectorFromString(
      @"extractImageAtPath:toDirectory:progress:error:");
  if (!extractor || ![extractor respondsToSelector:selector]) {
    return Fail(error, errorSize,
                "KartPad's DiscIO extractor is unavailable in the donor runtime.");
  }

  NSString* supportRoot = [NSString stringWithUTF8String:support];
  NSString* runtimeRoot = [supportRoot stringByAppendingPathComponent:@"Runtime"];
  NSString* finalPath = [runtimeRoot stringByAppendingPathComponent:@"GameData"];
  NSString* staging = [runtimeRoot stringByAppendingPathComponent:
      [NSString stringWithFormat:@"GameData.import-%@", NSUUID.UUID.UUIDString]];
  NSString* rollback = [runtimeRoot stringByAppendingPathComponent:
      [NSString stringWithFormat:@"GameData.rollback-%@", NSUUID.UUID.UUIDString]];
  NSFileManager* files = NSFileManager.defaultManager;
  NSError* failure = nil;
  [files createDirectoryAtPath:runtimeRoot withIntermediateDirectories:YES
                    attributes:nil error:&failure];
  if (failure) return Fail(error, errorSize, failure.localizedDescription.UTF8String);

  using ExtractFn =
      BOOL (*)(id, SEL, NSString*, NSString*, id, NSError**);
  IMP implementation = [extractor methodForSelector:selector];
  if (!implementation) {
    return Fail(error, errorSize, "KartPad DiscIO extractor entry point is missing.");
  }
  NSString* source = [NSString stringWithUTF8String:game];
  BOOL extracted =
      reinterpret_cast<ExtractFn>(implementation)(
          extractor, selector, source, staging, nil, &failure);
  if (!extracted || failure) {
    [files removeItemAtPath:staging error:nil];
    return Fail(error, errorSize,
                (failure.localizedDescription ?: @"KartPad could not extract this RVZ.")
                    .UTF8String);
  }

  BOOL movedExisting = NO;
  if ([files fileExistsAtPath:finalPath]) {
    movedExisting = [files moveItemAtPath:finalPath toPath:rollback error:&failure];
  }
  if (!failure) {
    [files moveItemAtPath:staging toPath:finalPath error:&failure];
  }
  if (failure) {
    [files removeItemAtPath:staging error:nil];
    if (movedExisting && ![files fileExistsAtPath:finalPath]) {
      [files moveItemAtPath:rollback toPath:finalPath error:nil];
    }
    return Fail(error, errorSize, failure.localizedDescription.UTF8String);
  }
  if (movedExisting) [files removeItemAtPath:rollback error:nil];
  if (!EnsureEmbeddedDvdRootConfig(error, errorSize)) return 0;
  NSLog(@"[NeoKartPad/Donor] Prepared RMCP01 game data from compressed image.");
  return 1;
}

using FirstLaunchRunFn = BOOL (*)(id, SEL);
FirstLaunchRunFn originalFirstLaunchRun = nullptr;

BOOL NeoStationFirstLaunchRun(id receiver, SEL selector) {
  if (EmbeddedPreparedGameDataReady()) {
    NSLog(@"[NeoKartPad/Donor] Skipping standalone KartPad chooser; NeoStation game data is ready.");
    return YES;
  }
  return originalFirstLaunchRun ? originalFirstLaunchRun(receiver, selector) : NO;
}

void InstallAutoImportSwizzle() {
  Class host = NSClassFromString(@"KartPadFirstLaunchHost");
  if (!host) return;

  Method run = class_getInstanceMethod(host, NSSelectorFromString(@"run"));
  if (run && !originalFirstLaunchRun) {
    originalFirstLaunchRun =
        reinterpret_cast<FirstLaunchRunFn>(method_getImplementation(run));
    method_setImplementation(run, reinterpret_cast<IMP>(NeoStationFirstLaunchRun));
  }

  Method show = class_getInstanceMethod(host, NSSelectorFromString(@"showOptions"));
  Method choose =
      class_getInstanceMethod(host, NSSelectorFromString(@"chooseDocumentsRoot"));
  if (show && choose) {
    method_setImplementation(show, method_getImplementation(choose));
  }

  Class chooser = NSClassFromString(@"KartPadFirstLaunchViewController");
  if (chooser) {
    Method viewDidLoad =
        class_getInstanceMethod(chooser, @selector(viewDidLoad));
    if (viewDidLoad && !originalKartPadFirstLaunchViewDidLoad) {
      originalKartPadFirstLaunchViewDidLoad =
          reinterpret_cast<ViewDidLoadFn>(method_getImplementation(viewDidLoad));
      method_setImplementation(
          viewDidLoad,
          reinterpret_cast<IMP>(NeoStationKartPadFirstLaunchViewDidLoad));
    }
    Method launchPreference = class_getInstanceMethod(
        chooser, NSSelectorFromString(@"showLaunchPreference"));
    if (launchPreference) {
      method_setImplementation(
          launchPreference,
          reinterpret_cast<IMP>(NeoStationKartPadShowLaunchPreference));
    }
  }

  Class overlay = NSClassFromString(@"KartPadGameOverlay");
  if (overlay) {
    Method autoAccelerate = class_getInstanceMethod(
        overlay, NSSelectorFromString(@"kartPadAutoAccelerateChanged:"));
    if (autoAccelerate && !originalKartPadAutoAccelerateChanged) {
      originalKartPadAutoAccelerateChanged =
          reinterpret_cast<AutoAccelerateChangedFn>(
              method_getImplementation(autoAccelerate));
      method_setImplementation(
          autoAccelerate,
          reinterpret_cast<IMP>(NeoStationKartPadAutoAccelerateChanged));
    }

    Method layout = class_getInstanceMethod(overlay, @selector(layoutSubviews));
    if (layout && !originalKartPadOverlayLayoutSubviews) {
      originalKartPadOverlayLayoutSubviews =
          reinterpret_cast<OverlayLayoutSubviewsFn>(
              method_getImplementation(layout));
      method_setImplementation(
          layout,
          reinterpret_cast<IMP>(NeoStationKartPadOverlayLayoutSubviews));
    }
  }

  [NSUserDefaults.standardUserDefaults setObject:@"base"
                                         forKey:kKartPadPreferredGameKey];
  ApplyNeoStationKartPadInputPolicy();
  NSLog(@"[NeoKartPad/Donor] Embedded first-launch, input and native menu policy installed.");
}

bool LoadRuntime(char* error, size_t errorSize) {
  if (runtimeHandle) return true;
  NSString* path = RuntimePath();
  runtimeHandle = dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
  if (!runtimeHandle) {
    return Fail(error, errorSize, dlerror() ?: "KartPad donor runtime could not load.");
  }
  runtimeMain = reinterpret_cast<RuntimeMainFn>(
      dlsym(runtimeHandle, "_Z11RuntimeMainiPPc"));
  sdlGetWindows = reinterpret_cast<SDLGetWindowsFn>(
      dlsym(runtimeHandle, "SDL_GetWindows"));
  sdlHideWindow = reinterpret_cast<SDLWindowVisibilityFn>(
      dlsym(runtimeHandle, "SDL_HideWindow"));
  sdlShowWindow = reinterpret_cast<SDLWindowVisibilityFn>(
      dlsym(runtimeHandle, "SDL_ShowWindow"));
  sdlFree = reinterpret_cast<SDLFreeFn>(dlsym(runtimeHandle, "SDL_free"));
  sdlSetMainReady = reinterpret_cast<SDLSetMainReadyFn>(
      dlsym(runtimeHandle, "SDL_SetMainReady"));
  sdlSetiOSEventPump = reinterpret_cast<SDLiOSEventPumpFn>(
      dlsym(runtimeHandle, "SDL_SetiOSEventPump"));
  sdlGetError = reinterpret_cast<SDLGetErrorFn>(
      dlsym(runtimeHandle, "SDL_GetError"));
  if (!runtimeMain || !sdlGetWindows || !sdlHideWindow || !sdlShowWindow ||
      !sdlSetMainReady || !sdlSetiOSEventPump || !sdlGetError) {
    return Fail(error, errorSize,
                "KartPad donor runtime is missing RuntimeMain or required SDL iOS exports.");
  }
  if (!BindSessionBridge(error, errorSize)) return false;
  if (!SetRuntimeLanguageOverride(CurrentGameLanguage())) {
    return Fail(error, errorSize,
                "KartPad donor runtime is missing the NeoStation language bridge.");
  }
  InstallAutoImportSwizzle();
  return true;
}

void ForEachSDLWindow(const std::function<void(SDL_Window*)>& action) {
  if (!sdlGetWindows) return;
  int count = 0;
  SDL_Window** windows = sdlGetWindows(&count);
  if (windows) {
    for (int i = 0; i < count; ++i) {
      if (windows[i]) action(windows[i]);
    }
    if (sdlFree) sdlFree(windows);
  }
}

UIWindow* CurrentDonorWindow() {
  for (UIScene* scene in UIApplication.sharedApplication.connectedScenes) {
    if (![scene isKindOfClass:UIWindowScene.class] ||
        scene.activationState != UISceneActivationStateForegroundActive) continue;
    for (UIWindow* window in ((UIWindowScene*)scene).windows) {
      if (window != neoStationWindow && !window.hidden && window.alpha > 0.01) {
        if (window.isKeyWindow) return window;
        donorWindow = window;
      }
    }
  }
  return donorWindow;
}

void ReturnToNeoStation();

void InstallReturnButton() {
  UIWindow* window = CurrentDonorWindow();
  if (!window || returnButton.superview) return;
  donorWindow = window;
  UIButton* button = [UIButton buttonWithType:UIButtonTypeSystem];
  button.translatesAutoresizingMaskIntoConstraints = NO;
  button.backgroundColor = [UIColor colorWithWhite:0.05 alpha:0.72];
  button.tintColor = UIColor.whiteColor;
  button.layer.cornerRadius = 12.0;
  button.contentEdgeInsets = UIEdgeInsetsMake(8, 12, 8, 12);
  [button setTitle:UIText(@"NeoStation", "returnToLibrary")
          forState:UIControlStateNormal];
  [button setImage:[UIImage systemImageNamed:@"arrow.uturn.backward.circle.fill"]
          forState:UIControlStateNormal];
  button.accessibilityLabel = UIText(@"Return to NeoStation", "returnToLibrary");
  UIAction* returnAction = [UIAction actionWithHandler:^(__kindof UIAction*) {
    ReturnToNeoStation();
  }];
  [button addAction:returnAction forControlEvents:UIControlEventTouchUpInside];
  UIView* root = window.rootViewController.view ?: window;
  [root addSubview:button];
  [NSLayoutConstraint activateConstraints:@[
    [button.topAnchor constraintEqualToAnchor:root.safeAreaLayoutGuide.topAnchor constant:8],
    [button.trailingAnchor constraintEqualToAnchor:root.safeAreaLayoutGuide.trailingAnchor constant:-8],
  ]];
  returnButton = button;

  UIButton* gear = [UIButton buttonWithType:UIButtonTypeSystem];
  gear.translatesAutoresizingMaskIntoConstraints = NO;
  gear.backgroundColor = [UIColor colorWithWhite:0.05 alpha:0.72];
  gear.tintColor = UIColor.whiteColor;
  gear.layer.cornerRadius = 12.0;
  gear.contentEdgeInsets = UIEdgeInsetsMake(8, 12, 8, 12);
  [gear setImage:[UIImage systemImageNamed:@"gearshape.fill"]
        forState:UIControlStateNormal];
  gear.accessibilityLabel = UIText(@"KartPad Settings", "settings");
  gear.showsMenuAsPrimaryAction = YES;
  gear.menu = BuildNeoKartPadSettingsMenu();
  [root addSubview:gear];
  [NSLayoutConstraint activateConstraints:@[
    [gear.topAnchor constraintEqualToAnchor:button.bottomAnchor constant:8],
    [gear.trailingAnchor constraintEqualToAnchor:button.trailingAnchor],
    [gear.widthAnchor constraintGreaterThanOrEqualToConstant:44],
    [gear.heightAnchor constraintGreaterThanOrEqualToConstant:44],
  ]];
  settingsButton = gear;
}

void PollForRuntimeWindow(int attempt) {
  if (session.state() != NEO_KARTPAD_STARTING) return;
  __block int count = 0;
  if (sdlGetWindows) {
    SDL_Window** windows = sdlGetWindows(&count);
    if (windows && sdlFree) sdlFree(windows);
  }
  if (count > 0 && CurrentDonorWindow()) {
    InstallReturnButton();
    if (session.firstFrame()) Emit("KartPad donor runtime window is ready.");
    return;
  }
  if (attempt >= 900) return;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC),
                 dispatch_get_main_queue(), ^{
    PollForRuntimeWindow(attempt + 1);
  });
}

void RuntimeMainOnUIKitThread() {
  if (!NSThread.isMainThread) {
    RunOnUIKitRunLoop(^{ RuntimeMainOnUIKitThread(); });
    return;
  }

  const uint64_t serial = sessionSerial.load(std::memory_order_acquire);
  runtimeThreadActive.store(true, std::memory_order_release);
  NSLog(@"[NeoKartPad/Lifecycle] session=%llu RuntimeMain begin",
        (unsigned long long)serial);

  // The official iOS executable enters RuntimeMain through SDL_RunApp.
  // NeoStation already owns UIApplication, so it must reproduce the parts of
  // SDL's iOS bootstrap that are safe inside an existing application.
  sdlSetMainReady();
  sdlSetiOSEventPump(true);

  char name[] = "KartPadRuntime";
  char* argv[] = {name, nullptr};
  const int result = runtimeMain ? runtimeMain(1, argv) : -1;

  const char* rawError = sdlGetError ? sdlGetError() : nullptr;
  const std::string runtimeError =
      rawError && *rawError ? std::string(rawError) : std::string();
  sdlSetiOSEventPump(false);
  runtimeThreadActive.store(false, std::memory_order_release);

  const bool orderly = orderlyRuntimeReturn && result == 0;
  const bool shouldRestart = orderly && restartAfterShutdown;
  const uint32_t pendingLanguage = restartLanguage;

  ReleaseTerminalGuestMemory();
  [returnButton removeFromSuperview];
  [settingsButton removeFromSuperview];
  returnButton = nil;
  settingsButton = nil;
  donorWindow = nil;
  if (ownedSessionAlert) {
    [ownedSessionAlert dismissViewControllerAnimated:NO completion:nil];
  }
  ownedSessionAlert = nil;

  if (orderly) {
    session.finishReusable();
    commands = neokartpad::SessionCommands{};
    frameGateEntered = false;
    orderlyRuntimeReturn = false;
    languageWrites.store(0, std::memory_order_release);
    languageWriteFailed = false;
    kNeoKartPadMenuActionInFlight.store(false, std::memory_order_release);
    kNeoKartPadMenuRefreshGeneration.fetch_add(1, std::memory_order_acq_rel);

    NSLog(@"[NeoKartPad/Lifecycle] session=%llu resources released; state=idle restart=%d",
          (unsigned long long)serial, shouldRestart);

    if (shouldRestart) {
      restartAfterShutdown = false;
      restartLanguage = 0;
      if (!SetRuntimeLanguageOverride(pendingLanguage)) {
        session.terminate();
        if (neoStationWindow) [neoStationWindow makeKeyAndVisible];
        Emit("KartPad language restart failed while preparing the fresh runtime.");
        return;
      }
      if (!session.reserve()) {
        session.terminate();
        if (neoStationWindow) [neoStationWindow makeKeyAndVisible];
        Emit("KartPad could not reserve a fresh restart session.");
        return;
      }
      session.runtimeReady();
      const uint64_t next = sessionSerial.fetch_add(1, std::memory_order_acq_rel) + 1;
      NSLog(@"[NeoKartPad/Lifecycle] session=%llu created from explicit language restart language=%u",
            (unsigned long long)next, pendingLanguage);
      RunOnUIKitRunLoop(^{
        RuntimeMainOnUIKitThread();
        PollForRuntimeWindow(0);
      });
      return;
    }

    restartAfterShutdown = false;
    restartLanguage = 0;
    if (neoStationWindow) [neoStationWindow makeKeyAndVisible];
    Emit("KartPad session closed after guest, audio and graphics shutdown.");
    return;
  }

  restartAfterShutdown = false;
  restartLanguage = 0;
  if (neoStationWindow) [neoStationWindow makeKeyAndVisible];
  if (session.state() != NEO_KARTPAD_ENDED) session.terminate();
  if (result == 0) {
    Emit("KartPad donor runtime exited unexpectedly.");
  } else if (!runtimeError.empty()) {
    const std::string message =
        "KartPad donor runtime failed before first frame: " + runtimeError;
    Emit(message.c_str());
  } else {
    Emit("KartPad donor runtime failed before first frame.");
  }
}

void ReturnToNeoStation() {
  if (!NSThread.isMainThread) {
    dispatch_async(dispatch_get_main_queue(), ^{ ReturnToNeoStation(); });
    return;
  }
  if (!session.active() || !commands.requestClose()) return;
  session.requestStop();
  kNeoKartPadMenuRefreshGeneration.fetch_add(1, std::memory_order_acq_rel);
  if (ownedSessionAlert) [ownedSessionAlert dismissViewControllerAnimated:NO completion:nil];
  ownedSessionAlert = nil;
  returnButton.enabled = NO;
  settingsButton.enabled = NO;
  // The next safe frame boundary requests the normal title transition to flush
  // saves, then returns through RuntimeMain cleanup. Hiding is not shutdown.
  NSLog(@"[NeoKartPad/Session] close requested; waiting for guest teardown");
}

int Initialize(const char* support, const char* cache,
               char* error, size_t errorSize) {
  if (!NSThread.isMainThread)
    return Fail(error, errorSize, "KartPad must initialize on the UIKit thread.");
  if (!support || !*support || !cache || !*cache)
    return Fail(error, errorSize, "KartPad data directories are missing.");
  if (session.state() == NEO_KARTPAD_ENDED)
    return Fail(error, errorSize,
                "KartPad donor runtime ended after an unexpected native failure.");
  supportPath = support;
  cachePath = cache;
  ApplyNeoStationKartPadInputPolicy();
  return PrepareRuntimeStorage(error, errorSize) ? 1 : 0;
}

int Start(const char* game, void* host, char* error, size_t errorSize) {
  if (!NSThread.isMainThread)
    return Fail(error, errorSize, "KartPad must launch on the UIKit thread.");
  if (!game || !*game)
    return Fail(error, errorSize, "KartPad has no Mario Kart Wii path.");
  if (session.active())
    return Fail(error, errorSize, "A KartPad session is already active.");

  ApplyNeoStationKartPadInputPolicy();

  UIView* hostView = (__bridge UIView*)host;
  if (!hostView || !hostView.window)
    return Fail(error, errorSize, "NeoStation host window is unavailable.");
  neoStationWindow = hostView.window;

  if (runtimeThreadActive.load(std::memory_order_acquire))
    return Fail(error, errorSize, "KartPad cleanup is still in progress.");

  gamePath = game;
  if (!PrepareUserGameDiscovery(error, errorSize)) return 0;
  if (!PrepareEmbeddedRuntimeBootstrap(error, errorSize)) return 0;
  if (!LoadRuntime(error, errorSize)) return 0;
  if (!SetRuntimeLanguageOverride(CurrentGameLanguage()))
    return Fail(error, errorSize, "KartPad language bridge is unavailable.");
  if (!session.reserve())
    return Fail(error, errorSize, "KartPad could not reserve a session.");

  session.runtimeReady();
  const uint64_t serial = sessionSerial.fetch_add(1, std::memory_order_acq_rel) + 1;
  NSLog(@"[NeoKartPad/Lifecycle] session=%llu created language=%ld",
        (unsigned long long)serial, (long)CurrentGameLanguage());

  // Return from the Flutter method call first, then enter the official runtime
  // on UIKit's main thread. SDL's own iOS pump services the nested main runloop
  // while the game is active, just as it does in the standalone KartPad app.
  dispatch_async(dispatch_get_main_queue(), ^{ RuntimeMainOnUIKitThread(); });
  PollForRuntimeWindow(0);
  return 1;
}

void Stop() { ReturnToNeoStation(); }
int IsRunning() { return session.active() ? 1 : 0; }
int State() { return session.state(); }

void SetCallback(NeoKartPadEventFn value, void* context) {
  callback = value;
  callbackContext = context;
}

void SetUIText(const char* key, const char* value) {
  if (!key || !*key || !value) return;
  std::lock_guard lock(uiTextMutex);
  uiText[std::string(key)] = std::string(value);
}

const char* RuntimeIdentity() {
  return NEO_KARTPAD_RUNTIME_IDENTITY;
}

const NeoKartPadAPI api{
    NEO_KARTPAD_ABI_VERSION,
    sizeof(NeoKartPadAPI),
    Initialize,
    Start,
    Stop,
    IsRunning,
    SetCallback,
    State,
    SetUIText,
    RuntimeIdentity,
};
}  // namespace

extern "C" __attribute__((visibility("default")))
const NeoKartPadAPI* NeoKartPad_GetAPI(void) {
  return &api;
}

extern "C" __attribute__((visibility("default")))
int NeoKartPad_PrepareUserGame(const char* game_path,
                               const char* support_path,
                               const char* cache_path,
                               char* error,
                               size_t error_size) {
  return PrepareCompressedGameData(
      game_path, support_path, cache_path, error, error_size);
}
