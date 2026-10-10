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
//
// The reservation runs on this process too: the span is reserved once at an
// aligned base of the window and blocks other mappings; before a boot only
// the three view ranges are freed (PPSSPP can map its views there, the
// span's other pieces stay held); after PPSSPP unmapped them they are held
// again at the same base; a view range taken meanwhile is left untouched,
// only the pieces the reservation holds are released, and a new span is
// reserved; the journal report follows each state.
#import <Foundation/Foundation.h>

#import "LibretroAddressSpace.h"

#include <mach/mach.h>
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

/// PPSSPP's views as offsets from the base (LibretroAddressSpace.m).
static const LibretroAddressRange kTestViews[] = {
    {0x00010000ull, 0x00014000ull},
    {0x04000000ull, 0x04800000ull},
    {0x08000000ull, 0x0C000000ull},
};
static const LibretroAddressRange kTestGaps[] = {
    {0x00000000ull, 0x00010000ull},
    {0x00014000ull, 0x04000000ull},
    {0x04800000ull, 0x08000000ull},
};

/// Whether an exact mapping of [start, end) can be made now (made, then
/// removed): what PPSSPP's vm_remap at a fixed address needs.
static BOOL CanMapExactly(uint64_t start, uint64_t end) {
  vm_address_t address = (vm_address_t)start;
  if (vm_allocate(mach_task_self(), &address, (vm_size_t)(end - start), VM_FLAGS_FIXED) != KERN_SUCCESS) return NO;
  vm_deallocate(mach_task_self(), address, (vm_size_t)(end - start));
  return YES;
}

/// Every byte of [start, end) is mapped.
static BOOL FullyMapped(uint64_t start, uint64_t end) {
  NSData *ranges = LibretroMappedRanges(start, end);
  const LibretroAddressRange *items = ranges.bytes;
  uint64_t cursor = start;
  for (NSUInteger index = 0; index < ranges.length / sizeof(LibretroAddressRange); index++) {
    if (items[index].start > cursor) return NO;
    if (items[index].end > cursor) cursor = items[index].end;
  }
  return cursor >= end;
}

static BOOL ViewsFree(uint64_t base) {
  for (size_t view = 0; view < 3; view++) {
    if (!CanMapExactly(base + kTestViews[view].start, base + kTestViews[view].end)) return NO;
  }
  return YES;
}

static BOOL ViewsHeld(uint64_t base) {
  for (size_t view = 0; view < 3; view++) {
    if (!FullyMapped(base + kTestViews[view].start, base + kTestViews[view].end)) return NO;
    if (CanMapExactly(base + kTestViews[view].start, base + kTestViews[view].end)) return NO;
  }
  return YES;
}

static BOOL GapsHeld(uint64_t base) {
  for (size_t gap = 0; gap < 3; gap++) {
    if (!FullyMapped(base + kTestGaps[gap].start, base + kTestGaps[gap].end)) return NO;
  }
  return YES;
}

