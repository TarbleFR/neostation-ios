#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#include "DusklightCoreABI.h"
#include "NeoDusklightHost.h"
#include "SessionState.h"
#define SDL_MAIN_HANDLED
#include <SDL3/SDL.h>
#include <SDL3/SDL_main.h>
#include <dlfcn.h>
#include <cstdio>
#include <exception>
#include <string>
#include <vector>

extern "C" __attribute__((visibility("default")))
const NeoDusklightAPI* NeoDusklight_GetAPI(void);

namespace {
NeoDusklightSessionState session;
NeoDusklightEventFn eventCallback = nullptr;
void* eventContext = nullptr;
std::string supportPath, cachePath, resourcesPath, gamePath;
UIWindow* hostWindow;
UIWindow* gameWindow;
NSTimer* startTimer;
FILE* traceFile = nullptr;

void Trace(const char* message) {
  NSLog(@"[NeoDusklight] %s", message);
  if (traceFile) {
    fprintf(traceFile, "%.3f state=%d %s\n", NSDate.date.timeIntervalSince1970,
            session.state(), message);
    fflush(traceFile);
  }
}

void Emit(const char* message) {
  Trace(message);
  if (eventCallback) eventCallback(eventContext, session.state(), message);
}

int Fail(char* error, size_t size, const char* message) {
  if (error && size) snprintf(error, size, "%s", message);
  Trace(message);
  return 0;
}

void Stop() {
  if (!NSThread.isMainThread || !session.active()) return;
  session.requestStop();
  Emit("Stop requested; waiting for native cleanup.");
  if (startTimer) {
    [startTimer invalidate];
    startTimer = nil;
    session.finish();
    Emit("Launch canceled before entering the game.");
    hostWindow = nil;
    return;
  }
  // Same thread as game_main, which pumps the UIKit run loop via SDL.
  // Never destroy SDL/rendering state from inside a UIKit callback.
  NeoDusklight_StopGame();
  SDL_Event quit{};
  quit.type = SDL_EVENT_QUIT;
  SDL_PushEvent(&quit);
}

void RestoreHost() {
  // Only the window captured by WindowReady belongs to this session.
  if (gameWindow) gameWindow.hidden = YES;
  gameWindow = nil;
  if (hostWindow && hostWindow.windowScene) [hostWindow makeKeyAndVisible];
  hostWindow = nil;
}

void RunGame() {
  startTimer = nil;
  if (!session.enter()) return;
  Emit("Entering native Dusklight game_main (Metal, no emulator/JIT).");
  SDL_SetMainReady();
  std::vector<std::string> arguments{
      "Dusklight", "--dvd", gamePath, "--user-dir", supportPath,
      "--backend", "metal"};
  std::vector<char*> argv;
  for (auto& arg : arguments) argv.push_back(arg.data());
  argv.push_back(nullptr);
  int result = 1;
  try {
    result = NeoDusklight_RunGame(static_cast<int>(arguments.size()), argv.data());
  } catch (const std::exception& ex) {
    Trace(ex.what());
  } catch (...) {
    Trace("Unknown exception escaped the native game.");
  }
  RestoreHost();
  session.finish();
  Emit(result == 0 ? "Dusklight closed. Restart NeoStation before another native session."
                   : "Dusklight returned a startup/runtime error; see its native log.");
  if (traceFile) { fclose(traceFile); traceFile = nullptr; }
}

int Initialize(const char* support, const char* cache, char* error, size_t size) {
  if (!NSThread.isMainThread) return Fail(error, size, "Dusklight must initialize on the UIKit thread.");
  if (session.active()) return Fail(error, size, "A Dusklight session is already active.");
  if (session.entered()) return Fail(error, size, "Restart NeoStation before launching Dusklight again.");
  if (!support || !*support || !cache || !*cache)
    return Fail(error, size, "Dusklight data directories are missing.");

  Dl_info image{};
  if (!dladdr(reinterpret_cast<const void*>(&NeoDusklight_GetAPI), &image) || !image.dli_fname)
    return Fail(error, size, "Cannot locate the Dusklight framework resources.");
  NSString* framework = [[NSString stringWithUTF8String:image.dli_fname] stringByDeletingLastPathComponent];
  if (![NSFileManager.defaultManager fileExistsAtPath:[framework stringByAppendingPathComponent:@"res"]])
    return Fail(error, size, "Dusklight framework resources are missing.");
  resourcesPath = std::string(framework.fileSystemRepresentation) + "/";
  supportPath = support;
  cachePath = cache;
  for (NSString* directory in @[[NSString stringWithUTF8String:support],
                                [NSString stringWithUTF8String:cache]]) {
    NSError* failure = nil;
    if (![NSFileManager.defaultManager createDirectoryAtPath:directory
                               withIntermediateDirectories:YES attributes:nil error:&failure])
      return Fail(error, size, failure.localizedDescription.UTF8String);
    NSString* probe = [directory stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    if (![[NSData data] writeToFile:probe options:0 error:&failure])
      return Fail(error, size, failure.localizedDescription.UTF8String);
    [NSFileManager.defaultManager removeItemAtPath:probe error:nil];
  }
  NSString* logs = [[NSString stringWithUTF8String:support] stringByAppendingPathComponent:@"Logs"];
  [NSFileManager.defaultManager createDirectoryAtPath:logs withIntermediateDirectories:YES attributes:nil error:nil];
  if (traceFile) fclose(traceFile);
  traceFile = fopen([logs stringByAppendingPathComponent:@"neostation-dusklight.log"].fileSystemRepresentation, "a");
  Trace("Native framework and resources initialized.");
  return 1;
}

int Start(const char* game, void* host, char* error, size_t size) {
  if (!NSThread.isMainThread) return Fail(error, size, "Dusklight must launch on the UIKit thread.");
  UIView* view = (__bridge UIView*)host;
  if (!view || !view.window || !view.window.windowScene)
    return Fail(error, size, "The NeoStation host window is unavailable.");
  if (!game || !*game || resourcesPath.empty())
    return Fail(error, size, "Dusklight has no game path or initialized resources.");
  if (session.active() || session.entered())
    return Fail(error, size, "Restart NeoStation before launching another Dusklight session.");

  // Authoritative upstream metadata/revision validation, also for RVZ/WBFS.
  // A rejected image never consumes the one native session or creates a window.
  if (!NeoDusklight_InspectDisc(game, error, size)) return 0;
  if (!session.reserve()) return Fail(error, size, "Dusklight could not reserve a session.");
  hostWindow = view.window;
  gamePath = game;
  Emit("Disc accepted; scheduling the native game on the UIKit run loop.");
  // Do not run the nested SDL/UIKit loop inside a main dispatch-queue block:
  // libdispatch must remain able to deliver Flutter and lifecycle callbacks.
  startTimer = [NSTimer timerWithTimeInterval:0.01 repeats:NO block:^(NSTimer*) {
    @autoreleasepool { RunGame(); }
  }];
  [NSRunLoop.mainRunLoop addTimer:startTimer forMode:NSRunLoopCommonModes];
  return 1;
}

int IsRunning() { return session.active() ? 1 : 0; }
int State() { return session.state(); }
void SetCallback(NeoDusklightEventFn callback, void* context) {
  eventCallback = callback;
  eventContext = context;
}
const NeoDusklightAPI api{NEO_DUSKLIGHT_ABI_VERSION, sizeof(NeoDusklightAPI),
    Initialize, Start, Stop, IsRunning, SetCallback, State};
}  // namespace

@interface NeoDusklightControls : NSObject
- (void)closeGame;
@end
@implementation NeoDusklightControls
- (void)closeGame { Stop(); }
@end

extern "C" const char* NeoDusklight_ResourcesPath() { return resourcesPath.c_str(); }
extern "C" const char* NeoDusklight_CachePath() { return cachePath.c_str(); }
extern "C" void* NeoDusklight_WindowScene() {
  return (__bridge void*)hostWindow.windowScene;
}
extern "C" void NeoDusklight_WindowReady(void* window) {
  auto* sdlWindow = static_cast<SDL_Window*>(window);
  gameWindow = (__bridge UIWindow*)SDL_GetPointerProperty(
      SDL_GetWindowProperties(sdlWindow), SDL_PROP_WINDOW_UIKIT_WINDOW_POINTER, nullptr);
  if (!gameWindow || gameWindow == hostWindow) {
    Trace("SDL did not provide a distinct owned game window.");
    Stop();
    return;
  }
  static NeoDusklightControls* controls = [NeoDusklightControls new];
  UIButton* close = [UIButton buttonWithType:UIButtonTypeSystem];
  close.translatesAutoresizingMaskIntoConstraints = NO;
  close.accessibilityLabel = @"Retour à NeoStation";
  [close setImage:[UIImage systemImageNamed:@"xmark.circle.fill"] forState:UIControlStateNormal];
  close.tintColor = UIColor.whiteColor;
  close.backgroundColor = [UIColor.blackColor colorWithAlphaComponent:0.65];
  close.layer.cornerRadius = 22;
  [close addTarget:controls action:@selector(closeGame) forControlEvents:UIControlEventTouchUpInside];
  [gameWindow addSubview:close];
  [NSLayoutConstraint activateConstraints:@[
    [close.widthAnchor constraintEqualToConstant:44],
    [close.heightAnchor constraintEqualToConstant:44],
    [close.trailingAnchor constraintEqualToAnchor:gameWindow.safeAreaLayoutGuide.trailingAnchor constant:-8],
    [close.topAnchor constraintEqualToAnchor:gameWindow.safeAreaLayoutGuide.topAnchor constant:8],
  ]];
  Trace("Owned Metal game window attached; return button available.");
}
extern "C" void NeoDusklight_FirstFrame() {
  if (session.firstFrame()) Emit("First native game frame submitted.");
}
extern "C" __attribute__((visibility("default")))
const NeoDusklightAPI* NeoDusklight_GetAPI() { return &api; }
