#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// [start, end) range of virtual addresses.
typedef struct {
  uint64_t start;
  uint64_t end;
} LibretroAddressRange;

/// The window PPSSPP needs on iOS. Built with MASKED_PSP_MEMORY, PPSSPP maps
/// the PSP memory as views at fixed offsets from a base it probes from 4 GiB
/// up to 6 GiB - 64 KiB in 8 MiB steps (Core/MemMap.cpp, MemoryMap_Setup;
/// Common/MemArenaDarwin.cpp: vm_remap at a fixed address, never over an
/// existing mapping). A base is usable when every view is free: scratchpad
/// (base + 0x10000, 16 KiB), VRAM and its three mirrors (base + 0x4000000,
/// 8 MiB) and the RAM of the default PSP-2000 model (base + 0x8000000,
/// 64 MiB). Before probing, PPSSPP allocates the memory behind the views
/// (MemArena::GrabMemSpace, 72 MiB, vm_allocate anywhere): the kernel puts
/// it in the first hole that fits, which can be the very window the views
/// need (seen in the iOS Simulator). When no base is usable, PPSSPP fails
/// its boot with "Memory init failed" and asks the frontend to shut down.
typedef struct {
  /// First usable base, 0 when none.
  uint64_t firstBase;
  NSUInteger usableBases;
  NSUInteger probedBases;
  /// Where PPSSPP's arena is expected (first hole of the probed span large
  /// enough for it), 0 when it lands above the span.
  uint64_t arenaStart;
  /// Largest unmapped hole inside the probed span once the arena is placed
  /// (start 0 when none).
  uint64_t largestHoleStart;
  uint64_t largestHoleSize;
} LibretroPPSSPPWindow;

FOUNDATION_EXPORT const uint64_t LibretroPPSSPPBaseMinimum;
FOUNDATION_EXPORT const uint64_t LibretroPPSSPPBaseLimit;
FOUNDATION_EXPORT const uint64_t LibretroPPSSPPBaseStride;
/// Offset just past the last view (base + this is the end of the span).
FOUNDATION_EXPORT const uint64_t LibretroPPSSPPSpan;
/// Size of PPSSPP's arena: the views it creates for 64 MiB of RAM.
FOUNDATION_EXPORT const uint64_t LibretroPPSSPPArenaBytes;

/// Evaluates PPSSPP's probe against `mapped` (any order, overlaps allowed),
/// after placing its arena in the first hole that fits.
LibretroPPSSPPWindow LibretroPPSSPPWindowForMappedRanges(const LibretroAddressRange *_Nullable mapped,
                                                         NSUInteger count);

/// Regions mapped in this process between `start` and `end`, as
/// LibretroAddressRange values (vm_region_64).
NSData *LibretroMappedRanges(uint64_t start, uint64_t end);

/// "[HOST] PPSSPP memory window: ..." for the session log: what PPSSPP's
/// probe will find in this process now. Advisory: vm_region lists
/// mappings, not the kernel's allocation policy boundaries.
NSString *LibretroPPSSPPAddressSpaceReport(void);

NS_ASSUME_NONNULL_END
