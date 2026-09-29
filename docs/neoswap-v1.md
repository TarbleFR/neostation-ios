# NeoSwap v1 — historical optional candidate (Build 366)

Superseded by the automatic8GiB runtime policy in Build367. See
[the current candidate](import-memory-build367.md). The controls below describe
the historical Build366 experiment.

## Scope

Original NeoStation file-backed CPU-data allocator, written for the shared host.
This is not kernel swap, not MeloNX memory donation and not a promise of extra
physical RAM. The C ABI exposes owner IDs for RPCS3, Dolphin, ARMSX2, Dusklight,
KartPad and an isolated probe. Only RPCS3 is wired into production allocations
in this candidate. No game-ID predicate: every RPCS3 game uses the same policy.

The RPCS3 adapter is in Emu/RSX/Common/aligned_malloc.hpp, so large CPU-side RSX
arrays/scratch buffers can use the broker. It does NOT migrate existing guest
RAM, JIT pages, Vulkan/Metal images, driver memory or every malloc in the process.
The existing file-backed guest RAM and Build 352 pressure/cache policies remain
unchanged. Some games may generate few or no eligible allocations. Zero bytes
is a valid measurement; no synthetic data is charged to the game's counter.

## Control and lifecycle

Settings > Tools > NeoSwap. Default: Off. Select 512, 1024 or 2048 MiB before
launching RPCS3. The native method channel saves a choice only after successful
configuration. The panel displays the actual broker budget, reports a failed
restored configuration and ignores diagnostic replies older than a setting
change. Reconfiguration refuses while any broker block is live; quit the
game, or restart NeoStation if the core retains a persistent CPU cache. The
module never frees game-owned pointers just to make a setting change succeed.

One neo_swap framework owns all files and accounting. The core borrows a v1
function table through rpcs3_ios_set_neoswap_api before initialization. It does
not link a second allocator. The existing RPCS3 ABI 30 is unchanged. A missing
optional service leaves the original allocator in use, and the panel reports
that the client has not connected. IPA validation requires the new client export.

Eligible allocations are >= 1 MiB and <= 256 MiB, with a power-of-two alignment
up to 64 KiB. At most 256 live blocks and the global selected byte budget are
allowed. A minimum 2 GiB of available disk space is retained before allocation.
Files are private, opened with exclusive/no-follow flags and immediately
unlinked. The file descriptor owns their lifetime. Darwin F_PREALLOCATE with
F_ALLOCATEALL reserves storage before ftruncate/MAP_SHARED; the broker never
publishes a sparse allocation on a promise that disk space might exist later.
Owned virtual reservations supply alignment without replacing foreign mappings.
Data files inherit protection until first user authentication after boot.

Allocation rejection falls back to the original CPU allocator BEFORE a pointer
is returned. Memory is never copied/remapped behind a live consumer. An unmap
failure retains ownership; the caller must not pass that pointer to heap free.
There is no signal-handler recovery and no arbitrary-address interception.
Full preallocation and safety margins mitigate, but cannot eliminate, later
storage faults, jetsam, or existing emulator crashes. Neither compilation nor
simulator tests prove on-device performance or stability.

## Measurements

The RPCS3 overlay appends NeoSwap's current mapped bytes using an atomic read.
Settings shows owner current/peak mapped bytes, actual allocated file blocks,
process phys_footprint and allocation counts. Peak counters span this process's
lifetime, including earlier games. Mapped bytes are NOT bytes proved paged out,
RAM saved, or new physical RAM. Driver allocations are not covered.

Documents/Diagnostics/NeoSwap-v1.jsonl records 2-second samples while enabled,
configuration/probe events, per-owner counts, I/O errors and allocation latency.
Rotation keeps the current file and one previous file (about 2 MiB each).
Detailed snapshot work runs on a serial worker, not the display thread. No
per-frame file sync or synchronous diagnostic write is added to the core.

The explicit 8 MiB probe writes, syncs, reads/verifies and releases its OWN
allocation. It tests the mechanism, not the RAM ceiling or God of War III. Its
owner and counters are distinct from RPCS3. Do not run artificial RAM fillers
alongside a game and call that evidence that the game's memory was migrated.

## Repeatable device test

Back up important saves. Start NeoStation fresh, keep the game, save point,
resolution and core settings fixed. First run with NeoSwap Off, export existing
RPCS3 diagnostics; then restart NeoStation, enable 512 MiB, run the integrity
probe and repeat the same scene with the performance overlay. Export
NeoSwap-v1.jsonl and RPCS3 diagnostics, noting device, OS, signing method,
elapsed time, crashes, image/audio errors and stutters. Raise to 1024/2048 MiB
only for comparison; the number selects backing storage, not a raised jetsam
limit. Compare process footprint AND mapped bytes AND frame-time/stability.
Quit/relaunch and switch back to another emulator to check host lifecycle.

## Verification and integration contract

- test/neoswap_test.cpp: real file mapping, alignment, zero fill, disk readback,
  concurrent owners, quota/storage/slot limits, five injected I/O/mapping faults,
  rejected live reconfiguration and complete release. Run under ASan/UBSan.
- test/neoswap_rpcs3_allocator_test.cpp: compiled against the exact materialized
  production allocator; heap-to-file, file-to-file and file-to-heap growth,
  preservation of initialized bytes, allocation-failure fallback and 20 cycles.
- test/check_neo_swap_simulator.py: real broker/plugin on iOS 18 Simulator,
  stubbed Flutter messaging only; singleton, persistent settings, busy refusal,
  probe ownership, data integrity and diagnostics. It does not run PS3 software.
- Flutter tests: 12 catalogues/placeholders/Traditional Chinese, method channel
  validation, off-by-default UI, explicit probe and late response after close.
- test/check_neo_swap_scope.py: immutable non-swap runtimes and all existing
  canonical JIT/VM/GPU postimage hashes. The completed bulk-cheat scope test now
  checks its own immutable endpoint and freezes the accepted cheat sources;
  NeoSwap changes have their own strict allowlist, not a widened cheat allowlist.
- build-utils/validate_neoswap_ipa.py: one host broker, no production test hooks,
  RPCS3 binding export, arm64 architecture, native dependency and binary hashes.

Other cores may use NeoSwap.h/NeoSwapClient.h through an explicit versioned
binding. Consumers MUST identify non-executable, CPU-owned storage, route every
free/reallocation through the same owner-aware path, honor lifetime rules and
pass real native tests before their owner bit is enabled. GPU or JIT integration
requires its own design and is not enabled by this shared API.

Research context: Madeira's file-backed tier demonstrated a related approach;
this module is independently implemented and does not import Wine/Madeira code.
Public platform references: Apple's mmap(2), fcntl(2) and Mapping Files Into
Memory documentation. Existing project license applies. No public release.
