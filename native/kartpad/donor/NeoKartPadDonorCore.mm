#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>

#include "KartPadCoreABI.h"
#include "../core/SessionState.h"

#include <atomic>
#include <cstdio>
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

void* runtimeHandle = nullptr;
RuntimeMainFn runtimeMain = nullptr;
SDLGetWindowsFn sdlGetWindows = nullptr;
SDLWindowVisibilityFn sdlHideWindow = nullptr;
SDLWindowVisibilityFn sdlShowWindow = nullptr;
SDLFreeFn sdlFree = nullptr;

std::atomic_bool runtimeThreadActive{false};
std::string supportPath;
std::string cachePath;
std::string gamePath;
UIWindow* neoStationWindow = nil;
UIWindow* donorWindow = nil;
UIButton* returnButton = nil;
NSObject* returnTarget = nil;

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

bool EnsureSymlink(NSString* linkPath, NSString* targetPath, NSError** error) {
  NSFileManager* files = NSFileManager.defaultManager;
  NSDictionary* attrs = [files attributesOfItemAtPath:linkPath error:nil];
  if (attrs != nil) {
    NSString* type = attrs[NSFileType];
    if ([type isEqualToString:NSFileTypeSymbolicLink]) {
      NSString* current = [files destinationOfSymbolicLinkAtPath:linkPath error:nil];
      if ([current isEqualToString:targetPath]) return true;
    }
    if (![files removeItemAtPath:linkPath error:error]) return false;
  }
  return [files createSymbolicLinkAtPath:linkPath
                     withDestinationPath:targetPath
                                   error:error];
}

bool PrepareRuntimeStorage(char* error, size_t errorSize) {
  NSFileManager* files = NSFileManager.defaultManager;
  NSString* support = [NSString stringWithUTF8String:supportPath.c_str()];
  NSString* cache = [NSString stringWithUTF8String:cachePath.c_str()];
  NSString* defaultRoot =
      [[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support"]
          stringByAppendingPathComponent:@"KartPad"];
  NSError* failure = nil;
  if (![files createDirectoryAtPath:defaultRoot withIntermediateDirectories:YES
                         attributes:nil error:&failure]) {
    return Fail(error, errorSize, failure.localizedDescription.UTF8String);
  }
  if (![files createDirectoryAtPath:cache withIntermediateDirectories:YES
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
    if (![EnsureSymlink(pair[0], target, &failure)]) {
      return Fail(error, errorSize, failure.localizedDescription.UTF8String);
    }
  }

  NSString* defaultCache =
      [[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Caches"]
          stringByAppendingPathComponent:@"KartPad"];
  [files createDirectoryAtPath:defaultCache.stringByDeletingLastPathComponent
   withIntermediateDirectories:YES attributes:nil error:nil];
  if (!EnsureSymlink(defaultCache, cache, &failure)) {
    return Fail(error, errorSize, failure.localizedDescription.UTF8String);
  }
  return true;
}

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

void InstallAutoImportSwizzle() {
  Class host = NSClassFromString(@"KartPadFirstLaunchHost");
  if (!host) return;
  Method show = class_getInstanceMethod(host, NSSelectorFromString(@"showOptions"));
  Method choose =
      class_getInstanceMethod(host, NSSelectorFromString(@"chooseDocumentsRoot"));
  if (!show || !choose) return;
  method_setImplementation(show, method_getImplementation(choose));
  NSLog(@"[NeoKartPad/Donor] First-launch import redirected to NeoStation user game.");
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
  if (!runtimeMain || !sdlGetWindows || !sdlHideWindow || !sdlShowWindow) {
    return Fail(error, errorSize,
                "KartPad donor runtime is missing RuntimeMain or SDL window exports.");
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

@interface NeoKartPadDonorReturnTarget : NSObject
- (void)returnToNeoStation;
@end
@implementation NeoKartPadDonorReturnTarget
- (void)returnToNeoStation { ReturnToNeoStation(); }
@end

void InstallReturnButton() {
  UIWindow* window = CurrentDonorWindow();
  if (!window || returnButton.superview) return;
  donorWindow = window;
  if (!returnTarget) returnTarget = [NeoKartPadDonorReturnTarget new];
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
  [button addTarget:returnTarget action:@selector(returnToNeoStation)
    forControlEvents:UIControlEventTouchUpInside];
  UIView* root = window.rootViewController.view ?: window;
  [root addSubview:button];
  [NSLayoutConstraint activateConstraints:@[
    [button.topAnchor constraintEqualToAnchor:root.safeAreaLayoutGuide.topAnchor constant:8],
    [button.trailingAnchor constraintEqualToAnchor:root.safeAreaLayoutGuide.trailingAnchor constant:-8],
  ]];
  returnButton = button;
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

void RuntimeThreadMain() {
  runtimeThreadActive.store(true, std::memory_order_release);
  char name[] = "KartPadRuntime";
  char* argv[] = {name, nullptr};
  const int result = runtimeMain ? runtimeMain(1, argv) : -1;
  runtimeThreadActive.store(false, std::memory_order_release);
  dispatch_async(dispatch_get_main_queue(), ^{
    if (session.state() != NEO_KARTPAD_ENDED) {
      session.terminate();
      Emit(result == 0 ? "KartPad donor runtime exited."
                       : "KartPad donor runtime failed.");
    }
  });
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

  if (!gamePath.empty() && gamePath != game && runtimeThreadActive.load())
    return Fail(error, errorSize,
                "The retained donor runtime owns another Mario Kart Wii image.");
  gamePath = game;

  if (!PrepareUserGameDiscovery(error, errorSize)) return 0;
  if (!LoadRuntime(error, errorSize)) return 0;
  if (!session.reserve())
    return Fail(error, errorSize, "KartPad could not reserve a session.");

  session.runtimeReady();
  if (runtimeThreadActive.load(std::memory_order_acquire)) {
    ForEachSDLWindow([](SDL_Window* window) { sdlShowWindow(window); });
    if (donorWindow) [donorWindow makeKeyAndVisible];
    returnButton.hidden = NO;
    session.firstFrame();
    Emit("Resumed retained KartPad donor runtime.");
    return 1;
  }

  std::thread(RuntimeThreadMain).detach();
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
