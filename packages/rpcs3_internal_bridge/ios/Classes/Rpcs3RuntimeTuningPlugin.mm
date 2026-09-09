#import "Rpcs3RuntimeTuningPlugin.h"

#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <stdint.h>
#import <string.h>

static NSString* const kRpcs3TuningChannel = @"neostation/rpcs3_tuning";

#ifndef RTLD_NOLOAD
#define RTLD_NOLOAD 0x10
#endif

typedef int32_t (*rpcs3_set_setting_fn)(const char* key, const char* value);
typedef int32_t (*rpcs3_set_game_setting_fn)(const char* title_id,
                                              const char* key,
                                              const char* value);
typedef int32_t (*rpcs3_delete_game_fn)(const char* title_id);
typedef int32_t (*rpcs3_get_boot_progress_fn)(uint32_t* current,
                                               uint32_t* total,
                                               char* stage,
                                               size_t stage_capacity);
typedef const char* (*rpcs3_last_error_fn)(void);

static void* RPCS3OpenLoadedCore(void) {
  NSString* frameworks = NSBundle.mainBundle.privateFrameworksPath ?: @"";
  NSArray<NSString*>* candidates = @[
    [frameworks stringByAppendingPathComponent:@"libRPCS3Core.dylib"],
    [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Frameworks/libRPCS3Core.dylib"],
  ];
  for (NSString* path in candidates) {
    if (![NSFileManager.defaultManager fileExistsAtPath:path]) continue;
    void* handle = dlopen(path.fileSystemRepresentation,
                          RTLD_LAZY | RTLD_LOCAL | RTLD_NOLOAD);
    if (handle) return handle;
  }
  return NULL;
}

static NSString* RPCS3TuningLastError(void* handle) {
  if (!handle) return @"RPCS3 Core is not loaded.";
  auto lastError = reinterpret_cast<rpcs3_last_error_fn>(
      dlsym(handle, "rpcs3_ios_last_error"));
  if (!lastError) return @"RPCS3 returned an unknown runtime error.";
  const char* message = lastError();
  return message && message[0]
      ? ([NSString stringWithUTF8String:message] ?: @"RPCS3 runtime error.")
      : @"RPCS3 runtime error.";
}

@interface Rpcs3RuntimeTuningPlugin ()
@property(nonatomic, strong) FlutterMethodChannel* channel;
@property(nonatomic, strong) dispatch_queue_t queue;
@end

@implementation Rpcs3RuntimeTuningPlugin

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar {
  FlutterMethodChannel* channel = [FlutterMethodChannel
      methodChannelWithName:kRpcs3TuningChannel
            binaryMessenger:registrar.messenger];
  Rpcs3RuntimeTuningPlugin* instance = [Rpcs3RuntimeTuningPlugin new];
  instance.channel = channel;
  instance.queue = dispatch_queue_create(
      "com.neogamelab.neostation.rpcs3.tuning", DISPATCH_QUEUE_SERIAL);
  [registrar addMethodCallDelegate:instance channel:channel];
}

- (void)handleMethodCall:(FlutterMethodCall*)call result:(FlutterResult)result {
  if ([call.method isEqualToString:@"setSetting"]) {
    NSDictionary* args = [call.arguments isKindOfClass:NSDictionary.class]
        ? call.arguments
        : @{};
    NSString* key = [args[@"key"] isKindOfClass:NSString.class]
        ? args[@"key"]
        : @"";
    NSString* value = [args[@"value"] isKindOfClass:NSString.class]
        ? args[@"value"]
        : @"";
    if (key.length == 0 || value.length == 0) {
      result(@{@"success": @NO,
               @"message": @"A RPCS3 setting key and value are required."});
      return;
    }

    dispatch_async(self.queue, ^{
      void* handle = RPCS3OpenLoadedCore();
      if (!handle) {
        dispatch_async(dispatch_get_main_queue(), ^{
          result(@{@"success": @NO,
                   @"message": @"RPCS3 Core must be initialized before changing settings."});
        });
        return;
      }
      auto setSetting = reinterpret_cast<rpcs3_set_setting_fn>(
          dlsym(handle, "rpcs3_ios_set_setting"));
      if (!setSetting) {
        dlclose(handle);
        dispatch_async(dispatch_get_main_queue(), ^{
          result(@{@"success": @NO,
                   @"message": @"This RPCS3 Core does not expose runtime settings."});
        });
        return;
      }
      int32_t status = setSetting(key.UTF8String, value.UTF8String);
      NSString* message = status == 0 ? @"" : RPCS3TuningLastError(handle);
      dlclose(handle);
      dispatch_async(dispatch_get_main_queue(), ^{
        result(status == 0
            ? @{@"success": @YES}
            : @{@"success": @NO,
                @"status": @(status),
                @"message": message});
      });
    });
    return;
  }

  if ([call.method isEqualToString:@"setGameSetting"]) {
    NSDictionary* args = [call.arguments isKindOfClass:NSDictionary.class]
        ? call.arguments
        : @{};
    NSString* titleId = [args[@"titleId"] isKindOfClass:NSString.class]
        ? args[@"titleId"]
        : @"";
    NSString* key = [args[@"key"] isKindOfClass:NSString.class]
        ? args[@"key"]
        : @"";
    NSString* value = [args[@"value"] isKindOfClass:NSString.class]
        ? args[@"value"]
        : @"";
    if (titleId.length == 0 || key.length == 0 || value.length == 0) {
      result(@{@"success": @NO,
               @"message": @"A RPCS3 title ID, setting key and value are required."});
      return;
    }

    dispatch_async(self.queue, ^{
      void* handle = RPCS3OpenLoadedCore();
      if (!handle) {
        dispatch_async(dispatch_get_main_queue(), ^{
          result(@{@"success": @NO,
                   @"message": @"RPCS3 Core must be initialized before changing game settings."});
        });
        return;
      }
      auto setGameSetting = reinterpret_cast<rpcs3_set_game_setting_fn>(
          dlsym(handle, "rpcs3_ios_set_game_setting"));
      if (!setGameSetting) {
        dlclose(handle);
        dispatch_async(dispatch_get_main_queue(), ^{
          result(@{@"success": @NO,
                   @"message": @"This RPCS3 Core does not expose per-game runtime settings."});
        });
        return;
      }
      int32_t status = setGameSetting(
          titleId.UTF8String, key.UTF8String, value.UTF8String);
      NSString* message = status == 0 ? @"" : RPCS3TuningLastError(handle);
      dlclose(handle);
      dispatch_async(dispatch_get_main_queue(), ^{
        result(status == 0
            ? @{@"success": @YES}
            : @{@"success": @NO,
                @"status": @(status),
                @"message": message});
      });
    });
    return;
  }

  if ([call.method isEqualToString:@"deleteGame"]) {
    NSDictionary* args = [call.arguments isKindOfClass:NSDictionary.class]
        ? call.arguments
        : @{};
    NSString* titleId = [args[@"titleId"] isKindOfClass:NSString.class]
        ? args[@"titleId"]
        : @"";
    if (titleId.length == 0) {
      result(@{@"success": @NO,
               @"message": @"A RPCS3 title ID is required for deletion."});
      return;
    }

    dispatch_async(self.queue, ^{
      void* handle = RPCS3OpenLoadedCore();
      if (!handle) {
        dispatch_async(dispatch_get_main_queue(), ^{
          result(@{@"success": @NO,
                   @"message": @"RPCS3 Core must be initialized before deleting a game."});
        });
        return;
      }
      auto deleteGame = reinterpret_cast<rpcs3_delete_game_fn>(
          dlsym(handle, "rpcs3_ios_delete_game"));
      if (!deleteGame) {
        dlclose(handle);
        dispatch_async(dispatch_get_main_queue(), ^{
          result(@{@"success": @NO,
                   @"message": @"This RPCS3 Core does not expose installed-game deletion."});
        });
        return;
      }
      int32_t status = deleteGame(titleId.UTF8String);
      NSString* message = status == 0 ? @"" : RPCS3TuningLastError(handle);
      dlclose(handle);
      dispatch_async(dispatch_get_main_queue(), ^{
        result(status == 0
            ? @{@"success": @YES, @"titleId": titleId}
            : @{@"success": @NO,
                @"status": @(status),
                @"message": message});
      });
    });
    return;
  }

  if ([call.method isEqualToString:@"bootProgress"]) {
    void* handle = RPCS3OpenLoadedCore();
    if (!handle) {
      result(@{@"success": @NO,
               @"message": @"RPCS3 Core is not loaded."});
      return;
    }
    auto getProgress = reinterpret_cast<rpcs3_get_boot_progress_fn>(
        dlsym(handle, "rpcs3_ios_get_boot_progress"));
    if (!getProgress) {
      dlclose(handle);
      result(@{@"success": @NO,
               @"message": @"This RPCS3 Core does not expose boot progress."});
      return;
    }
    uint32_t current = 0;
    uint32_t total = 0;
    char stage[512];
    memset(stage, 0, sizeof(stage));
    int32_t status = getProgress(&current, &total, stage, sizeof(stage));
    NSString* text = stage[0]
        ? ([NSString stringWithUTF8String:stage] ?: @"")
        : @"";
    NSString* message = status == 0 ? @"" : RPCS3TuningLastError(handle);
    dlclose(handle);
    result(status == 0
        ? @{@"success": @YES,
            @"current": @(current),
            @"total": @(total),
            @"stage": text}
        : @{@"success": @NO,
            @"status": @(status),
            @"message": message});
    return;
  }

  result(FlutterMethodNotImplemented);
}

@end
