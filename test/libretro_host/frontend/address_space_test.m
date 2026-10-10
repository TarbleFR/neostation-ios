// Behavioural test of LibretroAddressSpace: the PPSSPP memory window report.
//
// PPSSPP built for iOS (MASKED_PSP_MEMORY) maps the PSP memory as views at
// fixed offsets from a base it probes from 4 GiB to 6 GiB in 8 MiB steps; a
// base is usable only when the scratchpad, VRAM (with mirrors) and RAM
// views are all free; before probing, PPSSPP's own 72 MiB arena takes the
// first hole that fits. Synthetic maps check the probe: an empty window, a
// window filled by a reservation the size of RPCS3's early JIT escrow, the
// arena taking the only hole large enough for the views, a single usable
// base, mappings allowed between the views, unsorted and overlapping
// input. The live report runs on this process.
#import <Foundation/Foundation.h>

#import "LibretroAddressSpace.h"

#include <stdio.h>

static int failures = 0;

static void Report(BOOL passed, NSString *message, int line) {
  if (passed) {
    printf("PASS %s\n", message.UTF8String);
  } else {
    printf("FAIL %s (%s:%d)\n", message.UTF8String, __FILE__, line);
    failures++;
  }
}

#define CHECK(condition, ...) Report((condition) ? YES : NO, [NSString stringWithFormat:__VA_ARGS__], __LINE__)

static const uint64_t kMiB = 1024ull * 1024ull;

static LibretroPPSSPPWindow Probe(NSArray<NSValue *> *ranges) {
  NSUInteger count = ranges.count;
  LibretroAddressRange *buffer = count > 0 ? calloc(count, sizeof(LibretroAddressRange)) : NULL;
  for (NSUInteger index = 0; index < count; index++) [ranges[index] getValue:&buffer[index]];
  LibretroPPSSPPWindow window = LibretroPPSSPPWindowForMappedRanges(buffer, count);
  free(buffer);
  return window;
}

static NSValue *Range(uint64_t start, uint64_t end) {
  LibretroAddressRange range = {start, end};
  return [NSValue valueWithBytes:&range objCType:@encode(LibretroAddressRange)];
}

static void TestEmptyWindow(void) {
  LibretroPPSSPPWindow window = Probe(@[]);
  const uint64_t spanEnd = LibretroPPSSPPBaseLimit + LibretroPPSSPPSpan;
  CHECK(window.probedBases == 256, @"PPSSPP probes 256 bases (4 GiB to 6 GiB in 8 MiB steps), got %lu",
        (unsigned long)window.probedBases);
  CHECK(window.arenaStart == LibretroPPSSPPBaseMinimum, @"the arena takes the first hole, at 4 GiB");
  // Bases whose scratchpad falls in the arena (k = 0...8) are refused.
  CHECK(window.firstBase == LibretroPPSSPPBaseMinimum + 9 * LibretroPPSSPPBaseStride && window.usableBases == 247,
        @"an empty window leaves 247 bases after the arena (first 0x%llx, %lu usable)", window.firstBase,
        (unsigned long)window.usableBases);
  CHECK(window.largestHoleStart == LibretroPPSSPPBaseMinimum + LibretroPPSSPPArenaBytes &&
            window.largestHoleSize == spanEnd - LibretroPPSSPPBaseMinimum - LibretroPPSSPPArenaBytes,
        @"the largest hole starts after the arena");
}

static void TestFilledWindow(void) {
  // Binaries just above 4 GiB, a 704 MiB reservation (RPCS3's early JIT
  // escrow: 448 MiB code + 256 MiB data) right after them, and the rest of
  // the window fragmented by 40 MiB allocations every 64 MiB.
  NSMutableArray<NSValue *> *ranges = [NSMutableArray array];
  [ranges addObject:Range(0x100000000ull, 0x100000000ull + 100 * kMiB)];
  uint64_t escrow = 0x100000000ull + 128 * kMiB;
  [ranges addObject:Range(escrow, escrow + 704 * kMiB)];
  for (uint64_t start = escrow + 704 * kMiB; start < LibretroPPSSPPBaseLimit + LibretroPPSSPPSpan; start += 64 * kMiB) {
    [ranges addObject:Range(start, start + 40 * kMiB)];
  }
  LibretroPPSSPPWindow window = Probe(ranges);
  CHECK(window.arenaStart == 0, @"no hole of the window holds the arena: it goes above");
  CHECK(window.firstBase == 0 && window.usableBases == 0, @"no base is usable when 64 MiB of RAM never fits");
  CHECK(window.largestHoleSize == 28 * kMiB, @"the largest hole is reported (got 0x%llx)", window.largestHoleSize);
}

