/* Embedded RetroArch frontend adapter. GPL-3.0-or-later, like RetroArch.
 * Runs on the iOS main runloop, between frames, with no second UIApplication.
 * The frontend is source-built; the IPA application executable is never loaded.
 */
#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonDigest.h>
#include "NeoRetroArchCoreAPI.h"
#include "RetroArchMenuInput.h"
extern void NeoRetroArch_ReleaseRenderResources(void);
#include "configuration.h"
#include "retroarch.h"
#include "runloop.h"
#include "core.h"
#include "core_option_manager.h"
#include "content.h"
#include "command.h"
#include "cheat_manager.h"
#include "gfx/video_driver.h"
#include "gfx/video_shader_parse.h"
#include "input/input_driver.h"
#include "tasks/tasks_internal.h"
#include "ui/drivers/cocoa/apple_platform.h"
#include "ui/drivers/cocoa/cocoa_common.h"

static NSDictionary *g_paths;
static NSDictionary *g_core;
static NSString *g_game;
static NSString *g_cheat_file;
static NSString *g_active_shader;
static NSString *g_pending_overlay;
static NSTimeInterval g_overlay_deadline;
static UIView *g_host;
static RetroArch_iOS *g_controller;
static NeoRetroArchEventFn g_callback;
static void *g_context;
static uint64_t g_session;
static uint32_t g_state = NEO_RA_IDLE;
static bool g_initialized_frontend;
static bool g_in_frame;
static NeoRetroArchMenuInputState g_chord[16];

static NSString *str(const char *v) { return v ? [NSString stringWithUTF8String:v] : @""; }
static void error_text(char *out, size_t size, NSString *value) {
  if (out && size) snprintf(out, size, "%s", value.UTF8String ?: "native_error");
}
static NSString *json(NSDictionary *value) {
  NSData *data = [NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
  return data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"{}";
}
static void emit(uint32_t event, NSDictionary *detail) {
  if (g_callback && g_session)
    g_callback(g_context, g_session, event, g_state, json(detail).UTF8String);
}
static void state(uint32_t value, NSString *code, NSString *detail) {
  g_state = value;
  emit(NEO_RA_EVENT_STATE, @{ @"errorCode":code ?: @"", @"detail":detail ?: @"" });
}
static BOOL within(NSString *value, NSString *directory) {
  NSString *p = value.stringByStandardizingPath.stringByResolvingSymlinksInPath;
  NSString *r = directory.stringByStandardizingPath.stringByResolvingSymlinksInPath;
  return [p hasPrefix:[r stringByAppendingString:@"/"]];
}
static NSArray *files(NSString *directory, NSString *extension, NSString *active) {
  NSMutableArray *items = [NSMutableArray array];
  NSFileManager *fm = NSFileManager.defaultManager;
  for (NSString *relative in [fm enumeratorAtPath:directory]) {
    if (items.count >= 1024) break;
    NSString *path = [directory stringByAppendingPathComponent:relative];
    if (![relative.pathExtension.lowercaseString isEqual:extension] || !within(path,directory)) continue;
    BOOL isDirectory = NO;
    if (![fm fileExistsAtPath:path isDirectory:&isDirectory] || isDirectory) continue;
    [items addObject:@{ @"title":relative, @"path":path, @"active":@([path isEqual:active]) }];
  }
  return [items sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
    return [a[@"title"] localizedStandardCompare:b[@"title"]];
  }];
}
static UIViewController *owner(UIView *view) {
  UIResponder *r = view;
  while ((r = r.nextResponder)) if ([r isKindOfClass:UIViewController.class]) return (UIViewController *)r;
  return nil;
}
static void finish(BOOL failed, NSString *code, NSString *detail) {
  if (g_state == NEO_RA_STOPPED || g_state == NEO_RA_FAILED) return;
  rarch_stop_draw_observer();
  CocoaView *cocoa = (__bridge CocoaView *)nsview_get_ptr();
  cocoa.displayLink.paused = YES;
  if (g_initialized_frontend) {
    command_event(CMD_EVENT_SAVE_FILES, NULL);
    runloop_core_options_save();
    main_exit(NULL);
    g_initialized_frontend = false;
  }
  [g_controller willMoveToParentViewController:nil];
  [g_controller.view removeFromSuperview];
  [g_controller removeFromParentViewController];
  [g_controller setViewType:APPLE_VIEW_TYPE_NONE];
  g_controller = nil;
  apple_platform = nil;
  NeoRetroArch_ReleaseRenderResources();
  [cocoa.displayLink invalidate];
  cocoa.displayLink = nil;
  nsview_set_ptr(nil);
  g_host = nil;
  g_pending_overlay = nil;
  memset(g_chord,0,sizeof(g_chord));
  state(failed ? NEO_RA_FAILED : NEO_RA_STOPPED,code,detail);
}

