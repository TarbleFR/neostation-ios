#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>

#include "DusklightCoreABI.h"
#include "NeoDusklightHost.h"
#include "SessionState.h"
#include "VirtualMemoryTrace.h"
#define SDL_MAIN_HANDLED
#include <SDL3/SDL.h>
#include <SDL3/SDL_main.h>
#include <dlfcn.h>
#include <cstdio>
#include <exception>
#include <map>
#include <string>
#include <vector>

extern "C" __attribute__((visibility("default")))
const NeoDusklightAPI* NeoDusklight_GetAPI(void);

@interface NeoDusklightControls : NSObject
- (void)openMenu;
- (void)tick:(CADisplayLink*)link;
- (void)background:(NSNotification*)note;
- (void)foreground:(NSNotification*)note;
@end

namespace {
NeoDusklightSessionState session;
NeoDusklightEventFn eventCallback = nullptr;
void* eventContext = nullptr;
std::string supportPath, cachePath, resourcesPath, gamePath;
std::map<std::string, std::string> uiText;
UIWindow* hostWindow;
UIWindow* gameWindow;
SDL_Window* sdlWindow = nullptr;
UIButton* menuButton;
NeoDusklightControls* controls;
NSTimer* startTimer;
CADisplayLink* displayLink;
bool inNativeCall = false, suspended = false, backgrounded = false, menuRequested = false;
struct stat discIdentity{};
std::string terminalReason;
FILE* traceFile = nullptr;

void Trace(const char* message) {
  NSLog(@"[NeoDusklight] %s", message);
  if (traceFile) {
    fprintf(traceFile, "%.3f state=%d pid=%d build=%s %s\n", NSDate.date.timeIntervalSince1970,
            session.state(), getpid(),
            [[NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleVersion"] UTF8String] ?: "unknown", message);
    fflush(traceFile);
  }
}
void TraceResources(const char* phase) {
  NeoDusklightTraceVM(traceFile, NSDate.date.timeIntervalSince1970,
      [[NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleVersion"] UTF8String] ?: "unknown", phase);
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
NSString* Label(const char* key) {
  return [NSString stringWithUTF8String:NeoDusklight_UIText(key)];
}
void Suspend(bool value) {
  if (!session.ready() || suspended == value) return;
  NeoDusklight_SetGameSuspended(value);
  suspended = value;
}
void RestoreHost() {
  // Never enumerate/hide other emulators' or Flutter's windows.
  if (sdlWindow) SDL_HideWindow(sdlWindow);
  if (gameWindow) gameWindow.hidden = YES;
  if (hostWindow && hostWindow.windowScene) [hostWindow makeKeyAndVisible];
  hostWindow = nil;
}
void ReleaseHostLifecycle() {
  [startTimer invalidate];
  startTimer = nil;
  [displayLink invalidate];
  displayLink = nil;
  if (controls) [NSNotificationCenter.defaultCenter removeObserver:controls];
  [menuButton removeFromSuperview];
  menuButton = nil;
  controls = nil;
  sdlWindow = nullptr;
  gameWindow = nil;
  menuRequested = false;
  backgrounded = false;
  suspended = false;
}
void FinishReturn() {
  if (inNativeCall) return; // Only at a frame boundary, never inside rendering.
  [displayLink invalidate];
  displayLink = nil;
  Suspend(true);
  if (session.ready()) {
    TraceResources("before_graphics_release");
    @autoreleasepool {
      Trace(NeoDusklight_ReleaseFrameResources()
          ? "Transient graphics released; retained runtime is ready for a later Dusklight resume."
          : "Graphics drain did not complete; resources retained safely.");
    }
  }
  RestoreHost();
  menuRequested = false;
  terminalReason.clear();
  TraceResources("return_to_host");
  session.finish();
  Emit(session.ready()
      ? "Session suspended; the same disc can resume without restarting NeoStation."
      : "Launch canceled before runtime initialization completed.");
}

void TerminalShutdown(const char* reason) {
  if (inNativeCall) return;
  [displayLink invalidate];
  displayLink = nil;
  if (session.ready()) Suspend(true);
  RestoreHost();

  if (!session.ready()) {
    session.fail();
    Emit(reason ? reason : "Dusklight stopped before runtime initialization completed.");
    return;
  }

  session.requestStop();
  terminalReason = reason ? reason : "Dusklight stopped after a native runtime failure.";
  TraceResources("before_runtime_shutdown");
  const bool stopped = NeoDusklight_ShutdownRuntime() != 0;
  Trace(NeoDusklight_LastShutdownReport());
  ReleaseHostLifecycle();
  TraceResources("after_runtime_shutdown");
  if (!stopped) {
    Emit("Dusklight shutdown was incomplete; restart NeoStation before launching another core.");
    terminalReason.clear();
    if (traceFile) {
      fclose(traceFile);
      traceFile = nullptr;
    }
    return;
  }

  session.terminate();
  Emit(terminalReason.c_str());
  terminalReason.clear();
  if (traceFile) {
    fclose(traceFile);
    traceFile = nullptr;
  }
}

void Stop() {
  if (!NSThread.isMainThread || !session.active()) return;
  terminalReason.clear();
  session.requestStop();
  Emit("Return requested; waiting for the native frame boundary.");
  [startTimer invalidate];
  startTimer = nil;
  FinishReturn();
}

void RuntimeFailure(const char* reason) {
  if (session.ready()) {
    TerminalShutdown(reason);
    return;
  }
  [displayLink invalidate];
  displayLink = nil;
  RestoreHost();
  session.fail();
  Emit(reason);
}

void Tick() {void Tick() {
  if (inNativeCall || !session.active()) return;
  if (session.state() == NEO_DUSKLIGHT_STOPPING) { FinishReturn(); return; }
  if (backgrounded) { Suspend(true); return; }
  if (!gameWindow.isKeyWindow) { Suspend(true); return; }
  Suspend(false);
  displayLink.preferredFramesPerSecond = NeoDusklight_PreferredFrameRate();
  inNativeCall = true;
  bool ok = false;
  try {
    if (menuRequested) { menuRequested = false; NeoDusklight_OpenMenu(); }
    ok = NeoDusklight_TickGame() != 0;
    // Native RmlUI owns all navigation while a menu (including its closing
    // animation) is on screen. No UIKit hit target may cover its close button.
    menuButton.hidden = NeoDusklight_MenuVisible() != 0;
  } catch (const std::exception& ex) { Trace(ex.what()); }
    catch (...) { Trace("Unknown exception in native frame."); }
  inNativeCall = false;
  if (!ok) { RuntimeFailure("Native game frame failed; see Dusklight logs."); return; }
  if (session.state() == NEO_DUSKLIGHT_STOPPING) FinishReturn();
  else if (backgrounded) Suspend(true);
}
void RunGame() {
  startTimer = nil;
  if (session.state() != NEO_DUSKLIGHT_STARTING) return;
  if (!session.ready()) {
    if (!session.enter()) return;
    Emit("Initializing native Dusklight once (Metal, host-driven frames).");
    SDL_SetMainReady();
    // UIKit already runs NeoStation's main loop. SDL must not nest another.
    SDL_SetiOSEventPump(false);
    std::vector<std::string> arguments{
        "Dusklight", "--dvd", gamePath, "--user-dir", supportPath, "--backend", "metal"};
    std::vector<char*> argv;
    for (auto& arg : arguments) argv.push_back(arg.data());
    argv.push_back(nullptr);
    int result = 1;
    inNativeCall = true;
    try { result = NeoDusklight_RunGame(static_cast<int>(arguments.size()), argv.data()); }
    catch (const std::exception& ex) { Trace(ex.what()); }
    catch (...) { Trace("Unknown exception escaped native initialization."); }
    inNativeCall = false;
    if (result != 0 || !session.ready() || !gameWindow) {
      RuntimeFailure("Dusklight could not initialize its frame loop; see native logs.");
      return;
    }
  }

  if (session.state() == NEO_DUSKLIGHT_STOPPING) { FinishReturn(); return; }
  backgrounded = UIApplication.sharedApplication.applicationState != UIApplicationStateActive;
  menuButton.accessibilityLabel = Label("nativeMenu");
  menuButton.hidden = NeoDusklight_MenuVisible() != 0;
  SDL_ShowWindow(sdlWindow);
  [gameWindow makeKeyAndVisible];
  // Never acknowledge a resume using the old session's last frame.
  displayLink = [CADisplayLink displayLinkWithTarget:controls selector:@selector(tick:)];
  displayLink.preferredFramesPerSecond = NeoDusklight_PreferredFrameRate();
  displayLink.paused = backgrounded;
  [displayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
  if (backgrounded) Suspend(true);
  Emit(session.entered()
      ? "Native frame scheduling active; waiting for this session's first frame."
      : "Native frame scheduling active.");
}

int Initialize(int Initialize(const char* support, const char* cache, char* error, size_t size) {
  if (!NSThread.isMainThread) return Fail(error, size, "Dusklight must initialize on the UIKit thread.");
  if (session.active()) return Fail(error, size, "A Dusklight session is already active.");
  if (!support || !*support || !cache || !*cache)
    return Fail(error, size, "Dusklight data directories are missing.");
  if (session.ready()) {
    if (supportPath != support || cachePath != cache)
      return Fail(error, size, "Cannot change the initialized runtime's data directories.");
    return 1;
  }
  if (session.entered()) return Fail(error, size, "The native runtime failed and cannot be reused.");
  Dl_info image{};
  if (!dladdr(reinterpret_cast<const void*>(&NeoDusklight_GetAPI), &image) || !image.dli_fname)
    return Fail(error, size, "Cannot locate the Dusklight framework resources.");
  NSString* framework = [[NSString stringWithUTF8String:image.dli_fname] stringByDeletingLastPathComponent];
  if (![NSFileManager.defaultManager fileExistsAtPath:[framework stringByAppendingPathComponent:@"res"]])
    return Fail(error, size, "Dusklight framework resources are missing.");
  resourcesPath = std::string(framework.fileSystemRepresentation) + "/";
  supportPath = support;
  cachePath = cache;
  for (NSString* directory in @[[NSString stringWithUTF8String:support], [NSString stringWithUTF8String:cache]]) {
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
  if (!controls) {
    controls = [NeoDusklightControls new];
    [NSNotificationCenter.defaultCenter addObserver:controls selector:@selector(background:)
      name:UIApplicationWillResignActiveNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:controls selector:@selector(foreground:)
      name:UIApplicationDidBecomeActiveNotification object:nil];
  }
  Trace("Native framework and resources initialized.");
  TraceResources("before_runtime_init");
  return 1;
}
int Start(const char* game, void* host, char* error, size_t size) {
  if (!NSThread.isMainThread) return Fail(error, size, "Dusklight must launch on the UIKit thread.");
  UIView* view = (__bridge UIView*)host;
  if (!view || !view.window || !view.window.windowScene)
    return Fail(error, size, "The NeoStation host window is unavailable.");
  if (!game || !*game || resourcesPath.empty())
    return Fail(error, size, "Dusklight has no game path or initialized resources.");
  if (session.active() || session.state() == NEO_DUSKLIGHT_ENDED)
    return Fail(error, size, "Dusklight cannot reserve this session.");

  struct stat candidate{};
  if (stat(game, &candidate) != 0) return Fail(error, size, "Cannot inspect the selected disc.");
  if (session.ready() && (gamePath != game || candidate.st_dev != discIdentity.st_dev ||
      candidate.st_ino != discIdentity.st_ino || candidate.st_size != discIdentity.st_size ||
      candidate.st_mtimespec.tv_sec != discIdentity.st_mtimespec.tv_sec ||
      candidate.st_mtimespec.tv_nsec != discIdentity.st_mtimespec.tv_nsec)) {
    Fail(error, size,
         "The suspended runtime owns another disc or the disc was replaced; hot swapping is unsupported.");
    return NEO_DUSKLIGHT_DIFFERENT_DISC;
  }
  if (!session.ready() && !NeoDusklight_InspectDisc(game, error, size)) return 0;
  if (!session.reserve()) return Fail(error, size, "Dusklight could not reserve a session.");

  hostWindow = view.window;
  gamePath = game;
  discIdentity = candidate;
  Emit(session.ready()
      ? "Resuming the retained native runtime."
      : "Disc accepted; scheduling initialization.");
  startTimer = [NSTimer timerWithTimeInterval:0.01 repeats:NO block:^(NSTimer*) {
    @autoreleasepool { RunGame(); }
  }];
  [NSRunLoop.mainRunLoop addTimer:startTimer forMode:NSRunLoopCommonModes];
  return 1;
}
int IsRunning()int IsRunning() { return session.active() ? 1 : 0; }
int State() { return session.state(); }
void SetCallback(NeoDusklightEventFn callback, void* context) {
  eventCallback = callback; eventContext = context;
}
void SetUIText(const char* key, const char* value) {
  if (key && value && !session.active()) uiText[key] = value;
}
const NeoDusklightAPI api{NEO_DUSKLIGHT_ABI_VERSION, sizeof(NeoDusklightAPI),
    Initialize, Start, Stop, IsRunning, SetCallback, State, SetUIText};
} // namespace

@implementation NeoDusklightControls
- (void)openMenu {
  if (session.active() && !menuButton.hidden) {
    menuButton.hidden = YES; // Consume rapid taps before the next native frame.
    menuRequested = true;
  }
}
- (void)tick:(CADisplayLink*)link { @autoreleasepool { Tick(); } }
- (void)background:(NSNotification*)note {
  backgrounded = true;
  displayLink.paused = YES;
  if (session.active() && !inNativeCall) Suspend(true);
}
- (void)foreground:(NSNotification*)note {
  backgrounded = false;
  if (session.active()) displayLink.paused = NO;
}
@end

extern "C" const char* NeoDusklight_ResourcesPath() { return resourcesPath.c_str(); }
extern "C" const char* NeoDusklight_CachePath() { return cachePath.c_str(); }
extern "C" const char* NeoDusklight_UIText(const char* key) {
  auto found = uiText.find(key);
  return found == uiText.end() ? key : found->second.c_str();
}
extern "C" void* NeoDusklight_WindowScene() { return (__bridge void*)hostWindow.windowScene; }
extern "C" void NeoDusklight_WindowReady(void* window) {
  sdlWindow = static_cast<SDL_Window*>(window);
  SDL_SetiOSEventPump(false); // Refresh SDL lifecycle observation after window creation.
  gameWindow = (__bridge UIWindow*)SDL_GetPointerProperty(
      SDL_GetWindowProperties(sdlWindow), SDL_PROP_WINDOW_UIKIT_WINDOW_POINTER, nullptr);
  if (!gameWindow || gameWindow == hostWindow) {
    gameWindow = nil; sdlWindow = nullptr;
    Trace("SDL did not provide a distinct owned game window.");
    Stop();
    return;
  }
  menuButton = [UIButton buttonWithType:UIButtonTypeSystem];
  menuButton.translatesAutoresizingMaskIntoConstraints = NO;
  [menuButton setImage:[UIImage systemImageNamed:@"gearshape.fill"] forState:UIControlStateNormal];
  menuButton.tintColor = UIColor.whiteColor;
  menuButton.backgroundColor = [UIColor.blackColor colorWithAlphaComponent:0.65];
  menuButton.layer.cornerRadius = 22;
  menuButton.hidden = YES; // Reconciled with native UI only after initialization.
  [gameWindow addSubview:menuButton];
  [NSLayoutConstraint activateConstraints:@[
    [menuButton.widthAnchor constraintEqualToConstant:44],
    [menuButton.heightAnchor constraintEqualToConstant:44],
    [menuButton.trailingAnchor constraintEqualToAnchor:gameWindow.safeAreaLayoutGuide.trailingAnchor constant:-8],
    [menuButton.topAnchor constraintEqualToAnchor:gameWindow.safeAreaLayoutGuide.topAnchor constant:8],
  ]];
  [menuButton addTarget:controls action:@selector(openMenu) forControlEvents:UIControlEventTouchUpInside];
  Trace("Owned Metal window attached; single menu entry, native navigation owns menus.");
}
extern "C" void NeoDusklight_RuntimeReady() { session.initialized(); }
extern "C" void NeoDusklight_FirstFrame() {
  if (session.firstFrame()) {
    TraceResources("first_frame");
    Emit("First native game frame submitted for this session.");
  }
}
extern "C" void NeoDusklight_RequestReturn() { Stop(); }
extern "C" int NeoDusklight_LoadGameLanguage() {
  NSNumber* value = [NSUserDefaults.standardUserDefaults objectForKey:@"NeoDusklightGameLanguage"];
  return [value isKindOfClass:NSNumber.class] ? value.intValue : -1;
}
extern "C" void NeoDusklight_SaveGameLanguage(int language) {
  [NSUserDefaults.standardUserDefaults setInteger:language forKey:@"NeoDusklightGameLanguage"];
}
extern "C" int NeoDusklight_ShouldEnableTouch() {
  return ![NSUserDefaults.standardUserDefaults boolForKey:@"NeoDusklightTouchDefaultV1"];
}
extern "C" void NeoDusklight_DidEnableTouch() {
  [NSUserDefaults.standardUserDefaults setBool:YES forKey:@"NeoDusklightTouchDefaultV1"];
}
extern "C" __attribute__((visibility("default")))
const NeoDusklightAPI* NeoDusklight_GetAPI() { return &api; }