static void TestSingleBase(void) {
  const uint64_t base = 0x150000000ull;
  const uint64_t spanEnd = LibretroPPSSPPBaseLimit + LibretroPPSSPPSpan;
  // A single hole of exactly the views' span: the arena takes it first.
  NSArray<NSValue *> *only = @[ Range(0x100000000ull, base), Range(base + LibretroPPSSPPSpan, spanEnd + 64 * kMiB) ];
  LibretroPPSSPPWindow window = Probe(only);
  CHECK(window.arenaStart == base && window.firstBase == 0 && window.usableBases == 0,
        @"the arena takes the only hole large enough for the views: no base is usable");

  // An earlier 80 MiB hole holds the arena: the base is usable.
  const uint64_t arenaHole = 0x110000000ull;
  NSArray<NSValue *> *ranges = @[
    Range(0x100000000ull, arenaHole), Range(arenaHole + 80 * kMiB, base),
    Range(base + LibretroPPSSPPSpan, spanEnd + 64 * kMiB),
  ];
  window = Probe(ranges);
  CHECK(window.arenaStart == arenaHole && window.firstBase == base && window.usableBases == 1,
        @"with the arena in an earlier hole, exactly one base fits a hole of exactly the span");
  CHECK(window.largestHoleStart == base && window.largestHoleSize == LibretroPPSSPPSpan,
        @"the hole is reported at its start");

  // Mappings between the views do not prevent PPSSPP from using the base
  // (and leave no hole large enough for the arena).
  NSArray<NSValue *> *between = @[
    Range(0x100000000ull, base),
    Range(base + 0x00014000ull, base + 0x04000000ull),
    Range(base + 0x04800000ull, base + 0x08000000ull),
    Range(base + LibretroPPSSPPSpan, spanEnd),
  ];
  window = Probe(between);
  CHECK(window.arenaStart == 0 && window.firstBase == base && window.usableBases == 1,
        @"mappings between the views are allowed");

  // One page inside a view is enough to refuse the base.
  NSArray<NSValue *> *blocked = @[
    Range(0x100000000ull, arenaHole), Range(arenaHole + 80 * kMiB, base),
    Range(base + 0x0A000000ull, base + 0x0A004000ull), Range(base + LibretroPPSSPPSpan, spanEnd),
  ];
  window = Probe(blocked);
  CHECK(window.firstBase == 0 && window.usableBases == 0, @"a page inside the RAM view refuses the base");
}

static void TestUnsortedOverlappingInput(void) {
  const uint64_t base = 0x160000000ull;
  NSArray<NSValue *> *ranges = @[
    Range(base + LibretroPPSSPPSpan + 16 * kMiB, LibretroPPSSPPBaseLimit + LibretroPPSSPPSpan),
    Range(0x120000000ull, 0x140000000ull),
    Range(0x100000000ull, 0x130000000ull),
    Range(0x145000000ull, base),
    Range(base + LibretroPPSSPPSpan, base + LibretroPPSSPPSpan + 32 * kMiB),
    Range(base + 0x2000ull, base + 0x1000ull),
  ];
  LibretroPPSSPPWindow window = Probe(ranges);
  CHECK(window.arenaStart == 0x140000000ull && window.firstBase == base && window.usableBases == 1,
        @"unsorted, overlapping and empty ranges are merged before probing");
}

static void TestLiveReport(void) {
  NSData *ranges = LibretroMappedRanges(0x100000000ull, 0x200000000ull);
  CHECK(ranges.length >= sizeof(LibretroAddressRange), @"this process has mappings between 4 and 8 GiB");
  const LibretroAddressRange *items = ranges.bytes;
  BOOL ordered = YES;
  for (NSUInteger index = 0; index < ranges.length / sizeof(LibretroAddressRange); index++) {
    if (items[index].end <= items[index].start) ordered = NO;
    if (index > 0 && items[index].start < items[index - 1].end) ordered = NO;
  }
  CHECK(ordered, @"mapped ranges come in address order, without overlaps");
  NSString *report = LibretroPPSSPPAddressSpaceReport();
  CHECK([report hasPrefix:@"[HOST] PPSSPP memory window, estimated before boot: "] &&
            ([report containsString:@"first usable base 0x"] || [report containsString:@"no usable base"]),
        @"the live report names the outcome: %@", report);
  printf("  %s\n", report.UTF8String);
}

int main(int argc, const char *argv[]) {
  @autoreleasepool {
    TestEmptyWindow();
    TestFilledWindow();
    TestSingleBase();
    TestUnsortedOverlappingInput();
    TestLiveReport();
  }
  printf("%s: %d failure(s)\n", failures == 0 ? "address_space_test passed" : "address_space_test FAILED", failures);
  return failures == 0 ? 0 : 1;
}
