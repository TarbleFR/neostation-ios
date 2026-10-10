#import "LibretroAddressSpace.h"

#include <mach/mach.h>
#include <os/lock.h>
#include <stdlib.h>
#include <string.h>

const uint64_t LibretroPPSSPPBaseMinimum = 0x100000000ull;
/// PPSSPP: max_base_addr = 0x1FFFF0000 - 0x80000000, exclusive.
const uint64_t LibretroPPSSPPBaseLimit = 0x17FFF0000ull;
const uint64_t LibretroPPSSPPBaseStride = 0x800000ull;
const uint64_t LibretroPPSSPPSpan = 0x0C000000ull;
/// Scratchpad 16 KiB, VRAM and three mirrors 4 x 2 MiB, RAM views 31 + 31 +
/// 2 MiB: the sum MemoryMap_Setup passes to GrabMemSpace for 64 MiB of RAM
/// (32 MiB games: 0x2804000).
const uint64_t LibretroPPSSPPArenaBytes = 0x4804000ull;
/// PPSSPP's RETRO_MEMORY_SYSTEM_RAM: base + 0x08000000.
static const uint64_t kSystemRAMOffset = 0x08000000ull;

/// PPSSPP's views on iOS for the default PSP-2000 model, as offsets from the
/// base: scratchpad, VRAM with its three mirrors, then 64 MiB of RAM (31 MiB
/// primary view, 31 MiB first extra view, 2 MiB second extra view).
static const LibretroAddressRange kViews[] = {
    {0x00010000ull, 0x00014000ull},
    {0x04000000ull, 0x04800000ull},
    {0x08000000ull, 0x0C000000ull},
};

static int CompareRanges(const void *left, const void *right) {
  const LibretroAddressRange *a = left;
  const LibretroAddressRange *b = right;
  if (a->start != b->start) return a->start < b->start ? -1 : 1;
  return 0;
}

/// `merged` is sorted and disjoint, so its ends ascend too: the first range
/// ending after `start` is the only one that can overlap [start, end).
static BOOL RangeIsFree(const LibretroAddressRange *merged, NSUInteger count, uint64_t start, uint64_t end) {
  NSUInteger low = 0;
  NSUInteger high = count;
  while (low < high) {
    NSUInteger middle = low + (high - low) / 2;
    if (merged[middle].end <= start) {
      low = middle + 1;
    } else {
      high = middle;
    }
  }
  return low >= count || merged[low].start >= end;
}

/// Sorts `ranges` in place and merges overlapping or touching ones, empty
/// ranges dropped. Returns the number of merged ranges at the front.
static NSUInteger MergeRanges(LibretroAddressRange *ranges, NSUInteger count) {
  if (count == 0) return 0;
  qsort(ranges, count, sizeof(*ranges), CompareRanges);
  NSUInteger merged = 0;
  for (NSUInteger index = 0; index < count; index++) {
    LibretroAddressRange range = ranges[index];
    if (range.end <= range.start) continue;
    if (merged > 0 && range.start <= ranges[merged - 1].end) {
      if (range.end > ranges[merged - 1].end) ranges[merged - 1].end = range.end;
    } else {
      ranges[merged++] = range;
    }
  }
  return merged;
}

/// Calls `hole` for each unmapped hole of [start, end), in address order;
/// stops when it returns NO.
static void ForEachHole(const LibretroAddressRange *merged, NSUInteger count, uint64_t start, uint64_t end,
                        BOOL (^hole)(uint64_t holeStart, uint64_t holeSize)) {
  uint64_t cursor = start;
  for (NSUInteger index = 0; index <= count && cursor < end; index++) {
    uint64_t holeEnd = index < count ? MIN(merged[index].start, end) : end;
    if (holeEnd > cursor && !hole(cursor, holeEnd - cursor)) return;
    if (index < count && merged[index].end > cursor) cursor = merged[index].end;
  }
}