/* Called by the patched GL2 driver only after it submitted a nonempty game
 * frame to GLKView. Initialization/core loading alone never emits RUNNING. */
void NeoRetroArch_FramePresented(void) {
  if (g_state == NEO_RA_STARTING && (runloop_get_flags() & RUNLOOP_FLAG_CORE_RUNNING))
    state(NEO_RA_RUNNING,@"",@"");
}
void NeoRetroArch_RequestMenu(void) {
  if (g_state != NEO_RA_RUNNING && g_state != NEO_RA_PAUSED) return;
  const uint64_t sid = g_session;
  dispatch_async(dispatch_get_main_queue(), ^{
    if (sid == g_session && (g_state == NEO_RA_RUNNING || g_state == NEO_RA_PAUSED))
      emit(NEO_RA_EVENT_MENU_REQUESTED,@{});
  });
}
/* Consume Select+Start and both buttons until both have been released. */
uint32_t NeoRetroArch_FilterButtons(unsigned port, uint32_t buttons) {
  if (port >= 16) return buttons;
  uint16_t pad = (uint16_t)(buttons & UINT16_MAX);
  if (NeoRetroArchMenuInputConsume(&g_chord[port], &pad, 1)) NeoRetroArch_RequestMenu();
  buttons = (buttons & ~UINT16_MAX) | pad;
  return buttons;
}
void NeoRetroArch_ControllerDisconnected(unsigned port) {
  if (port < 16) NeoRetroArchMenuInputReset(&g_chord[port]);
}
void NeoRetroArch_OverlayFailed(const char *detail) {
  if (!g_pending_overlay || g_state == NEO_RA_STOPPED || g_state == NEO_RA_FAILED) return;
  emit(NEO_RA_EVENT_COMMAND_RESULT,@{ @"command":@"applyOverlay", @"success":@NO, @"errorCode":@"overlay_load_failed", @"detail":str(detail), @"path":g_pending_overlay });
  g_pending_overlay = nil;
}
void NeoRetroArch_Tick(void) {
  if (g_in_frame || (g_state != NEO_RA_STARTING && g_state != NEO_RA_RUNNING && g_state != NEO_RA_PAUSED)) return;
  if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
  g_in_frame = true;
  int result = runloop_iterate();
  task_queue_check();
  g_in_frame = false;
  if (g_pending_overlay) {
    input_overlay_t *overlay = input_state_get_ptr()->overlay_ptr;
    if (overlay && (overlay->flags & INPUT_OVERLAY_ALIVE) && input_overlay_has_source(overlay) && [str(overlay->path) isEqual:g_pending_overlay]) {
      emit(NEO_RA_EVENT_COMMAND_RESULT,@{ @"command":@"applyOverlay", @"success":@YES, @"path":g_pending_overlay });
      g_pending_overlay = nil;
    } else if (NSDate.timeIntervalSinceReferenceDate > g_overlay_deadline) {
      NeoRetroArch_OverlayFailed("overlay readiness timed out");
    }
  }
  if (result == -1) finish(NO,@"",@"");
}

