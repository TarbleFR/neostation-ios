#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#include "KartPadCoreABI.h"
#include "SessionState.h"

#include <atomic>
#include <condition_variable>
#include <cstdio>
#include <mutex>
#include <string>
#include <thread>
#include <unordered_map>

extern "C" int NeoKartPadRuntimeRunGuest(void);

namespace {
NeoKartPadSessionState session;
NeoKartPadEventFn callback = nullptr;
void* callbackContext = nullptr;

std::string supportPath;
std::string cachePath;
std::string gamePath;
UIWindow* hostWindow = nil;

std::mutex guestMutex;
std::condition_variable guestCondition;
std::atomic_bool returnRequested{false};
std::atomic_bool guestSuspended{false};
std::atomic_bool terminalRequested{false};
std::atomic_bool guestStarted{false};
std::atomic_int lastExitReason{NEO_KARTPAD_EXIT_NONE};
std::mutex uiTextMutex;
std::unordered_map<std::string, std::string> uiText;

int Fail(char* error, size_t errorSize, const char* message) {
  if (error && errorSize) std::snprintf(error, errorSize, "%s", message);
  NSLog(@"[NeoKartPad] %s", message);
  return 0;
}

void Emit(const char* message) {
  NSLog(@"[NeoKartPad] state=%d %s", session.state(), message ? message : "");
  if (callback) callback(callbackContext, session.state(), message ? message : "");
}

void RestoreHostWindow() {
  if (hostWindow && hostWindow.windowScene) [hostWindow makeKeyAndVisible];
  hostWindow = nil;
}

void FinishRetainedReturnOnMainThread() {
  if (!NSThread.isMainThread) {
    dispatch_async(dispatch_get_main_queue(), ^{
      FinishRetainedReturnOnMainThread();
    });
    return;
  }
  if (!session.active()) return;
  RestoreHostWindow();
  session.finishRetained();
  Emit("KartPad session suspended; Mario Kart Wii can resume without restarting NeoStation.");
}

void TerminalEndOnMainThread(const char* reason) {
  if (!NSThread.isMainThread) {
    const std::string copy = reason ? reason : "KartPad runtime ended.";
    dispatch_async(dispatch_get_main_queue(), ^{
      TerminalEndOnMainThread(copy.c_str());
    });
    return;
  }
  terminalRequested.store(true, std::memory_order_release);
  guestSuspended.store(false, std::memory_order_release);
  guestCondition.notify_all();
  RestoreHostWindow();
  lastExitReason.store(NEO_KARTPAD_EXIT_RUNTIME_FAILURE, std::memory_order_release);
  session.terminate();
  Emit(reason ? reason : "KartPad runtime ended.");
}

void GuestMain() {
  guestStarted.store(true, std::memory_order_release);
  const int result = NeoKartPadRuntimeRunGuest();
  guestStarted.store(false, std::memory_order_release);
  if (terminalRequested.load(std::memory_order_acquire)) return;
  dispatch_async(dispatch_get_main_queue(), ^{
    TerminalEndOnMainThread(
        result == 0
            ? "KartPad guest runtime exited."
            : "KartPad guest runtime failed; see KartPad logs.");
  });
}

int Initialize(const char* support,
               const char* cache,
               char* error,
               size_t errorSize) {
  if (!NSThread.isMainThread)
    return Fail(error, errorSize, "KartPad must initialize on the UIKit thread.");
  if (!support || !*support || !cache || !*cache)
    return Fail(error, errorSize, "KartPad data directories are missing.");
  if (session.state() == NEO_KARTPAD_ENDED)
    return Fail(error, errorSize, "KartPad runtime is terminal and cannot be reused.");

  if (!supportPath.empty() &&
      (supportPath != support || cachePath != cache)) {
    return Fail(error, errorSize,
                "KartPad cannot change its data directories after initialization.");
  }

  supportPath = support;
  cachePath = cache;
  for (NSString* raw in @[
         [NSString stringWithUTF8String:support],
         [NSString stringWithUTF8String:cache],
       ]) {
    NSError* failure = nil;
    if (![NSFileManager.defaultManager createDirectoryAtPath:raw
                                withIntermediateDirectories:YES
                                                 attributes:nil
                                                      error:&failure]) {
      return Fail(error, errorSize, failure.localizedDescription.UTF8String);
    }
  }
  return 1;
}

int Start(const char* game, void* host, char* error, size_t errorSize) {
  if (!NSThread.isMainThread)
    return Fail(error, errorSize, "KartPad must launch on the UIKit thread.");
  if (!game || !*game)
    return Fail(error, errorSize, "KartPad has no Mario Kart Wii path.");
  if (supportPath.empty() || cachePath.empty())
    return Fail(error, errorSize, "KartPad is not initialized.");
  if (session.state() == NEO_KARTPAD_ENDED)
    return Fail(error, errorSize, "KartPad runtime is terminal and requires a NeoStation restart.");
  if (session.active())
    return Fail(error, errorSize, "A KartPad session is already active.");

  UIView* hostView = (__bridge UIView*)host;
  if (!hostView || !hostView.window || !hostView.window.windowScene)
    return Fail(error, errorSize, "NeoStation host window is unavailable.");

  if (session.runtimeReadyFlag() && gamePath != game)
    return Fail(error, errorSize, "The retained KartPad runtime owns another game image.");

  if (!session.reserve())
    return Fail(error, errorSize, "KartPad could not reserve a session.");

  hostWindow = hostView.window;
  gamePath = game;
  returnRequested.store(false, std::memory_order_release);
  terminalRequested.store(false, std::memory_order_release);

  if (session.runtimeReadyFlag() &&
      guestSuspended.load(std::memory_order_acquire)) {
    Emit("Resuming retained KartPad runtime.");
    guestSuspended.store(false, std::memory_order_release);
    guestCondition.notify_all();
    return 1;
  }

  if (guestStarted.load(std::memory_order_acquire))
    return Fail(error, errorSize, "KartPad guest runtime is already active.");

  Emit("Starting embedded KartPad runtime.");
  session.runtimeReady();
  std::thread(GuestMain).detach();
  return 1;
}

void Stop() {
  if (!NSThread.isMainThread || !session.active()) return;
  lastExitReason.store(NEO_KARTPAD_EXIT_USER_RETURN, std::memory_order_release);
  session.requestStop();
  returnRequested.store(true, std::memory_order_release);
  Emit("Return requested; waiting for KartPad's guest event boundary.");
}

int IsRunning() { return session.active() ? 1 : 0; }
int State() { return session.state(); }
int LastExitReason() { return lastExitReason.load(std::memory_order_acquire); }

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
    LastExitReason,
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
  if (!game_path || !*game_path || !support_path || !*support_path ||
      !cache_path || !*cache_path) {
    return Fail(error, error_size, "KartPad preparation paths are incomplete.");
  }
  if (session.active()) {
    return Fail(error, error_size,
                "KartPad cannot prepare game data while a session is active.");
  }