LibretroPPSSPPWindow LibretroPPSSPPWindowForMappedRanges(const LibretroAddressRange *mapped, NSUInteger count) {
  LibretroPPSSPPWindow window;
  memset(&window, 0, sizeof(window));
  const uint64_t spanStart = LibretroPPSSPPBaseMinimum;
  const uint64_t spanEnd = LibretroPPSSPPBaseLimit + LibretroPPSSPPSpan;
  if (mapped == NULL) count = 0;
  // One more slot for the arena.
  LibretroAddressRange *merged = malloc((count + 1) * sizeof(*merged));
  if (merged == NULL) return window;
  if (count > 0) memcpy(merged, mapped, count * sizeof(*merged));
  NSUInteger mergedCount = MergeRanges(merged, count);
  // The arena first, in the first hole that fits (vm_allocate anywhere).
  __block uint64_t arena = 0;
  ForEachHole(merged, mergedCount, spanStart, spanEnd, ^BOOL(uint64_t holeStart, uint64_t holeSize) {
    if (holeSize < LibretroPPSSPPArenaBytes) return YES;
    arena = holeStart;
    return NO;
  });
  window.arenaStart = arena;
  if (arena != 0) {
    merged[mergedCount] = (LibretroAddressRange){arena, arena + LibretroPPSSPPArenaBytes};
    mergedCount = MergeRanges(merged, mergedCount + 1);
  }
  for (uint64_t base = LibretroPPSSPPBaseMinimum; base < LibretroPPSSPPBaseLimit; base += LibretroPPSSPPBaseStride) {
    window.probedBases++;
    BOOL usable = YES;
    for (size_t view = 0; view < sizeof(kViews) / sizeof(kViews[0]) && usable; view++) {
      usable = RangeIsFree(merged, mergedCount, base + kViews[view].start, base + kViews[view].end);
    }
    if (!usable) continue;
    window.usableBases++;
    if (window.firstBase == 0) window.firstBase = base;
  }
  __block uint64_t largestStart = 0;
  __block uint64_t largestSize = 0;
  ForEachHole(merged, mergedCount, spanStart, spanEnd, ^BOOL(uint64_t holeStart, uint64_t holeSize) {
    if (holeSize > largestSize) {
      largestStart = holeStart;
      largestSize = holeSize;
    }
    return YES;
  });
  window.largestHoleStart = largestStart;
  window.largestHoleSize = largestSize;
  free(merged);
  return window;
}

NSData *LibretroMappedRanges(uint64_t start, uint64_t end) {
  NSMutableData *ranges = [NSMutableData data];
  vm_address_t address = (vm_address_t)start;
  for (unsigned guard = 0; guard < 65536 && address < end; guard++) {
    vm_size_t size = 0;
    vm_region_basic_info_data_64_t info;
    mach_msg_type_number_t infoCount = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t object = MACH_PORT_NULL;
    kern_return_t result = vm_region_64(mach_task_self(), &address, &size, VM_REGION_BASIC_INFO_64,
                                        (vm_region_info_t)&info, &infoCount, &object);
    if (object != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), object);
    if (result != KERN_SUCCESS || size == 0 || address >= end) break;
    LibretroAddressRange range = {address, address + size};
    [ranges appendBytes:&range length:sizeof(range)];
    if (range.end <= address) break;
    address = (vm_address_t)range.end;
  }
  return ranges;
}