static const char *identity(void) { return NEO_RETROARCH_RUNTIME_IDENTITY; }
static int initialize(const NeoRetroArchPaths *paths, char *error, size_t size) {
  if (!NSThread.isMainThread || !paths || paths->size < sizeof(*paths)) {
    error_text(error,size,@"invalid_paths_or_thread"); return -1;
  }
  if (g_state == NEO_RA_STARTING || g_state == NEO_RA_RUNNING || g_state == NEO_RA_PAUSED || g_state == NEO_RA_STOPPING) {
    error_text(error,size,@"session_active"); return -1;
  }
  g_paths = @{ @"root":str(paths->root_path), @"system":str(paths->system_path), @"saves":str(paths->save_path),
    @"states":str(paths->state_path), @"config":str(paths->config_path), @"shaders":str(paths->shader_path),
    @"overlays":str(paths->overlay_path), @"cheats":str(paths->cheat_path), @"logs":str(paths->log_path).stringByDeletingLastPathComponent };
  NSFileManager *fm = NSFileManager.defaultManager;
  NSString *documents = [fm URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject.path;
  if (!within(g_paths[@"root"],documents)) { error_text(error,size,@"root_outside_documents"); return -1; }
  for (NSString *key in g_paths) {
    NSString *path = g_paths[key];
    if ([key isEqual:@"root"] ? !path.length : !within(path,g_paths[@"root"])) {
      error_text(error,size,@"directory_outside_retroarch_root"); return -1;
    }
    NSError *e = nil;
    if (![fm createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:&e]) {
      error_text(error,size,e.description); return -1;
    }
  }
  return 0;
}
static void callback(NeoRetroArchEventFn cb, void *context) { g_callback = cb; g_context = context; }
static NSString *escaped(NSString *path) {
  return [[path stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"] stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
}
static int language(NSString *locale) {
  if ([locale hasPrefix:@"zh-Hant"] || [locale hasPrefix:@"zh_Hant"] || [locale hasPrefix:@"zh_TW"]) locale=@"zh_Hant";
  else locale=[[locale componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"_-"]] firstObject];
  NSDictionary *map = @{ @"en":@(RETRO_LANGUAGE_ENGLISH), @"fr":@(RETRO_LANGUAGE_FRENCH),
    @"es":@(RETRO_LANGUAGE_SPANISH), @"ru":@(RETRO_LANGUAGE_RUSSIAN), @"zh":@(RETRO_LANGUAGE_CHINESE_SIMPLIFIED),
    @"zh_Hant":@(RETRO_LANGUAGE_CHINESE_TRADITIONAL), @"pt":@(RETRO_LANGUAGE_PORTUGUESE_BRAZIL),
    @"de":@(RETRO_LANGUAGE_GERMAN), @"it":@(RETRO_LANGUAGE_ITALIAN), @"id":@(RETRO_LANGUAGE_INDONESIAN),
    @"ja":@(RETRO_LANGUAGE_JAPANESE), @"ko":@(RETRO_LANGUAGE_KOREAN) };
  return [(map[locale] ?: @(RETRO_LANGUAGE_ENGLISH)) intValue];
}
static int start(const NeoRetroArchLaunch *launch, char *error, size_t size) {
  if (!NSThread.isMainThread || !g_paths || !launch || launch->size < sizeof(*launch) || !launch->session_id || !launch->host_view) {
    error_text(error,size,@"invalid_launch_or_thread"); return -1;
  }
  if (g_state == NEO_RA_STARTING || g_state == NEO_RA_RUNNING || g_state == NEO_RA_PAUSED || g_state == NEO_RA_STOPPING) {
    error_text(error,size,@"session_active"); return -1;
  }
  NSString *corePath = str(launch->core_path);
  NSString *gamePath = str(launch->game_path);
  NSString *bundlePath = NSBundle.mainBundle.bundlePath;
  NSString *manifestPath = [bundlePath stringByAppendingPathComponent:@"retroarch-core-manifest.json"];
  NSDictionary *manifest = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:manifestPath] ?: NSData.data options:0 error:nil];
  NSDictionary *selected = nil;
  for (NSDictionary *entry in manifest[@"cores"])
    if ([[bundlePath stringByAppendingPathComponent:entry[@"binary"]] isEqual:corePath]) selected = entry;
  BOOL directory = NO;
  NSString *documents = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject.path;
  if (!selected || !within(corePath,[bundlePath stringByAppendingPathComponent:@"Frameworks"]) || !within(gamePath,documents)
      || ![NSFileManager.defaultManager fileExistsAtPath:gamePath isDirectory:&directory] || directory) {
    error_text(error,size,@"uncurated_core_or_invalid_game"); return -1;
  }
  g_core = selected; g_game = gamePath; g_session = launch->session_id;
  g_host = (__bridge UIView *)launch->host_view;
  g_active_shader = @"";
  NSString *locale = str(launch->locale);
  const uint64_t sid = g_session;
  state(NEO_RA_STARTING,@"",@"");
  dispatch_async(dispatch_get_main_queue(), ^{
    if (sid != g_session || g_state != NEO_RA_STARTING) return;
    @autoreleasepool {
      NSString *base = [g_paths[@"config"] stringByAppendingPathComponent:@"retroarch.cfg"];
      NSString *session = [g_paths[@"config"] stringByAppendingPathComponent:@"neostation-session.cfg"];
      if (![NSFileManager.defaultManager fileExistsAtPath:base])
        if (![@"video_smooth = \"false\"\n" writeToFile:base atomically:YES encoding:NSUTF8StringEncoding error:nil]) {
          finish(YES,@"config_write_failed",base); return;
        }
      NSMutableString *cfg = [NSMutableString stringWithString:
        @"video_driver = \"gl\"\nvideo_threaded = \"false\"\nvideo_vsync = \"true\"\n"
         "menu_driver = \"rgui\"\nmenu_pause_libretro = \"true\"\nconfig_save_on_exit = \"false\"\n"
         "input_driver = \"cocoa\"\ninput_joypad_driver = \"mfi\"\naudio_driver = \"coreaudio\"\n"
         "savestate_auto_load = \"false\"\nsavestate_auto_save = \"false\"\n"
         "sort_savefiles_enable = \"true\"\nsort_savestates_enable = \"true\"\n"
         "log_to_file = \"true\"\nlog_to_file_timestamp = \"true\"\n"
         "menu_show_load_core = \"false\"\nmenu_show_online_updater = \"false\"\n"
         "input_menu_toggle_gamepad_combo = \"0\"\ninput_overlay_hide_in_menu = \"false\"\n"
         "input_overlay_enable_autopreferred = \"false\"\n"];
      NSDictionary *keys = @{ @"system":@"system_directory", @"saves":@"savefile_directory", @"states":@"savestate_directory",
        @"shaders":@"video_shader_dir", @"overlays":@"overlay_directory", @"cheats":@"cheat_database_path", @"logs":@"log_dir" };
      for (NSString *key in keys) [cfg appendFormat:@"%@ = \"%@\"\n",keys[key],escaped(g_paths[key])];
      [cfg appendFormat:@"core_assets_directory = \"%@\"\nassets_directory = \"%@/assets\"\ncore_info_path = \"%@/info\"\n"
         "joypad_autoconfig_dir = \"%@/autoconfig\"\nuser_language = \"%d\"\n",
         escaped(g_paths[@"root"]),escaped(g_paths[@"root"]),escaped(g_paths[@"root"]),escaped(g_paths[@"root"]),language(locale)];
      NSString *defaultOverlay = [g_paths[@"overlays"] stringByAppendingPathComponent:@"gamepads/retropad/retropad.cfg"];
      if ([NSFileManager.defaultManager fileExistsAtPath:defaultOverlay])
        [cfg appendFormat:@"input_overlay = \"%@\"\ninput_overlay_enable = \"true\"\n",escaped(defaultOverlay)];
      if (![cfg writeToFile:session atomically:YES encoding:NSUTF8StringEncoding error:nil]) {
        finish(YES,@"config_write_failed",session); return;
      }
      CocoaView *cocoa = [CocoaView get];
      cocoa.displayLink.paused = YES;
      g_controller = [[RetroArch_iOS alloc] initWithRootViewController:cocoa];
      g_controller.window = g_host.window;
      [g_controller setNavigationBarHidden:YES animated:NO];
      apple_platform = g_controller;
      UIViewController *parent = owner(g_host);
      if (parent) [parent addChildViewController:g_controller];
      g_controller.view.frame = g_host.bounds;
      g_controller.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
      [g_host addSubview:g_controller.view];
      if (parent) [g_controller didMoveToParentViewController:parent];
      NSArray<NSString *> *args = @[@"retroarch",@"-c",base,@"--appendconfig",session,@"-L",corePath,gamePath];
      char *argv[9] = {0};
      for (NSUInteger i=0;i<args.count;i++) argv[i] = (char *)args[i].UTF8String;
      g_initialized_frontend = true;
      int result = rarch_main((int)args.count,argv,NULL);
      if (result != 0 || !(runloop_get_flags() & RUNLOOP_FLAG_CORE_RUNNING)) {
        finish(YES,@"frontend_load_failed",[NSString stringWithFormat:@"rarch_main=%d core=%@ game=%@",result,corePath,gamePath]); return;
      }
      // PCSX ReARMed is part of the App Store subset; stay on its interpreter
      // even if NeoStation has JIT enabled for a different standalone backend.
      core_option_manager_t *opts = runloop_state_get_ptr()->core_options;
      size_t drc = 0;
      if (opts && core_option_manager_get_idx(opts,"pcsx_rearmed_drc",&drc)) {
        struct core_option *option = &opts->opts[drc];
        for (size_t i=0;i<option->vals->size;i++)
          if (strcmp(option->vals->elems[i].data,"disabled")==0) core_option_manager_set_val(opts,drc,i,false);
      }
      NSData *name = [[g_core[@"id"] stringByAppendingString:g_game] dataUsingEncoding:NSUTF8StringEncoding];
      unsigned char digest[CC_SHA256_DIGEST_LENGTH]; CC_SHA256(name.bytes,(CC_LONG)name.length,digest);
      NSMutableString *hash = [NSMutableString string]; for (int i=0;i<16;i++) [hash appendFormat:@"%02x",digest[i]];
      g_cheat_file = [g_paths[@"cheats"] stringByAppendingPathComponent:[hash stringByAppendingString:@".cht"]];
      if ([g_core[@"cheats"] boolValue] && [NSFileManager.defaultManager fileExistsAtPath:g_cheat_file]) {
        if (cheat_manager_load(g_cheat_file.UTF8String,false)) cheat_manager_apply_cheats(false);
      }
      cocoa.displayLink.paused = NO;
    }
  });
  return 0;
}
static int stop(uint64_t session, char *error, size_t size) {
  if (!NSThread.isMainThread || session != g_session || !session) { error_text(error,size,@"stale_session"); return -1; }
  if (g_state == NEO_RA_STOPPED || g_state == NEO_RA_FAILED) return 0;
  state(NEO_RA_STOPPING,@"",@"");
  dispatch_async(dispatch_get_main_queue(), ^{ if (session == g_session && g_state == NEO_RA_STOPPING) finish(NO,@"",@""); });
  return 0;
}
static int pause_session(uint64_t session, int paused, char *error, size_t size) {
  if (!NSThread.isMainThread || session != g_session || (g_state != NEO_RA_RUNNING && g_state != NEO_RA_PAUSED)) {
    error_text(error,size,@"session_not_running"); return -1;
  }
  if (paused) runloop_state_get_ptr()->flags |= RUNLOOP_FLAG_PAUSED;
  else runloop_state_get_ptr()->flags &= ~RUNLOOP_FLAG_PAUSED;
  state(paused ? NEO_RA_PAUSED : NEO_RA_RUNNING,@"",@"");
  return 0;
}
static uint32_t session_state(uint64_t session) { return session == g_session ? g_state : NEO_RA_IDLE; }
static uint64_t capabilities(uint64_t session) {
  if (session != g_session || (g_state != NEO_RA_RUNNING && g_state != NEO_RA_PAUSED)) return 0;
  uint64_t result = NEO_RA_CAP_OVERLAYS;
  if (core_serialize_size() > 0) result |= NEO_RA_CAP_SAVE_STATES;
  if (runloop_state_get_ptr()->core_options) result |= NEO_RA_CAP_CORE_OPTIONS;
  video_driver_state_t *v = video_state_get_ptr();
  if (v->current_video && v->current_video->set_shader && [str(video_driver_get_ident()) isEqual:@"gl"]) result |= NEO_RA_CAP_SHADERS;
  if ([g_core[@"cheats"] boolValue]) result |= NEO_RA_CAP_CHEATS;
  return result;
}
static NSDictionary *failure(NSString *code, NSString *detail) { return @{ @"success":@NO,@"errorCode":code,@"detail":detail ?: @"" }; }
static NSDictionary *perform(NSDictionary *request) {
  NSString *op = request[@"command"] ?: request[@"operation"] ?: request[@"action"];
  if (![op isKindOfClass:NSString.class] || !op.length) return failure(@"invalid_command",@"");
  if ([op isEqual:@"readStates"] || [op isEqual:@"saveState"] || [op isEqual:@"loadState"]) {
    if (!(capabilities(g_session) & NEO_RA_CAP_SAVE_STATES)) return failure(@"unsupported",op);
    if ([op isEqual:@"readStates"]) {
      NSMutableArray *slots = [NSMutableArray array];
      for (int slot=0;slot<10;slot++) {
        char path[PATH_MAX_LENGTH]={0};
        if (!runloop_get_savestate_path(path,sizeof(path),slot)) continue;
        NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:str(path) error:nil];
        [slots addObject:@{ @"slot":@(slot),@"exists":@(attrs != nil),@"modified":@([attrs[NSFileModificationDate] timeIntervalSince1970]) }];
      }
      return @{ @"success":@YES,@"slots":slots };
    }
    id value = request[@"slot"];
    if (![value isKindOfClass:NSNumber.class] || [value intValue] < 0 || [value intValue] > 9) return failure(@"invalid_slot",@"");
    char rawPath[PATH_MAX_LENGTH]={0};
    if (!runloop_get_savestate_path(rawPath,sizeof(rawPath),[value intValue])) return failure(@"state_path_failed",@"");
    NSString *path = str(rawPath);
    if (!within(path,g_paths[@"states"])) return failure(@"state_path_outside_root",path);
    if ([op isEqual:@"saveState"]) {
      size_t length = core_serialize_size();
      if (!length || length > 128 * 1024 * 1024) return failure(@"state_size_invalid",@"");
      NSMutableData *data = [NSMutableData dataWithLength:length];
      if (!data) return failure(@"state_allocation_failed",@"");
      retro_ctx_serialize_info_t info = { .data=data.mutableBytes,.data_const=NULL,.size=data.length };
      if (!core_serialize(&info)) return failure(@"serialize_failed",path);
      NSError *err = nil;
      if (![NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:&err]
          || ![data writeToFile:path options:NSDataWritingAtomic error:&err]) return failure(@"state_write_failed",err.description);
      return @{ @"success":@YES,@"slot":value,@"path":path,@"format":@"libretro-raw" };
    }
    NSData *data = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];
    if (!data) return failure(@"state_read_failed",path);
    size_t expected = core_serialize_size();
    if (data.length != expected) return failure(@"state_format_or_size_invalid",@"Expected libretro raw state for this core and content revision");
    retro_ctx_serialize_info_t info = { .data=NULL,.data_const=data.bytes,.size=data.length };
    if (!core_unserialize(&info)) return failure(@"unserialize_failed",path);
    return @{ @"success":@YES,@"slot":value };
  }
  if ([op isEqual:@"readOptions"] || [op isEqual:@"setOption"]) {
    core_option_manager_t *manager = runloop_state_get_ptr()->core_options;
    if (!manager) return failure(@"unsupported",op);
    if ([op isEqual:@"readOptions"]) {
      NSMutableArray *items = [NSMutableArray array];
      for (size_t i=0;i<manager->size;i++) {
        if (!core_option_manager_get_visible(manager,i)) continue;
        struct core_option *option = &manager->opts[i];
        NSMutableArray *choices = [NSMutableArray array];
        for (size_t j=0;j<option->vals->size;j++)
          [choices addObject:@{ @"value":str(option->vals->elems[j].data),@"title":str(option->val_labels && j < option->val_labels->size ? option->val_labels->elems[j].data : option->vals->elems[j].data) }];
        [items addObject:@{ @"key":str(option->key),@"title":str(core_option_manager_get_desc(manager,i,false)),
          @"value":str(core_option_manager_get_val(manager,i)),@"choices":choices }];
      }
      return @{ @"success":@YES,@"items":items };
    }
    NSString *key = request[@"key"], *value = request[@"value"];
    if ([key isEqual:@"pcsx_rearmed_drc"] && ![value isEqual:@"disabled"]) return failure(@"jit_unavailable",key);
    size_t index=0;
    if (![key isKindOfClass:NSString.class] || ![value isKindOfClass:NSString.class] || !core_option_manager_get_idx(manager,key.UTF8String,&index))
      return failure(@"invalid_option",key);
    struct core_option *option = &manager->opts[index];
    for (size_t i=0;i<option->vals->size;i++) if ([str(option->vals->elems[i].data) isEqual:value]) {
      core_option_manager_set_val(manager,index,i,false);
      runloop_core_options_save();
      return @{ @"success":@YES,@"restartMayBeRequired":@YES };
    }
    return failure(@"invalid_option_value",value);
  }
  if ([op isEqual:@"readShaders"] || [op isEqual:@"applyShader"]) {
    if (!(capabilities(g_session) & NEO_RA_CAP_SHADERS)) return failure(@"unsupported",op);
    if ([op isEqual:@"readShaders"]) return @{ @"success":@YES,@"items":files(g_paths[@"shaders"],@"glslp",g_active_shader),@"formats":@[@"glslp"] };
    NSString *path = request[@"path"];
    if (![path isKindOfClass:NSString.class] || (path.length && (!within(path,g_paths[@"shaders"]) || ![path.pathExtension.lowercaseString isEqual:@"glslp"])))
      return failure(@"invalid_shader_path",path);
    if (!command_set_shader(NULL,path.UTF8String)) return failure(@"shader_apply_failed",path);
    g_active_shader = path;
    return @{ @"success":@YES };
  }
  if ([op isEqual:@"readOverlays"] || [op isEqual:@"applyOverlay"]) {
    input_overlay_t *overlay = input_state_get_ptr()->overlay_ptr;
    NSString *active = overlay ? str(overlay->path) : @"";
    if ([op isEqual:@"readOverlays"]) return @{ @"success":@YES,@"items":files(g_paths[@"overlays"],@"cfg",active) };
    NSString *path = request[@"path"];
    if (![path isKindOfClass:NSString.class] || (path.length && (!within(path,g_paths[@"overlays"]) || ![path.pathExtension.lowercaseString isEqual:@"cfg"])))
      return failure(@"invalid_overlay_path",path);
    if (path.length) {
      config_file_t *cfg = config_file_new_from_path_to_string(path.UTF8String);
      unsigned count=0;
      if (!cfg || !config_get_uint(cfg,"overlays",&count) || !count) {
        if (cfg) config_file_free(cfg); return failure(@"invalid_overlay_config",path);
      }
      config_file_free(cfg);
    }
    settings_t *settings=config_get_ptr();
    configuration_set_string(settings,settings->paths.path_overlay,path.UTF8String);
    configuration_set_bool(settings,settings->bools.input_overlay_enable,path.length > 0);
    input_overlay_unload();
    if (!path.length) { g_pending_overlay=nil; return @{ @"success":@YES }; }
    g_pending_overlay=path;
    g_overlay_deadline=NSDate.timeIntervalSinceReferenceDate+15;
    input_overlay_init();
    return @{ @"success":@YES,@"pending":@YES };
  }
  if ([op isEqual:@"readCheats"] || [op isEqual:@"setCheat"] || [op isEqual:@"addCheat"] || [op isEqual:@"deleteCheat"] || [op isEqual:@"importCheats"]) {
    if (!(capabilities(g_session) & NEO_RA_CAP_CHEATS)) return failure(@"unsupported",op);
    cheat_manager_t *manager = &cheat_manager_state;
    if ([op isEqual:@"readCheats"]) {
      NSMutableArray *items = [NSMutableArray array];
      for (unsigned i=0;i<manager->size;i++)
        [items addObject:@{ @"index":@(i),@"title":str(cheat_manager_get_desc(i)),@"code":str(cheat_manager_get_code(i)),@"enabled":@(cheat_manager_get_code_state(i)) }];
      return @{ @"success":@YES,@"items":items };
    }
    if ([op isEqual:@"importCheats"]) {
      NSString *path = request[@"path"];
      if (![path isKindOfClass:NSString.class] || !within(path,g_paths[@"cheats"]) || ![path.pathExtension.lowercaseString isEqual:@"cht"])
        return failure(@"invalid_cheat_path",path);
      if (!cheat_manager_load(path.UTF8String,false)) return failure(@"cheat_import_failed",path);
    } else if ([op isEqual:@"addCheat"]) {
      NSString *code=request[@"code"],*description=request[@"description"];
      if (![code isKindOfClass:NSString.class] || !code.length || [code lengthOfBytesUsingEncoding:NSUTF8StringEncoding] >= CHEAT_CODE_SCRATCH_SIZE
          || ![description isKindOfClass:NSString.class] || [description lengthOfBytesUsingEncoding:NSUTF8StringEncoding] >= CHEAT_DESC_SCRATCH_SIZE || manager->size >= 4096)
        return failure(@"invalid_cheat",@"");
      char *newCode=strdup(code.UTF8String),*newDesc=strdup(description.UTF8String);
      if (!newCode || !newDesc) { free(newCode);free(newDesc);return failure(@"cheat_allocation_failed",@""); }
      unsigned index=manager->size;
      if (!cheat_manager_realloc(index+1,CHEAT_HANDLER_TYPE_EMU)) { free(newCode);free(newDesc);return failure(@"cheat_allocation_failed",@""); }
      free(manager->cheats[index].code);free(manager->cheats[index].desc);
      manager->cheats[index].code=newCode;manager->cheats[index].desc=newDesc;
      manager->cheats[index].state=[request[@"enabled"] boolValue];
    } else {
      id value=request[@"index"];
      if (![value isKindOfClass:NSNumber.class] || [value integerValue]<0 || [value unsignedIntegerValue]>=manager->size)
        return failure(@"invalid_cheat_index",@"");
      unsigned index=[value unsignedIntValue];
      if ([op isEqual:@"setCheat"]) manager->cheats[index].state=[request[@"enabled"] boolValue];
      else {
        free(manager->cheats[index].code);free(manager->cheats[index].desc);
        memmove(&manager->cheats[index],&manager->cheats[index+1],(manager->size-index-1)*sizeof(struct item_cheat));
        memset(&manager->cheats[manager->size-1],0,sizeof(struct item_cheat));
        manager->size--;
        for (unsigned i=0;i<manager->size;i++) manager->cheats[i].idx=i;
      }
    }
    cheat_manager_apply_cheats(false);
    if (!cheat_manager_save(g_cheat_file.UTF8String,g_paths[@"cheats"].UTF8String,true)) return failure(@"cheat_save_failed",g_cheat_file);
    return @{ @"success":@YES,@"codeValidation":@"core-defined" };
  }
  return failure(@"unsupported_command",op);
}
static int command(uint64_t session, const char *request, char *response, size_t capacity, char *error, size_t errorSize) {
  if (!NSThread.isMainThread || g_in_frame || session != g_session || (g_state != NEO_RA_RUNNING && g_state != NEO_RA_PAUSED)) {
    error_text(error,errorSize,@"session_or_thread_invalid"); return -1;
  }
  if (!response || capacity < 1024) { error_text(error,errorSize,@"response_buffer_too_small"); return -1; }
  NSData *input=[str(request) dataUsingEncoding:NSUTF8StringEncoding];
  id value = input ? [NSJSONSerialization JSONObjectWithData:input options:0 error:nil] : nil;
  NSDictionary *result=[value isKindOfClass:NSDictionary.class] ? perform(value) : failure(@"invalid_json",@"");
  NSData *output=[json(result) dataUsingEncoding:NSUTF8StringEncoding];
  if (!response || capacity <= output.length) { error_text(error,errorSize,@"response_buffer_too_small"); return -1; }
  memcpy(response,output.bytes,output.length);response[output.length]=0;
  return [result[@"success"] boolValue] ? 0 : -1;
}
static const NeoRetroArchCoreAPI api = {
  .abi_version=NEO_RETROARCH_ABI_VERSION,.struct_size=sizeof(NeoRetroArchCoreAPI),.runtime_identity=identity,
  .initialize=initialize,.set_event_callback=callback,.start=start,.request_stop=stop,.set_paused=pause_session,
  .session_state=session_state,.capabilities=capabilities,.command=command
};
__attribute__((visibility("default"))) const NeoRetroArchCoreAPI *NeoRetroArch_GetAPI(void) { return &api; }
