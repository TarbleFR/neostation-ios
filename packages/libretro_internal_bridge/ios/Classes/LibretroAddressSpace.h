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

/// "[HOST] PPSSPP memory window, estimated before boot: ..." for the session
/// log: what PPSSPP's probe should find in this process now. An estimate:
/// PPSSPP allocates a little more before probing (its base was one 8 MiB
/// step after the estimate in the simulator), and vm_region lists mappings,
/// not the kernel's allocation policy boundaries.
NSString *LibretroPPSSPPAddressSpaceReport(void);

/// PPSSPP's window, reserved while the address space is still free.
///
/// On the iPhone the 4-6 GiB window is crowded long before a PSP game
/// starts (10 October 2026: 1790 mappings, largest hole 63 MiB, "Memory init
/// failed"). The plugin therefore reserves the views' span (192 MiB of
/// address space, VM_PROT_NONE: no memory is used) at the highest free
/// 8 MiB-aligned base of the window shortly after launch, once the other
/// plugins have made their early reservations (RPCS3's JIT escrow is taken
/// while it registers). Right before PPSSPP boots, only the three view
/// ranges are released: each is smaller than PPSSPP's 72 MiB arena, which
/// therefore goes elsewhere, and PPSSPP's probe finds them free at that base.
/// After the core is unloaded the view ranges are reserved again, or a new
/// span is looked for when one of them was taken meanwhile. Thread-safe.

/// Reserves the span if none is held. YES when one is held afterwards.
BOOL LibretroPPSSPPReserveWindow(void);
/// Releases the view ranges for a boot. Returns the base, 0 when no span is
/// held.
uint64_t LibretroPPSSPPReleaseViewsForBoot(void);
/// After PPSSPP was unloaded: reserves the view ranges again.
void LibretroPPSSPPRestoreReservation(void);
/// Base of the held span, 0 when none.
uint64_t LibretroPPSSPPReservedBase(void);
/// "[HOST] PPSSPP window ..." describing the reservation, for the journal.
NSString *LibretroPPSSPPReservationReport(void);

NS_ASSUME_NONNULL_END
