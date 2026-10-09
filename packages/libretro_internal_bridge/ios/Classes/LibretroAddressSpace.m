#import "LibretroAddressSpace.h"

#include <mach/mach.h>
#include <stdlib.h>
#include <string.h>

const uint64_t LibretroPPSSPPBaseMinimum = 0x100000000ull;
/// PPSSPP: max_base_addr = 0x1FFFF0000 - 0x80000000, exclusive.
const uint64_t LibretroPPSSPPBaseLimit = 0x17FFF0000ull;
const uint64_t LibretroPPSSPPBaseStride = 0x800000ull;
const uint64_t LibretroPPSSPPSpan = 0x0C000000ull;

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

LibretroPPSSPPWindow LibretroPPSSPPWindowForMappedRanges(const LibretroAddressRange *mapped, NSUInteger count) {
  LibretroPPSSPPWindow window;
  memset(&window, 0, sizeof(window));
  LibretroAddressRange *merged = NULL;
  NSUInteger mergedCount = 0;
  if (mapped != NULL && count > 0) {
    merged = malloc(count * sizeof(*merged));
    if (merged == NULL) return window;
    memcpy(merged, mapped, count * sizeof(*merged));
    qsort(merged, count, sizeof(*merged), CompareRanges);
    for (NSUInteger index = 0; index < count; index++) {
      LibretroAddressRange range = merged[index];
      if (range.end <= range.start) continue;
      if (mergedCount > 0 && range.start <= merged[mergedCount - 1].end) {
        if (range.end > merged[mergedCount - 1].end) merged[mergedCount - 1].end = range.end;
      } else {
        merged[mergedCount++] = range;
      }
    }
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
  const uint64_t spanStart = LibretroPPSSPPBaseMinimum;
  const uint64_t spanEnd = LibretroPPSSPPBaseLimit + LibretroPPSSPPSpan;
  uint64_t cursor = spanStart;
  for (NSUInteger index = 0; index <= mergedCount && cursor < spanEnd; index++) {
    uint64_t holeEnd = index < mergedCount ? MIN(merged[index].start, spanEnd) : spanEnd;
    if (holeEnd > cursor && holeEnd - cursor > window.largestHoleSize) {
      window.largestHoleStart = cursor;
      window.largestHoleSize = holeEnd - cursor;
    }
    if (index < mergedCount && merged[index].end > cursor) cursor = merged[index].end;
  }
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
  if (window.firstBase != 0) {
    return [NSString stringWithFormat:@"[HOST] PPSSPP memory window: usable base 0x%llx (%lu of %lu probed bases free, "
                                      @"%lu regions mapped in 0x%llx-0x%llx); largest hole 0x%llx bytes at 0x%llx",
                                      window.firstBase, (unsigned long)window.usableBases,
                                      (unsigned long)window.probedBases, (unsigned long)count,
                                      LibretroPPSSPPBaseMinimum, spanEnd, window.largestHoleSize,
                                      window.largestHoleStart];
  }
  return [NSString stringWithFormat:@"[HOST] PPSSPP memory window: no usable base among %lu probed (%lu regions "
                                    @"mapped in 0x%llx-0x%llx); largest hole 0x%llx bytes at 0x%llx; PPSSPP needs "
                                    @"0x%llx free bytes at an 8 MiB-aligned base below 0x%llx",
                                    (unsigned long)window.probedBases, (unsigned long)count,
                                    LibretroPPSSPPBaseMinimum, spanEnd, window.largestHoleSize,
                                    window.largestHoleStart, LibretroPPSSPPSpan, LibretroPPSSPPBaseLimit];
}
