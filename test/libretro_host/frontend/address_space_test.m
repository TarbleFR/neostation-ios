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
// aligned base of the window and blocks other mappings; before a boot the
// three view ranges and the arena slot are freed (a 32 MiB game's arena
// fits the slot, PPSSPP can map its views at the base, the guards stay
// held); once PPSSPP's memory is set up the rest of the slot is held again
// (the view ranges wait for the unload when PPSSPP took another base);
// after PPSSPP unmapped everything the span is held whole again at the
// same base; a
// view range taken meanwhile is left untouched, only the pieces the
// reservation holds are released, and a new span is reserved; the journal
// report follows each state. PPSSPP's base is read from its system RAM
// pointer.
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
/// The arena slot and the guards that stay held around it and the views.
static const LibretroAddressRange kTestSlot = {0x00018000ull, 0x03FFC000ull};
static const LibretroAddressRange kTestGuards[] = {
    {0x00000000ull, 0x00010000ull},
    {0x00014000ull, 0x00018000ull},
    {0x03FFC000ull, 0x04000000ull},
    {0x04800000ull, 0x08000000ull},
};
/// PPSSPP's arena for the 32 MiB of commercial games.
static const uint64_t kArena32 = 0x2804000ull;

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

static BOOL GuardsHeld(uint64_t base) {
  for (size_t guard = 0; guard < 4; guard++) {
    if (!FullyMapped(base + kTestGuards[guard].start, base + kTestGuards[guard].end)) return NO;
  }
  return YES;
}

static BOOL SlotHeld(uint64_t base) {
  return FullyMapped(base + kTestSlot.start, base + kTestSlot.end) &&
         !CanMapExactly(base + kTestSlot.start, base + kTestSlot.start + 0x4000);
}

/// What PPSSPP does at `base`: its arena where the kernel's first fit puts
/// it (the slot's start once the slot is the lowest hole that fits), then
/// its views. Returns the arena.
static vm_address_t BootLikePPSSPP(uint64_t base, uint64_t arenaAddress) {
  vm_address_t arena = (vm_address_t)arenaAddress;
  if (vm_allocate(mach_task_self(), &arena, (vm_size_t)kArena32, VM_FLAGS_FIXED) != KERN_SUCCESS) return 0;
  ((volatile uint8_t *)arena)[0x100] = 0xA5;
  for (size_t view = 0; view < 3; view++) {
    vm_address_t address = (vm_address_t)(base + kTestViews[view].start);
    vm_allocate(mach_task_self(), &address, (vm_size_t)(kTestViews[view].end - kTestViews[view].start),
                VM_FLAGS_FIXED);
  }
  return arena;
}

static void ShutDownLikePPSSPP(uint64_t base, vm_address_t arena) {
  for (size_t view = 0; view < 3; view++) {
    vm_deallocate(mach_task_self(), (vm_address_t)(base + kTestViews[view].start),
                  (vm_size_t)(kTestViews[view].end - kTestViews[view].start));
  }
  if (arena != 0) vm_deallocate(mach_task_self(), arena, (vm_size_t)kArena32);
}

static void TestSystemRAMBase(void) {
  CHECK(LibretroPPSSPPBaseFromSystemRAM(NULL) == 0, @"no RAM pointer, no base");
  CHECK(LibretroPPSSPPBaseFromSystemRAM((const void *)0x08000000ull) == 0,
        @"a null base (memory not set up yet) gives no base");
  CHECK(LibretroPPSSPPBaseFromSystemRAM((const void *)0x17C000000ull) == 0x174000000ull,
        @"the PSP RAM is at base + 0x08000000");
}

static void TestViewsMapped(uint64_t base) {
  CHECK(LibretroPPSSPPViewsMappedAt(base, 32 * kMiB) && LibretroPPSSPPViewsMappedAt(base, 64 * kMiB),
        @"views mapped at the held span (32 and 64 MiB of RAM)");
  CHECK(!LibretroPPSSPPViewsMappedAt(base, 0) && !LibretroPPSSPPViewsMappedAt(0, 32 * kMiB),
        @"no RAM size or no base: not mapped");
}