  __block int initialized = 0;
  void (^initializeBlock)(void) = ^{
    initialized = Initialize(
        support_path, cache_path, error, error_size);
  };
  if (NSThread.isMainThread) initializeBlock();
  else dispatch_sync(dispatch_get_main_queue(), initializeBlock);
  if (!initialized) return 0;

  Class extractor = NSClassFromString(@"KartPadDiscExtractor");
  SEL selector = NSSelectorFromString(
      @"extractImageAtPath:toDirectory:progress:error:");
  if (!extractor || ![extractor respondsToSelector:selector]) {
    return Fail(error, error_size, "KartPad DiscIO extractor is unavailable.");
  }

  NSString* support = [NSString stringWithUTF8String:support_path];
  NSString* finalPath = [support stringByAppendingPathComponent:@"GameData"];
  NSString* staging = [support stringByAppendingPathComponent:
      [NSString stringWithFormat:@"GameData.import-%@", NSUUID.UUID.UUIDString]];
  NSString* rollback = [support stringByAppendingPathComponent:
      [NSString stringWithFormat:@"GameData.rollback-%@", NSUUID.UUID.UUIDString]];
  NSFileManager* files = NSFileManager.defaultManager;
  NSError* failure = nil;

  using ExtractFn =
      BOOL (*)(id, SEL, NSString*, NSString*, id, NSError**);
  IMP implementation = [extractor methodForSelector:selector];
  if (!implementation) {
    return Fail(error, error_size, "KartPad DiscIO extractor entry point is missing.");
  }
  BOOL extracted = reinterpret_cast<ExtractFn>(implementation)(
      extractor, selector, [NSString stringWithUTF8String:game_path],
      staging, nil, &failure);
  if (!extracted || failure) {
    [files removeItemAtPath:staging error:nil];
    return Fail(error, error_size,
                (failure.localizedDescription ?: @"KartPad extraction failed.")
                    .UTF8String);
  }

  BOOL movedExisting = NO;
  if ([files fileExistsAtPath:finalPath]) {
    movedExisting = [files moveItemAtPath:finalPath toPath:rollback error:&failure];
  }
  if (!failure) [files moveItemAtPath:staging toPath:finalPath error:&failure];
  if (failure) {
    [files removeItemAtPath:staging error:nil];
    if (movedExisting && ![files fileExistsAtPath:finalPath]) {
      [files moveItemAtPath:rollback toPath:finalPath error:nil];
    }
    return Fail(error, error_size, failure.localizedDescription.UTF8String);
  }
  if (movedExisting) [files removeItemAtPath:rollback error:nil];
  return 1;
}


extern "C" const char* NeoKartPadEmbeddedUIText(const char* key) {
  static thread_local std::string result;
  if (!key || !*key) return nullptr;
  std::lock_guard lock(uiTextMutex);
  const auto it = uiText.find(std::string(key));
  if (it == uiText.end()) return nullptr;
  result = it->second;
  return result.c_str();
}

extern "C" const char* NeoKartPadEmbeddedSupportPath(void) {
  return supportPath.c_str();
}

extern "C" const char* NeoKartPadEmbeddedCachePath(void) {
  return cachePath.c_str();
}

extern "C" const char* NeoKartPadEmbeddedGamePath(void) {
  return gamePath.c_str();
}

extern "C" int NeoKartPadEmbeddedShouldReturnToHost(void) {
  return returnRequested.load(std::memory_order_acquire) ? 1 : 0;
}

extern "C" void NeoKartPadEmbeddedSuspendGuestUntilResume(void) {
  guestSuspended.store(true, std::memory_order_release);
  returnRequested.store(false, std::memory_order_release);
  dispatch_async(dispatch_get_main_queue(), ^{
    FinishRetainedReturnOnMainThread();
  });

  std::unique_lock lock(guestMutex);
  guestCondition.wait(lock, [] {
    return !guestSuspended.load(std::memory_order_acquire) ||
           terminalRequested.load(std::memory_order_acquire);
  });
}

extern "C" void NeoKartPadEmbeddedFramePresented(void) {
  dispatch_async(dispatch_get_main_queue(), ^{
    if (session.firstFrame()) Emit("First KartPad frame presented.");
  });
}
