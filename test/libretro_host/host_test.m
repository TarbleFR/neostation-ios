// Behavioural test of NeoStation's portable libretro host on macOS: core
// loading, environment calls, content (plain and zipped), save RAM written
// on unload and restored on the next load, save states in RetroArch's
// RASTATE and rzip layouts, options, cheats, disk control, and a fresh core
// after unloading. Runs against test/libretro_host/test_core.c.
#import <Foundation/Foundation.h>

#import "LibretroCoreHost.h"
#import "LibretroCoreOptions.h"
#import "LibretroStateCodec.h"

#include <zlib.h>

static int failures = 0;

#define CHECK(condition, message)                                   \
  do {                                                              \
    if (condition) {                                                \
      printf("PASS %s\n", message);                                 \
    } else {                                                        \
      printf("FAIL %s (%s:%d)\n", message, __FILE__, __LINE__);    \
      failures++;                                                   \
    }                                                               \
  } while (0)

@interface TestDelegate : NSObject <LibretroCoreHostDelegate>
@property(nonatomic) unsigned frames;
@property(nonatomic) uint32_t pixel0;
@property(nonatomic) uint32_t pixel1;
@property(nonatomic) size_t audioFrames;
@property(nonatomic) uint16_t buttons;
@end

@implementation TestDelegate
- (void)coreHost:(LibretroCoreHost *)host
      videoFrame:(const void *)data
           width:(unsigned)width
          height:(unsigned)height
           pitch:(size_t)pitch {
  if (data == NULL || data == RETRO_HW_FRAME_BUFFER_VALID) return;
  self.frames++;
  self.pixel0 = ((const uint32_t *)data)[0];
  self.pixel1 = ((const uint32_t *)data)[1];
}
- (void)coreHost:(LibretroCoreHost *)host audioFrames:(const int16_t *)frames count:(size_t)count {
  self.audioFrames += count;
}
- (void)coreHost:(LibretroCoreHost *)host fillInput:(LibretroInputSnapshot *)snapshot {
  memset(snapshot, 0, sizeof(*snapshot));
  snapshot->buttons[0] = self.buttons;
}
@end

/// A delegate with a hardware context: its render interface exists from
/// context creation until the frontend releases the context.
@interface HardwareDelegate : TestDelegate
@property(nonatomic) BOOL contextAlive;
@end

@implementation HardwareDelegate
- (BOOL)coreHost:(LibretroCoreHost *)host prepareHardwareRender:(struct retro_hw_render_callback *)callback {
  self.contextAlive = YES;
  return YES;
}
- (const struct retro_hw_render_interface *)hardwareRenderInterfaceForCoreHost:(LibretroCoreHost *)host {
  static const struct retro_hw_render_interface interface = {RETRO_HW_RENDER_INTERFACE_VULKAN, 5};
  return self.contextAlive ? &interface : NULL;
}
@end

static NSUInteger LogIndex(NSArray<NSString *> *log, NSString *line) {
  NSUInteger index = [log indexOfObject:line];
  return index == NSNotFound ? NSUIntegerMax : index;
}

static LibretroCoreHost *MakeHost(NSString *core, NSString *work) {
  return [[LibretroCoreHost alloc] initWithCorePath:core
                                    systemDirectory:[work stringByAppendingPathComponent:@"System"]
                                      saveDirectory:[work stringByAppendingPathComponent:@"Saves"]
                                     stateDirectory:[work stringByAppendingPathComponent:@"States"]
                                   optionsDirectory:[work stringByAppendingPathComponent:@"Config"]
                                     cacheDirectory:[work stringByAppendingPathComponent:@"Cache"]
                                           language:RETRO_LANGUAGE_FRENCH
                                         jitCapable:NO];
}

