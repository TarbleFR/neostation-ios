// Isolated test-only backend. It deliberately withholds first-frame and STOP
// acknowledgements so the production host's lifecycle cannot infer readiness.
#import <UIKit/UIKit.h>
#include "../ios/Classes/NeoRetroArchCoreAPI.h"
#include <cstring>
#include <cstdio>

static NeoRetroArchEventFn callback;
static void* context;
static uint64_t active;
static uint32_t state = NEO_RA_IDLE;
static bool auto_run;
static bool auto_stop;
static int starts;
static int stops;
static int initializes;
static __weak UIView* host_view;
static UIView* render_view;

static const char* Identity() { return NEO_RETROARCH_RUNTIME_IDENTITY; }
static int Initialize(const NeoRetroArchPaths* paths, char*, size_t) {
  if (!NSThread.isMainThread || !paths || active) return -1;
  initializes++;
  return 0;
}
static void SetCallback(NeoRetroArchEventFn value, void* owner) { callback = value; context = owner; }
static void Emit(uint64_t session, uint32_t event_state) {
  if (session == active) state = event_state;
  if (event_state == NEO_RA_STOPPED || event_state == NEO_RA_FAILED) {
    if (session == active) { [render_view removeFromSuperview]; render_view = nil; active = 0; host_view = nil; }
  }
  if (callback) callback(context, session, NEO_RA_EVENT_STATE, event_state, "{}");
}
static int Start(const NeoRetroArchLaunch* launch, char* error, size_t size) {
  UIView* view = launch ? (__bridge UIView*)launch->host_view : nil;
  if (!NSThread.isMainThread || !launch || active || !view.window) {
    if (size) std::snprintf(error, size, "fake runtime rejected launch boundary");
    return -1;
  }
  active = launch->session_id;
  host_view = view;
  starts++;
  state = NEO_RA_STARTING;
  const uint64_t session = active;
  dispatch_async(dispatch_get_main_queue(), ^{
    if (active != session || state != NEO_RA_STARTING) return;
    // Match the real frontend: its UIKit renderer is attached asynchronously
    // after start() returns. The host menu button must end up above this view.
    render_view = [[UIView alloc] initWithFrame:host_view.bounds];
    render_view.backgroundColor = UIColor.blackColor;
    render_view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [host_view addSubview:render_view];
    if (auto_run) Emit(session, NEO_RA_RUNNING);
  });
  return 0;
}
static int Stop(uint64_t session, char*, size_t) {
  if (!active || active != session) return -1;
  stops++;
  state = NEO_RA_STOPPING;
  if (auto_stop) Emit(session, NEO_RA_STOPPED);
  return 0;
}
static int Pause(uint64_t session, int paused, char*, size_t) {
  if (active != session || (state != NEO_RA_RUNNING && state != NEO_RA_PAUSED)) return -1;
  uint32_t desired = paused ? NEO_RA_PAUSED : NEO_RA_RUNNING;
  if (state != desired) Emit(session, desired);
  return 0;
}
static uint32_t State(uint64_t session) { return session == active ? state : NEO_RA_IDLE; }
static uint64_t Capabilities(uint64_t) { return NEO_RA_CAP_SAVE_STATES | NEO_RA_CAP_CORE_OPTIONS; }
static int Command(uint64_t session, const char*, char* response, size_t size, char*, size_t) {
  if (session != active) return -1;
  const char* result = "{\"success\":true,\"items\":[],\"slots\":[]}";
  if (std::strlen(result) >= size) return -1;
  std::strcpy(response, result);
  return 0;
}
static const NeoRetroArchCoreAPI api = {NEO_RETROARCH_ABI_VERSION, sizeof(NeoRetroArchCoreAPI),
  Identity, Initialize, SetCallback, Start, Stop, Pause, State, Capabilities, Command};
extern "C" const NeoRetroArchCoreAPI* NeoRetroArch_GetAPI() { return &api; }
extern "C" void NeoRetroArchProbeSetAutomatic(int run, int stop) { auto_run = run; auto_stop = stop; }
extern "C" void NeoRetroArchProbeEmit(uint64_t session, uint32_t event_state) { Emit(session, event_state); }
extern "C" uint64_t NeoRetroArchProbeSession() { return active; }
extern "C" int NeoRetroArchProbeStarts() { return starts; }
extern "C" int NeoRetroArchProbeStops() { return stops; }
extern "C" int NeoRetroArchProbeInitializes() { return initializes; }
extern "C" int NeoRetroArchProbeHostAttached() { return host_view != nil && host_view.window != nil; }
