#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>

#include "KartPadCoreABI.h"
#include "../core/SessionState.h"

#include <atomic>
#include <cerrno>
#include <cstring>
#include <sys/stat.h>
#include <unistd.h>
#include <cstdio>
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
  [NSUserDefaults.standardUserDefaults setInteger:value forKey:key];
  [NSUserDefaults.standardUserDefaults synchronize];
}

void PersistBool(NSString* key, BOOL value) {
  [NSUserDefaults.standardUserDefaults setBool:value forKey:key];
  [NSUserDefaults.standardUserDefaults synchronize];
}

UIMenu* BuildNeoKartPadSettingsMenu();

void RefreshSettingsMenu() {
  if (settingsButton) settingsButton.menu = BuildNeoKartPadSettingsMenu();
}

UIMenu* BuildNeoKartPadSettingsMenu() {
  NSUserDefaults* defaults = NSUserDefaults.standardUserDefaults;

  // Selecting this action simply dismisses UIKit's menu and hands controller
  // focus straight back to the already-running guest. It deliberately does
  // not mutate session state or rebuild the renderer.
  UIAction* returnToGameAction = [UIAction actionWithTitle:
      UIText(@"Return to Game", "returnToGame")
      image:[UIImage systemImageNamed:@"play.fill"] identifier:nil
      handler:^(__kindof UIAction*) {}];

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
      PersistInteger(kNeoKartPadLanguageKey, value);
      NSError* languageError = nil;
      if (!WriteGameLanguageSysConf(&languageError)) {
        NSLog(@"[NeoKartPad/Settings] language write failed: %@", languageError);
      } else {
        NSLog(@"[NeoKartPad/Settings] game language=%ld persisted to Wii IPL.LNG",
              (long)value);
      }
      RefreshSettingsMenu();
    }];
    action.state =
        currentLanguage == value ? UIMenuElementStateOn : UIMenuElementStateOff;
    [languageItems addObject:action];
  }
  UIAction* languageRestartHint = [UIAction actionWithTitle:
      UIText(@"Saved now; restart NeoStation to apply the new game language.",
             "languageRestartHint")
      image:[UIImage systemImageNamed:@"info.circle"] identifier:nil
      handler:^(__kindof UIAction*) {}];
  languageRestartHint.attributes = UIMenuElementAttributesDisabled;
  [languageItems addObject:languageRestartHint];

  NSString* languageMenuTitle = [NSString stringWithFormat:@"%@ — %@",
      UIText(@"Game Language", "gameLanguage"), currentLanguageName];
  UIMenu* languageMenu = [UIMenu menuWithTitle:languageMenuTitle
      image:[UIImage systemImageNamed:@"globe"]
      identifier:@"com.neostation.kartpad.language" options:0
      children:languageItems];

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
                      children:@[returnToGameAction, languageMenu, graphicsMenu, hint]];
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
  NSLog(@"[NeoKartPad/Donor] Embedded first-launch policy installed.");
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
    dispatch_async(dispatch_get_main_queue(), ^{ RuntimeMainOnUIKitThread(); });
    return;
  }
  runtimeThreadActive.store(true, std::memory_order_release);

  // The official iOS executable enters RuntimeMain through SDL_RunApp.
  // NeoStation already owns UIApplication, so it must reproduce the parts of
  // SDL's iOS bootstrap that are safe inside an existing application:
  // main-ready state plus the UIKit event pump. RuntimeMain itself must remain
  // on UIKit's main thread because SDL creates UIWindow/CAMetalLayer there.
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

  if (session.state() != NEO_KARTPAD_ENDED) {
    session.terminate();
    if (result == 0) {
      Emit("KartPad donor runtime exited.");
    } else if (!runtimeError.empty()) {
      const std::string message =
          "KartPad donor runtime failed before first frame: " + runtimeError;
      Emit(message.c_str());
    } else {
      Emit("KartPad donor runtime failed before first frame.");
    }
  }
}

void ReturnToNeoStation() {
  if (!NSThread.isMainThread) {
    dispatch_async(dispatch_get_main_queue(), ^{ ReturnToNeoStation(); });
    return;
  }
  if (!session.active()) return;
  session.requestStop();
  ForEachSDLWindow([](SDL_Window* window) { sdlHideWindow(window); });
  returnButton.hidden = YES;
  settingsButton.hidden = YES;
  if (neoStationWindow) [neoStationWindow makeKeyAndVisible];
  session.finishRetained();
  Emit("KartPad donor runtime hidden and retained.");
}

int Initialize(const char* support, const char* cache,
               char* error, size_t errorSize) {
  if (!NSThread.isMainThread)
    return Fail(error, errorSize, "KartPad must initialize on the UIKit thread.");
  if (!support || !*support || !cache || !*cache)
    return Fail(error, errorSize, "KartPad data directories are missing.");
  if (session.state() == NEO_KARTPAD_ENDED)
    return Fail(error, errorSize, "KartPad donor runtime is terminal.");
  supportPath = support;
  cachePath = cache;
  return PrepareRuntimeStorage(error, errorSize) ? 1 : 0;
}

int Start(const char* game, void* host, char* error, size_t errorSize) {
  if (!NSThread.isMainThread)
    return Fail(error, errorSize, "KartPad must launch on the UIKit thread.");
  if (!game || !*game)
    return Fail(error, errorSize, "KartPad has no Mario Kart Wii path.");
  if (session.active())
    return Fail(error, errorSize, "A KartPad session is already active.");

  UIView* hostView = (__bridge UIView*)host;
  if (!hostView || !hostView.window)
    return Fail(error, errorSize, "NeoStation host window is unavailable.");
  neoStationWindow = hostView.window;

  const bool retainedRuntime =
      runtimeThreadActive.load(std::memory_order_acquire);
  if (retainedRuntime) {
    if (!gamePath.empty() && gamePath != game)
      return Fail(error, errorSize,
                  "The retained donor runtime owns another Mario Kart Wii image.");
    gamePath = game;
    if (!session.reserve())
      return Fail(error, errorSize, "KartPad could not reserve a retained session.");
    session.runtimeReady();
    ForEachSDLWindow([](SDL_Window* window) { sdlShowWindow(window); });
    if (donorWindow) [donorWindow makeKeyAndVisible];
    returnButton.hidden = NO;
    settingsButton.hidden = NO;
    RefreshSettingsMenu();
    session.firstFrame();
    Emit("Resumed retained KartPad donor runtime without bootstrap.");
    return 1;
  }

  gamePath = game;
  if (!PrepareUserGameDiscovery(error, errorSize)) return 0;
  if (!PrepareEmbeddedRuntimeBootstrap(error, errorSize)) return 0;
  if (!LoadRuntime(error, errorSize)) return 0;
  if (!session.reserve())
    return Fail(error, errorSize, "KartPad could not reserve a session.");

  session.runtimeReady();

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
