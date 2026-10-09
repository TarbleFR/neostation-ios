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
    [host unloadWithHardwareTeardown:nil];
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
    [again unloadWithHardwareTeardown:nil];

    NSData *options = [NSData dataWithContentsOfFile:[work stringByAppendingPathComponent:@"Config/NeoTest.json"]];
    CHECK(options != nil && [[[NSString alloc] initWithData:options encoding:NSUTF8StringEncoding]
                                containsString:@"beta"],
          "user option persisted per core");
  }
  if (failures > 0) {
    printf("%d libretro host check(s) failed\n", failures);
    return 1;
  }
  printf("All libretro host checks passed\n");
  return 0;
}