static NSData *RzipWrap(NSData *payload) {
  // One deflate (zlib-framed) chunk, as RetroArch's rzip writer produces.
  uLongf bound = compressBound((uLong)payload.length);
  NSMutableData *compressed = [NSMutableData dataWithLength:bound];
  compress2(compressed.mutableBytes, &bound, payload.bytes, (uLong)payload.length, 6);
  compressed.length = bound;
  NSMutableData *file = [NSMutableData data];
  const uint8_t magic[8] = {'#', 'R', 'Z', 'I', 'P', 'v', 1, '#'};
  [file appendBytes:magic length:8];
  uint32_t chunk = 131072;
  [file appendBytes:&chunk length:4];
  uint64_t total = payload.length;
  [file appendBytes:&total length:8];
  uint32_t size = (uint32_t)compressed.length;
  [file appendBytes:&size length:4];
  [file appendData:compressed];
  return file;
}

int main(int argc, const char *argv[]) {
  @autoreleasepool {
    if (argc < 4) {
      printf("usage: host_test CORE WORKDIR CONTENT_ZIP\n");
      return 2;
    }
    NSString *core = @(argv[1]);
    NSString *work = @(argv[2]);
    NSString *zipped = @(argv[3]);
    NSString *content = [work stringByAppendingPathComponent:@"Test Game.ntc"];
    NSMutableData *rom = [NSMutableData dataWithLength:100];
    for (int index = 0; index < 100; index++) ((uint8_t *)rom.mutableBytes)[index] = (uint8_t)(index + 1);
    [rom writeToFile:content atomically:YES];

    // Session 1: plain content.
    TestDelegate *delegate = [TestDelegate new];
    delegate.buttons = 0x0103;
    LibretroCoreHost *host = MakeHost(core, work);
    host.delegate = delegate;
    NSError *error = nil;
    CHECK([host loadCore:&error], "core loads and exposes libretro API 1");
    CHECK([host.libraryName isEqualToString:@"NeoTest"], "library name read");
    [host.options applyDefaults:@{@"neotest_mode" : @"beta"}];
    CHECK([host loadContentAtPath:content error:&error], "plain content loads");
    for (int frame = 0; frame < 10; frame++) [host runFrame];
    CHECK(delegate.frames == 10 && delegate.pixel0 == 10, "ten frames presented");
    CHECK(delegate.audioFrames == 8000, "audio batches forwarded");
    CHECK(delegate.pixel1 == 0, "no save RAM restored on first run");
    CHECK([host saveStateToSlot:1 error:&error], "state saved to slot 1");
    NSData *stateFile = [NSData dataWithContentsOfFile:[host statePathForSlot:1]];
    CHECK(stateFile.length > 8 && memcmp(stateFile.bytes, "RASTATE", 7) == 0, "state written as RASTATE container");
    for (int frame = 0; frame < 5; frame++) [host runFrame];
    CHECK([host loadStateFromSlot:1 error:&error], "state loaded from slot 1");
    [host runFrame];
    CHECK(delegate.pixel0 == 11, "restored state resumes at frame 11");
    [host applyCheats:@[ @"CODE-1", @"", @"CODE-2" ]];
    CHECK(host.supportsDiskControl && host.diskCount == 2, "disk control interface registered");
    CHECK([host selectDisk:1] && host.diskIndex == 1, "disk 2 selected");
    CHECK([[host labelForDisk:1] isEqualToString:@"Test disc 2"], "disk label read");
    [host runFrame];
    NSString *saveRAM = host.saveRAMPath;
    [host unloadWithContextDestroy:nil contextRelease:nil];
    NSData *sram = [NSData dataWithContentsOfFile:saveRAM];
    const uint8_t *bytes = sram.bytes;
    CHECK(sram.length == 2048, "save RAM written on unload");
    CHECK(sram.length == 2048 && bytes[1] == 0x5A, "save RAM content");
    CHECK(sram.length == 2048 && bytes[2] == 'b', "NeoStation default option reached the core");
    CHECK(sram.length == 2048 && bytes[3] == 0, "JIT reported unavailable");
    CHECK(sram.length == 2048 && bytes[4] == 2, "only non-empty cheats applied");
    CHECK(sram.length == 2048 && bytes[5] == 1, "disk index persisted in core state");
    CHECK(sram.length == 2048 && bytes[10] == 0x03, "input bitmask delivered");
    CHECK([saveRAM.stringByDeletingLastPathComponent.lastPathComponent isEqualToString:@"NeoTest"],
          "save RAM sorted by core name like RetroArch");

    // Session 2: zipped content, fresh core, save RAM restored.
    TestDelegate *second = [TestDelegate new];
    LibretroCoreHost *again = MakeHost(core, work);
    again.delegate = second;
    CHECK([again loadCore:&error], "core reloads after unload");
    CHECK([again loadContentAtPath:zipped error:&error], "zipped content extracted and loaded");
    [again runFrame];
    CHECK(second.pixel0 == 1, "core state is fresh after dlclose");
    CHECK(second.pixel1 == 0x5A, "save RAM restored before the first frame");
    [again.options setValue:@"beta" forKey:@"neotest_mode" persist:YES];
    CHECK([again.options consumeUpdate], "option change flagged for the core");
    CHECK(![again.options consumeUpdate], "option change flagged only once");
    // User values that session 3's NeoStation values must beat.
    [again.options setValue:@"three" forKey:@"neotest_init" persist:YES];
    [again.options setValue:@"user" forKey:@"neotest_locked" persist:YES];

    // RetroArch-style compressed state in slot 2 (frame counter 42).
    uint32_t serialized[2] = {42, 0};
    NSData *container = [LibretroStateCodec containerForCoreState:[NSData dataWithBytes:serialized length:8]];
    [RzipWrap(container) writeToFile:[again statePathForSlot:2] atomically:YES];
    CHECK([again loadStateFromSlot:2 error:&error], "rzip-compressed RASTATE state accepted");
    [again runFrame];
    CHECK(second.pixel0 == 43, "compressed state restored the frame counter");
    NSError *decodeError = nil;
    const uint8_t zstd[20] = {'#', 'R', 'Z', 'I', 'P', 'v', 2, '#', 0, 0, 2, 0, 8, 0, 0, 0, 0, 0, 0, 0};
    CHECK([LibretroStateCodec coreStateFromFileData:[NSData dataWithBytes:zstd length:20] error:&decodeError] == nil &&
              decodeError.code == LibretroStateCodecErrorUnsupportedCompression,
          "zstd states are reported, not guessed");
    [again unloadWithContextDestroy:nil contextRelease:nil];

    NSData *options = [NSData dataWithContentsOfFile:[work stringByAppendingPathComponent:@"Config/NeoTest.json"]];
    CHECK(options != nil && [[[NSString alloc] initWithData:options encoding:NSUTF8StringEncoding]
                                containsString:@"beta"],
          "user option persisted per core");

    // Session 3: NeoStation's option values must reach a core that reads
    // them only in retro_init (DeSmuME), locked values resist user changes,
    // and a value changed during the session is flagged for the core.
    TestDelegate *third = [TestDelegate new];
    LibretroCoreHost *configured = MakeHost(core, work);
    configured.delegate = third;
    configured.initialOptionDefaults = @{@"neotest_default" : @"neo", @"neotest_mode" : @"alpha"};
    configured.initialSessionOverrides = @{@"neotest_init" : @"two", @"neotest_locked" : @"free"};
    configured.lockedSessionOverrides = @{@"neotest_locked" : @"fixed"};
    CHECK([configured loadCore:&error], "core loads with initial option values");
    CHECK([configured loadContentAtPath:content error:&error], "content loads in the option session");
    size_t reportSize = 0;
    const char *report = [configured memoryDataForIdentifier:RETRO_MEMORY_SYSTEM_RAM size:&reportSize];
    BOOL hasReport = report != NULL && reportSize >= 96;
    CHECK(hasReport && strcmp(report, "two") == 0, "session override read in retro_init, over the stored value");
    CHECK(hasReport && strcmp(report + 16, "fixed") == 0, "locked override read in retro_init, over everything");
    CHECK(hasReport && strcmp(report + 32, "neo") == 0, "NeoStation default read in retro_init");
    CHECK(hasReport && strcmp(report + 48, "beta") == 0, "NeoStation default does not replace a stored user value");
    CHECK(!configured.options.updatePending, "values given before retro_init are not flagged as updates");
    CHECK([configured.options isLockedKey:@"neotest_locked"] && ![configured.options isLockedKey:@"neotest_init"],
          "only locked overrides are locked");
    CHECK(![configured.options setValue:@"user" forKey:@"neotest_locked" persist:YES],
          "a locked option refuses a user change");
    const char *lockedValue = [configured.options valueForKey:"neotest_locked"];
    CHECK(lockedValue != NULL && strcmp(lockedValue, "fixed") == 0, "the locked value stays in effect");
    CHECK(!configured.options.updatePending, "a refused change is not flagged");
    [configured runFrame];
    [configured.options applySessionOverrides:@{@"neotest_init" : @"two"}];
    CHECK(!configured.options.updatePending, "an override that changes nothing is not flagged");
    [configured.options applySessionOverrides:@{@"neotest_init" : @"one"}];
    CHECK(configured.options.updatePending, "an override changing a declared option is flagged for the core");
    [configured runFrame];
    CHECK(!configured.options.updatePending, "the core consumed the update");
    report = [configured memoryDataForIdentifier:RETRO_MEMORY_SYSTEM_RAM size:&reportSize];
    hasReport = report != NULL && reportSize >= 96;
    CHECK(hasReport && strcmp(report + 64, "one") == 0 && report[80] == 1, "the core re-read the overridden value");
    [configured.options applyDefaults:@{@"neotest_mode" : @"beta"}];
    CHECK(!configured.options.updatePending, "a default under a stored user value is not flagged");
    [configured.options applyDefaults:@{@"neotest_default" : @"core"}];
    CHECK(configured.options.updatePending, "a default changing a declared option is flagged for the core");
    [configured unloadWithContextDestroy:nil contextRelease:nil];
    NSData *stored = [NSData dataWithContentsOfFile:[work stringByAppendingPathComponent:@"Config/NeoTest.json"]];
    id storedJSON = stored != nil ? [NSJSONSerialization JSONObjectWithData:stored options:0 error:nil] : nil;
    NSDictionary *storedValues = [storedJSON isKindOfClass:[NSDictionary class]] ? storedJSON[@"values"] : nil;
    CHECK([storedValues[@"neotest_locked"] isEqual:@"user"], "the refused change was not stored");
    CHECK([storedValues[@"neotest_init"] isEqual:@"three"], "session overrides are never stored");

    // Session 4: RetroArch's teardown order. context_destroy first, then
    // retro_unload_game and retro_deinit while the hardware context and its
    // interface still exist (Azahar destroys its Vulkan renderer through the
    // frontend's VkDevice in retro_unload_game), then the frontend releases
    // the context, and dlclose last. Releasing the context before
    // retro_unload_game crashed NeoStation when a 3DS game was closed.
    HardwareDelegate *hardware = [HardwareDelegate new];
    LibretroCoreHost *rendered = MakeHost(core, work);
    rendered.delegate = hardware;
    rendered.initialSessionOverrides = @{@"neotest_hw" : @"on"};
    CHECK([rendered loadCore:&error], "core loads for the hardware context session");
    CHECK([rendered loadContentAtPath:content error:&error], "content loads with a hardware context");
    CHECK(rendered.usesHardwareRendering, "the core registered its hardware context");
    [rendered hardwareContextReset];
    [rendered runFrame];
    NSMutableArray<NSString *> *steps = [NSMutableArray array];
    rendered.teardownObserver = ^(NSString *step, BOOL finished) {
      [steps addObject:[NSString stringWithFormat:@"%@ %@", step, finished ? @"returned" : @"called"]];
    };
    __block NSArray<NSString *> *logAtRelease = @[];
    [rendered unloadWithContextDestroy:^{
      [steps addObject:@"frontend destroys the context"];
      [rendered hardwareContextDestroy];
    }
        contextRelease:^{
          [steps addObject:@"frontend releases the context"];
          logAtRelease = rendered.recentLog;
          hardware.contextAlive = NO;
        }];
    NSArray<NSString *> *expectedSteps = @[
      @"frontend destroys the context", @"retro_unload_game called", @"retro_unload_game returned",
      @"retro_deinit called", @"retro_deinit returned", @"frontend releases the context", @"dlclose called",
      @"dlclose returned"
    ];
    CHECK([steps isEqualToArray:expectedSteps], "teardown runs context_destroy, unload, deinit, release, dlclose");
    if (![steps isEqualToArray:expectedSteps]) printf("  steps: %s\n", [steps description].UTF8String);
    NSArray<NSString *> *log = rendered.recentLog;
    NSUInteger destroyed = LogIndex(log, @"[INFO] neotest context_destroy interface=1");
    NSUInteger unloaded = LogIndex(log, @"[INFO] neotest unload_game interface=1");
    NSUInteger deinitialized = LogIndex(log, @"[INFO] neotest deinit interface=1");
    CHECK(destroyed != NSUIntegerMax, "context_destroy runs while the context exists");
    CHECK(unloaded != NSUIntegerMax, "retro_unload_game still reaches the hardware render interface");
    CHECK(deinitialized != NSUIntegerMax, "retro_deinit still reaches the hardware render interface");
    CHECK(destroyed < unloaded && unloaded < deinitialized, "context_destroy, then retro_unload_game, then retro_deinit");
    CHECK([logAtRelease containsObject:@"[INFO] neotest deinit interface=1"],
          "the frontend releases its context only after retro_deinit returned");
    if (destroyed == NSUIntegerMax || unloaded == NSUIntegerMax || deinitialized == NSUIntegerMax) {
      printf("  log: %s\n", [log description].UTF8String);
    }

    // Session 5: a core that stops by itself (PPSSPP when its boot fails)
    // raises shutdownRequested and leaves its error line, which the session
    // quotes in a LIBRETRO_CORE_STOPPED launch failure.
    TestDelegate *fifth = [TestDelegate new];
    LibretroCoreHost *stopping = MakeHost(core, work);
    stopping.delegate = fifth;
    stopping.initialSessionOverrides = @{@"neotest_shutdown_frame" : @"3"};
    CHECK([stopping loadCore:&error], "core loads for the shutdown session");
    CHECK([stopping loadContentAtPath:content error:&error], "content loads for the shutdown session");
    int frames = 0;
    while (frames < 10 && !stopping.shutdownRequested) {
      [stopping runFrame];
      frames++;
    }
    CHECK(stopping.shutdownRequested && frames == 3, "the core's shutdown request is seen at the frame it is made");
    NSArray<NSString *> *errors = [stopping recentErrors:4];
    CHECK(errors.count == 1 && [errors.firstObject isEqualToString:@"[ERROR] neotest boot failed: simulated"],
          "the core's error line is available for the failure message");
    [stopping appendLog:@"[HOST] note"];
    CHECK([[stopping recentLog].lastObject isEqualToString:@"[HOST] note"], "frontend notes join the log");
    [stopping unloadWithContextDestroy:nil contextRelease:nil];
  }
  if (failures > 0) {
    printf("%d libretro host check(s) failed\n", failures);
    return 1;
  }
  printf("All libretro host checks passed\n");
  return 0;
}