static void TestReservation(void) {
  CHECK(LibretroPPSSPPReservedBase() == 0, @"nothing is reserved before the first call");
  CHECK([LibretroPPSSPPReservationReport() hasPrefix:@"[HOST] PPSSPP window not held (not attempted yet)"],
        @"the report says so: %@", LibretroPPSSPPReservationReport());
  LibretroPPSSPPMemorySettled(0x150000000ull);
  CHECK(LibretroPPSSPPReservedBase() == 0, @"a memory base without a reservation changes nothing");
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
  TestViewsMapped(base);
  NSString *heldPrefix = [NSString stringWithFormat:@"[HOST] PPSSPP window held at 0x%llx, arena slot held", base];
  CHECK([LibretroPPSSPPReservationReport() hasPrefix:heldPrefix], @"held report: %@", LibretroPPSSPPReservationReport());

  // Boot: views and slot free, guards held.
  CHECK(LibretroPPSSPPReleaseViewsForBoot() == base, @"the views are released at the reserved base");
  CHECK(ViewsFree(base), @"PPSSPP can map its three views at that base");
  CHECK(CanMapExactly(base + kTestSlot.start, base + kTestSlot.end), @"the arena slot is free");
  CHECK(kTestSlot.end - kTestSlot.start >= kArena32 && kTestSlot.end - kTestSlot.start < 0x4804000ull,
        @"the slot takes a 32 MiB game's arena, not a 64 MiB game's");
  CHECK(GuardsHeld(base), @"the guards around the views and the slot stay held during the boot");
  CHECK([LibretroPPSSPPReservationReport() containsString:@"view ranges and arena slot released for this boot"],
        @"boot report: %@", LibretroPPSSPPReservationReport());
  CHECK(LibretroPPSSPPReleaseViewsForBoot() == base, @"a second release changes nothing");
  CHECK(!LibretroPPSSPPViewsMappedAt(base, 32 * kMiB), @"released views are not mapped");
  vm_address_t arena = BootLikePPSSPP(base, base + kTestSlot.start);
  CHECK(arena == base + kTestSlot.start, @"PPSSPP's arena at the slot's start and its views at the base");
  CHECK(LibretroPPSSPPViewsMappedAt(base, 32 * kMiB), @"PPSSPP's views are seen mapped at the base");
  LibretroPPSSPPMemorySettled(base);
  CHECK(FullyMapped(base + kTestSlot.start, base + kTestSlot.end) &&
            !CanMapExactly(base + kTestSlot.start + kArena32, base + kTestSlot.start + kArena32 + 0x4000),
        @"once PPSSPP's memory is set up the rest of the slot is held again");
  CHECK(arena == 0 || ((volatile uint8_t *)arena)[0x100] == 0xA5, @"the arena kept its memory");
  CHECK([LibretroPPSSPPReservationReport() containsString:@"at the reserved base"] &&
            [LibretroPPSSPPReservationReport() containsString:@"of the 0x3fe4000-byte arena slot held"],
        @"running report: %@", LibretroPPSSPPReservationReport());
  ShutDownLikePPSSPP(base, arena);
  LibretroPPSSPPRestoreReservation();
  CHECK(LibretroPPSSPPReservedBase() == base && ViewsHeld(base) && GuardsHeld(base) && SlotHeld(base),
        @"after the session the views and the whole slot are held again at the same base");
  CHECK([LibretroPPSSPPReservationReport() hasPrefix:heldPrefix] &&
            [LibretroPPSSPPReservationReport() containsString:@"reserved again"],
        @"restore report: %@", LibretroPPSSPPReservationReport());

  // PPSSPP takes another base (room lower in the window): the slot is held
  // again at once, the views after the session.
  CHECK(LibretroPPSSPPReleaseViewsForBoot() == base, @"second boot");
  LibretroPPSSPPMemorySettled(base - 0x10000000ull);
  CHECK(SlotHeld(base) && ViewsFree(base), @"another base: the slot is held during the session, not the views");
  CHECK([LibretroPPSSPPReservationReport() containsString:@"another base"], @"report: %@",
        LibretroPPSSPPReservationReport());
  LibretroPPSSPPRestoreReservation();
  CHECK(LibretroPPSSPPReservedBase() == base && ViewsHeld(base) && SlotHeld(base), @"both after it");

  // A view range taken meanwhile (another allocation) is never touched.
  CHECK(LibretroPPSSPPReleaseViewsForBoot() == base, @"third boot");
  vm_address_t foreign = (vm_address_t)(base + 0x4000000ull);
  kern_return_t taken = vm_allocate(mach_task_self(), &foreign, 0x800000, VM_FLAGS_FIXED);
  CHECK(taken == KERN_SUCCESS, @"another allocation takes the VRAM view range");
  if (taken == KERN_SUCCESS) ((volatile uint8_t *)foreign)[0x1234] = 0x5A;
  LibretroPPSSPPRestoreReservation();
  uint64_t moved = LibretroPPSSPPReservedBase();
  CHECK(moved != 0 && moved != base, @"a new span is reserved elsewhere: 0x%llx", moved);
  CHECK(moved == 0 || (FullyMapped(moved, moved + LibretroPPSSPPSpan) && ViewsHeld(moved) && SlotHeld(moved)),
        @"the new span is held whole");
  CHECK(taken != KERN_SUCCESS || ((volatile uint8_t *)foreign)[0x1234] == 0x5A,
        @"the other allocation kept its memory");
  BOOL oldPiecesFree = YES;
  for (size_t guard = 0; guard < 4; guard++) {
    uint64_t start = base + kTestGuards[guard].start;
    uint64_t end = base + kTestGuards[guard].end;
    if (moved != 0 && start < moved + LibretroPPSSPPSpan && moved < end) continue;
    if (!CanMapExactly(start, end)) oldPiecesFree = NO;
  }
  if (!(moved != 0 && base + kTestSlot.start < moved + LibretroPPSSPPSpan && moved < base + kTestSlot.end) &&
      !CanMapExactly(base + kTestSlot.start, base + kTestSlot.end)) {
    oldPiecesFree = NO;
  }
  CHECK(oldPiecesFree, @"the old span's guards and slot are released");
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
    TestSystemRAMBase();
    TestReservation();
  }
  printf("%s: %d failure(s)\n", failures == 0 ? "address_space_test passed" : "address_space_test FAILED", failures);
  return failures == 0 ? 0 : 1;
}