static void TestReservation(void) {
  CHECK(LibretroPPSSPPReservedBase() == 0, @"nothing is reserved before the first call");
  CHECK([LibretroPPSSPPReservationReport() hasPrefix:@"[HOST] PPSSPP window not held (not attempted yet)"],
        @"the report says so: %@", LibretroPPSSPPReservationReport());
  LibretroPPSSPPRestoreReservation();
  uint64_t first = LibretroPPSSPPReservedBase();
  CHECK(first != 0, @"restore with nothing held reserves a span (retry after a PSP session)");
  CHECK(LibretroPPSSPPReserveWindow(), @"the span is reserved in this process");
  uint64_t base = LibretroPPSSPPReservedBase();
  CHECK(base == first, @"a second reservation keeps the span held");
  CHECK(base >= LibretroPPSSPPBaseMinimum && base < LibretroPPSSPPBaseLimit &&
            (base - LibretroPPSSPPBaseMinimum) % LibretroPPSSPPBaseStride == 0,
        @"at a base PPSSPP probes: 0x%llx", base);
  CHECK(FullyMapped(base, base + LibretroPPSSPPSpan), @"the whole span is mapped");
  CHECK(!CanMapExactly(base + 0x4000000ull, base + 0x4800000ull), @"nothing else can map inside it");
  vm_region_basic_info_data_64_t info;
  mach_msg_type_number_t infoCount = VM_REGION_BASIC_INFO_COUNT_64;
  mach_port_t object = MACH_PORT_NULL;
  vm_address_t probe = (vm_address_t)base;
  vm_size_t probeSize = 0;
  kern_return_t region = vm_region_64(mach_task_self(), &probe, &probeSize, VM_REGION_BASIC_INFO_64,
                                      (vm_region_info_t)&info, &infoCount, &object);
  if (object != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), object);
  CHECK(region == KERN_SUCCESS && probe == base && info.protection == VM_PROT_NONE,
        @"without access: address space only, no memory");
  NSString *heldPrefix = [NSString stringWithFormat:@"[HOST] PPSSPP window held at 0x%llx", base];
  CHECK([LibretroPPSSPPReservationReport() hasPrefix:heldPrefix], @"held report: %@", LibretroPPSSPPReservationReport());

  // Boot: views free at the base, the rest of the span still held.
  CHECK(LibretroPPSSPPReleaseViewsForBoot() == base, @"the views are released at the reserved base");
  CHECK(ViewsFree(base), @"PPSSPP can map its three views at that base");
  CHECK(GapsHeld(base), @"the span's other pieces stay held during the boot");
  CHECK([LibretroPPSSPPReservationReport() containsString:@"view ranges released for this boot"],
        @"boot report: %@", LibretroPPSSPPReservationReport());
  CHECK(LibretroPPSSPPReleaseViewsForBoot() == base, @"a second release changes nothing");
  // What PPSSPP does: its views at the base, removed in retro_unload_game.
  for (size_t view = 0; view < 3; view++) {
    vm_address_t address = (vm_address_t)(base + kTestViews[view].start);
    vm_allocate(mach_task_self(), &address, (vm_size_t)(kTestViews[view].end - kTestViews[view].start),
                VM_FLAGS_FIXED);
  }
  for (size_t view = 0; view < 3; view++) {
    vm_deallocate(mach_task_self(), (vm_address_t)(base + kTestViews[view].start),
                  (vm_size_t)(kTestViews[view].end - kTestViews[view].start));
  }
  LibretroPPSSPPRestoreReservation();
  CHECK(LibretroPPSSPPReservedBase() == base && ViewsHeld(base) && GapsHeld(base),
        @"after the session the views are held again at the same base");
  CHECK([LibretroPPSSPPReservationReport() containsString:@"reserved again"], @"restore report: %@",
        LibretroPPSSPPReservationReport());

  // A view range taken meanwhile (another allocation) is never touched.
  CHECK(LibretroPPSSPPReleaseViewsForBoot() == base, @"second boot");
  vm_address_t foreign = (vm_address_t)(base + 0x4000000ull);
  kern_return_t taken = vm_allocate(mach_task_self(), &foreign, 0x800000, VM_FLAGS_FIXED);
  CHECK(taken == KERN_SUCCESS, @"another allocation takes the VRAM view range");
  if (taken == KERN_SUCCESS) ((volatile uint8_t *)foreign)[0x1234] = 0x5A;
  LibretroPPSSPPRestoreReservation();
  uint64_t moved = LibretroPPSSPPReservedBase();
  CHECK(moved != 0 && moved != base, @"a new span is reserved elsewhere: 0x%llx", moved);
  CHECK(moved == 0 || (FullyMapped(moved, moved + LibretroPPSSPPSpan) && ViewsHeld(moved)),
        @"the new span is held whole");
  CHECK(taken != KERN_SUCCESS || ((volatile uint8_t *)foreign)[0x1234] == 0x5A,
        @"the other allocation kept its memory");
  BOOL oldPiecesFree = YES;
  for (size_t gap = 0; gap < 3; gap++) {
    uint64_t start = base + kTestGaps[gap].start;
    uint64_t end = base + kTestGaps[gap].end;
    if (moved != 0 && start < moved + LibretroPPSSPPSpan && moved < end) continue;
    if (!CanMapExactly(start, end)) oldPiecesFree = NO;
  }
  CHECK(oldPiecesFree, @"the old span's pieces are released");
  CHECK([LibretroPPSSPPReservationReport() containsString:@"was taken"], @"moved report: %@",
        LibretroPPSSPPReservationReport());
  if (taken == KERN_SUCCESS) vm_deallocate(mach_task_self(), foreign, 0x800000);
  printf("  %s\n", LibretroPPSSPPReservationReport().UTF8String);
}

int main(int argc, const char *argv[]) {
  @autoreleasepool {
    TestEmptyWindow();
    TestFilledWindow();
    TestSingleBase();
    TestUnsortedOverlappingInput();
    TestLiveReport();
    TestReservation();
  }
  printf("%s: %d failure(s)\n", failures == 0 ? "address_space_test passed" : "address_space_test FAILED", failures);
  return failures == 0 ? 0 : 1;
}