NSString *LibretroPPSSPPAddressSpaceReport(void) {
  const uint64_t spanEnd = LibretroPPSSPPBaseLimit + LibretroPPSSPPSpan;
  NSData *ranges = LibretroMappedRanges(LibretroPPSSPPBaseMinimum, spanEnd);
  NSUInteger count = ranges.length / sizeof(LibretroAddressRange);
  LibretroPPSSPPWindow window = LibretroPPSSPPWindowForMappedRanges(ranges.bytes, count);
  NSString *arena = window.arenaStart != 0
                        ? [NSString stringWithFormat:@"its 0x%llx-byte arena expected at 0x%llx", LibretroPPSSPPArenaBytes,
                                                     window.arenaStart]
                        : [NSString stringWithFormat:@"its 0x%llx-byte arena expected above 0x%llx",
                                                     LibretroPPSSPPArenaBytes, spanEnd];
  // An estimate: PPSSPP allocates a little more before probing (seen one
  // 8 MiB step later in the simulator).
  if (window.firstBase != 0) {
    return [NSString stringWithFormat:@"[HOST] PPSSPP memory window, estimated before boot: first usable base "
                                      @"0x%llx (%lu of %lu probed bases free, %lu regions mapped in 0x%llx-0x%llx, "
                                      @"%@); largest hole 0x%llx bytes at 0x%llx",
                                      window.firstBase, (unsigned long)window.usableBases,
                                      (unsigned long)window.probedBases, (unsigned long)count,
                                      LibretroPPSSPPBaseMinimum, spanEnd, arena, window.largestHoleSize,
                                      window.largestHoleStart];
  }
  return [NSString stringWithFormat:@"[HOST] PPSSPP memory window, estimated before boot: no usable base among "
                                    @"%lu probed (%lu regions mapped in 0x%llx-0x%llx, %@); largest hole 0x%llx "
                                    @"bytes at 0x%llx; PPSSPP needs 0x%llx free bytes at an 8 MiB-aligned base below "
                                    @"0x%llx",
                                    (unsigned long)window.probedBases, (unsigned long)count,
                                    LibretroPPSSPPBaseMinimum, spanEnd, arena, window.largestHoleSize,
                                    window.largestHoleStart, LibretroPPSSPPSpan, LibretroPPSSPPBaseLimit];
}

uint64_t LibretroPPSSPPBaseFromSystemRAM(const void *ram) {
  uint64_t address = (uint64_t)(uintptr_t)ram;
  if (address < LibretroPPSSPPBaseMinimum + kSystemRAMOffset) return 0;
  return address - kSystemRAMOffset;
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

BOOL LibretroPPSSPPViewsMappedAt(uint64_t base, uint64_t ramBytes) {
  if (base == 0 || ramBytes == 0) return NO;
  return FullyMapped(base + kViews[0].start, base + kViews[0].end) &&
         FullyMapped(base + kViews[1].start, base + kViews[1].end) &&
         FullyMapped(base + kViews[2].start, base + kViews[2].start + ramBytes);
}

#pragma mark - Reservation

typedef NS_ENUM(NSInteger, LibretroReservationState) {
  LibretroReservationNone,
  /// The whole span is held.
  LibretroReservationHeld,
  /// View ranges and arena slot released for PPSSPP's boot.
  LibretroReservationBooting,
  /// PPSSPP's memory is set up; the rest of the slot is held again.
  LibretroReservationRunning,
};

static os_unfair_lock gReservationLock = OS_UNFAIR_LOCK_INIT;
static LibretroReservationState gReservationState = LibretroReservationNone;
static uint64_t gReservationBase = 0;
/// The view ranges are held (not released, or held again).
static BOOL gViewsHeld = NO;
/// Absolute ranges of the arena slot this file holds.
static NSMutableData *gSlotPieces = nil;
/// Last reservation event, for the journal.
static NSString *gReservationNote = @"not attempted yet";

/// The arena slot, between the scratchpad and VRAM views, 16 KiB from each
/// so that a block placed at its start never touches a view: 0x3FE4000
/// bytes. PPSSPP's arena is its RAM plus 0x804000 bytes (scratchpad and four
/// VRAM views): 0x2804000 for the 32 MiB of commercial games, 0x4804000 for
/// 64 MiB (homebrew asking for it, HD remasters), 0x5404000 for 76 MiB (two
/// remasters). The kernel places it in the lowest hole that fits. A 32 MiB
/// game's arena fits this slot, which lies below the 64 MiB RAM range: it
/// goes in the slot (or lower), never in a view range. Larger arenas fit
/// neither the slot nor the RAM range.
static const LibretroAddressRange kSlot = {0x00018000ull, 0x03FFC000ull};
/// Never released while a span is held: the guards around the views and
/// slot, and the space between VRAM and RAM.
static const LibretroAddressRange kGuards[] = {
    {0x00000000ull, 0x00010000ull},
    {0x00014000ull, 0x00018000ull},
    {0x03FFC000ull, 0x04000000ull},
    {0x04800000ull, 0x08000000ull},
};

/// An exact, non-overwriting reservation without access.
static BOOL ReserveRange(uint64_t start, uint64_t size) {
  vm_address_t address = (vm_address_t)start;
  if (vm_allocate(mach_task_self(), &address, (vm_size_t)size, VM_FLAGS_FIXED) != KERN_SUCCESS) return NO;
  if (address != (vm_address_t)start) {
    vm_deallocate(mach_task_self(), address, (vm_size_t)size);
    return NO;
  }
  vm_protect(mach_task_self(), address, (vm_size_t)size, FALSE, VM_PROT_NONE);
  return YES;
}

static void ReleaseRange(uint64_t start, uint64_t size) {
  vm_deallocate(mach_task_self(), (vm_address_t)start, (vm_size_t)size);
}

static uint64_t SlotHeldBytes(void) {
  uint64_t total = 0;
  const LibretroAddressRange *pieces = gSlotPieces.bytes;
  for (NSUInteger index = 0; index < gSlotPieces.length / sizeof(LibretroAddressRange); index++) {
    total += pieces[index].end - pieces[index].start;
  }
  return total;
}

/// Lock held. Releases the slot pieces this file holds.
static void ReleaseSlotLocked(void) {
  const LibretroAddressRange *pieces = gSlotPieces.bytes;
  for (NSUInteger index = 0; index < gSlotPieces.length / sizeof(LibretroAddressRange); index++) {
    ReleaseRange(pieces[index].start, pieces[index].end - pieces[index].start);
  }
  gSlotPieces.length = 0;
}

/// Lock held. Holds every free page range of the slot (what PPSSPP's arena
/// or another allocation left), keeping what is already held.
static void HoldFreeSlotLocked(void) {
  const uint64_t start = gReservationBase + kSlot.start;
  const uint64_t end = gReservationBase + kSlot.end;
  NSData *ranges = LibretroMappedRanges(start, end);
  NSUInteger count = ranges.length / sizeof(LibretroAddressRange);
  LibretroAddressRange *merged = malloc((count + 1) * sizeof(*merged));
  if (merged == NULL) return;
  if (count > 0) memcpy(merged, ranges.bytes, count * sizeof(*merged));
  NSUInteger mergedCount = MergeRanges(merged, count);
  ForEachHole(merged, mergedCount, start, end, ^BOOL(uint64_t holeStart, uint64_t holeSize) {
    if (ReserveRange(holeStart, holeSize)) {
      LibretroAddressRange piece = {holeStart, holeStart + holeSize};
      [gSlotPieces appendBytes:&piece length:sizeof(piece)];
    }
    return YES;
  });
  free(merged);
}

/// Lock held. Re-holds the view ranges; NO when one was taken meanwhile
/// (the ranges held again then are released).
static BOOL HoldViewsLocked(void) {
  const size_t viewCount = sizeof(kViews) / sizeof(kViews[0]);
  BOOL held[sizeof(kViews) / sizeof(kViews[0])];
  BOOL all = YES;
  for (size_t view = 0; view < viewCount; view++) {
    held[view] = ReserveRange(gReservationBase + kViews[view].start, kViews[view].end - kViews[view].start);
    all = all && held[view];
  }
  if (!all) {
    for (size_t view = 0; view < viewCount; view++) {
      if (held[view]) ReleaseRange(gReservationBase + kViews[view].start, kViews[view].end - kViews[view].start);
    }
  }
  gViewsHeld = all;
  return all;
}

/// Lock held, nothing reserved. Tries the free bases of the window from the
/// highest down: allocations fill the window from below.
static BOOL ReserveSpanLocked(NSString *reason) {
  const uint64_t spanEnd = LibretroPPSSPPBaseLimit + LibretroPPSSPPSpan;
  NSData *ranges = LibretroMappedRanges(LibretroPPSSPPBaseMinimum, spanEnd);
  NSUInteger count = ranges.length / sizeof(LibretroAddressRange);
  LibretroAddressRange *merged = malloc((count + 1) * sizeof(*merged));
  if (merged == NULL) return NO;
  if (count > 0) memcpy(merged, ranges.bytes, count * sizeof(*merged));
  NSUInteger mergedCount = MergeRanges(merged, count);
  const uint64_t highest =
      LibretroPPSSPPBaseMinimum +
      (LibretroPPSSPPBaseLimit - 1 - LibretroPPSSPPBaseMinimum) / LibretroPPSSPPBaseStride * LibretroPPSSPPBaseStride;
  NSUInteger attempts = 0;
  uint64_t reserved = 0;
  for (uint64_t base = highest; base >= LibretroPPSSPPBaseMinimum && attempts < 16; base -= LibretroPPSSPPBaseStride) {
    if (!RangeIsFree(merged, mergedCount, base, base + LibretroPPSSPPSpan)) continue;
    // A free span the kernel may still refuse, or another thread may just
    // have taken: try the next one.
    attempts++;
    if (ReserveRange(base, LibretroPPSSPPSpan)) {
      reserved = base;
      break;
    }
  }
  free(merged);
  if (reserved == 0) {
    gReservationNote = [NSString stringWithFormat:@"%@: no free 0x%llx-byte span at an 8 MiB-aligned base of "
                                                  @"0x%llx-0x%llx (%lu regions mapped, %lu refused)",
                                                  reason, LibretroPPSSPPSpan, LibretroPPSSPPBaseMinimum,
                                                  LibretroPPSSPPBaseLimit, (unsigned long)count,
                                                  (unsigned long)attempts];
    return NO;
  }
  gReservationBase = reserved;
  gReservationState = LibretroReservationHeld;
  gViewsHeld = YES;
  if (gSlotPieces == nil) gSlotPieces = [NSMutableData data];
  gSlotPieces.length = 0;
  LibretroAddressRange slot = {reserved + kSlot.start, reserved + kSlot.end};
  [gSlotPieces appendBytes:&slot length:sizeof(slot)];
  gReservationNote = [NSString stringWithFormat:@"%@: span reserved at 0x%llx (%lu regions mapped in the window then)",
                                                reason, reserved, (unsigned long)count];
  return YES;
}

/// Lock held. Gives up the span (a view range was taken): releases only
/// what this file holds, then looks for a new span.
static void MoveSpanLocked(NSString *reason) {
  uint64_t previous = gReservationBase;
  for (size_t guard = 0; guard < sizeof(kGuards) / sizeof(kGuards[0]); guard++) {
    ReleaseRange(previous + kGuards[guard].start, kGuards[guard].end - kGuards[guard].start);
  }
  ReleaseSlotLocked();
  gReservationState = LibretroReservationNone;
  gReservationBase = 0;
  gViewsHeld = NO;
  ReserveSpanLocked(reason);
}

BOOL LibretroPPSSPPReserveWindow(void) {
  os_unfair_lock_lock(&gReservationLock);
  BOOL held = gReservationState != LibretroReservationNone || ReserveSpanLocked(@"reserved after launch");
  NSString *note = gReservationNote;
  os_unfair_lock_unlock(&gReservationLock);
  NSLog(@"[Libretro] PPSSPP window %@", note);
  return held;
}

uint64_t LibretroPPSSPPReleaseViewsForBoot(void) {
  os_unfair_lock_lock(&gReservationLock);
  if (gReservationState == LibretroReservationHeld) {
    for (size_t view = 0; view < sizeof(kViews) / sizeof(kViews[0]); view++) {
      ReleaseRange(gReservationBase + kViews[view].start, kViews[view].end - kViews[view].start);
    }
    gViewsHeld = NO;
    ReleaseSlotLocked();
    gReservationState = LibretroReservationBooting;
  }
  uint64_t base = gReservationState == LibretroReservationNone ? 0 : gReservationBase;
  os_unfair_lock_unlock(&gReservationLock);
  return base;
}

void LibretroPPSSPPMemorySettled(uint64_t memoryBase) {
  os_unfair_lock_lock(&gReservationLock);
  if (gReservationState == LibretroReservationBooting) {
    // The arena is allocated before the probe starts: holding the slot
    // cannot disturb either. The view ranges wait for the unload, in case
    // PPSSPP were still probing.
    gReservationNote = memoryBase == gReservationBase
                           ? [NSString stringWithFormat:@"PPSSPP's memory at the reserved base 0x%llx", memoryBase]
                           : [NSString stringWithFormat:@"PPSSPP's memory at 0x%llx, another base",
                                                        memoryBase];
    HoldFreeSlotLocked();
    gReservationState = LibretroReservationRunning;
  }
  os_unfair_lock_unlock(&gReservationLock);
}

void LibretroPPSSPPRestoreReservation(void) {
  os_unfair_lock_lock(&gReservationLock);
  if (gReservationState == LibretroReservationBooting || gReservationState == LibretroReservationRunning) {
    uint64_t base = gReservationBase;
    if (!gViewsHeld && !HoldViewsLocked()) {
      MoveSpanLocked([NSString stringWithFormat:@"a view range at 0x%llx was taken", base]);
    } else {
      // PPSSPP's arena was freed in retro_unload_game.
      HoldFreeSlotLocked();
      gReservationState = LibretroReservationHeld;
      gReservationNote = [NSString stringWithFormat:@"view ranges at 0x%llx reserved again", base];
    }
  } else if (gReservationState == LibretroReservationNone) {
    ReserveSpanLocked(@"retried after a PSP session");
  }
  os_unfair_lock_unlock(&gReservationLock);
}

uint64_t LibretroPPSSPPReservedBase(void) {
  os_unfair_lock_lock(&gReservationLock);
  uint64_t base = gReservationState == LibretroReservationNone ? 0 : gReservationBase;
  os_unfair_lock_unlock(&gReservationLock);
  return base;
}

NSString *LibretroPPSSPPReservationReport(void) {
  os_unfair_lock_lock(&gReservationLock);
  LibretroReservationState state = gReservationState;
  uint64_t base = gReservationBase;
  uint64_t slot = SlotHeldBytes();
  NSString *note = gReservationNote;
  os_unfair_lock_unlock(&gReservationLock);
  const uint64_t slotSize = kSlot.end - kSlot.start;
  NSString *slotText = slot == slotSize ? @"arena slot held"
                                        : [NSString stringWithFormat:@"0x%llx of the 0x%llx-byte arena slot held",
                                                                     slot, slotSize];
  switch (state) {
    case LibretroReservationHeld:
      return [NSString stringWithFormat:@"[HOST] PPSSPP window held at 0x%llx, %@ (%@)", base, slotText, note];
    case LibretroReservationBooting:
      return [NSString stringWithFormat:@"[HOST] PPSSPP window held at 0x%llx, view ranges and arena slot released "
                                        @"for this boot (%@)",
                                        base, note];
    case LibretroReservationRunning:
      return [NSString stringWithFormat:@"[HOST] PPSSPP window held at 0x%llx, %@ (%@)", base, slotText, note];
    case LibretroReservationNone:
    default:
      return [NSString stringWithFormat:@"[HOST] PPSSPP window not held (%@)", note];
  }
}
