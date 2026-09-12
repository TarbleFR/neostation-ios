# Build 254 — native RPCS3 savestate stability

Base: Build 253, commit 36b19178c32370ec9488821bb7d3a98b11222456.
Upstream core remains pinned to 22f1152783cef1f7e04af7b1c895173e28fd5b03.

## Confirmed code defects

- ZSTD read contexts had no destructor owner; save-list header inspection did not
  call finalize, leaking decoder contexts. An additional unused DStream was
  allocated on each reader. Explicit finalization also inverted the zero-success
  return value of ZSTD_freeDCtx.
- Compressed writes ignored partial/failed disk writes, allowing an incomplete
  pending savestate to reach the commit path.
- Compression errors could abandon an ordered queue slot instead of draining it.
- A ZSTD decoding error was treated as a need for more input, potentially reading
  the remainder of a damaged file into memory.
- The save command acknowledged asynchronous dispatch, not completion. The API
  mutex did not cover preparation, writing and automatic restoration; stop/load
  requests could interfere with that operation. Host stop also detached Metal and
  audio even when native stop was refused.
- The stop watchdog shared a plain boolean across threads.

These are reproduced/verified code defects, not proof of the cause of the user's
latest regression: no post-Build-253 device diagnostic was available.

## Changes

- Native decoder ownership, early rejection of invalid ZSTD frames, complete
  writes, ordered worker draining, error before atomic pending-file commit.
- Lossless ZSTD level 3 for iOS savestates (previous numerical level 8).
  Same save format and version; no lossy state reduction or global CPU/GPU hacks.
- Reset input/output indices when reusing a compressed writer.
- Native save-operation state shared across the async lifecycle. Destructive
  boot/stop/shutdown requests are rejected while it owns emulation. Automatic
  reload only follows a successfully committed file.
- Preparation failures identify SPU safe-point, active HLE video decoder, game
  savedata or pending system callback conditions. They are not bypassed.
- UI waits for native completion, exposes failure, and retains Metal/audio/input
  if stop is refused. New completion labels cover all 12 existing languages.
- The final IPA validator requires the new private status export; public ABI
  remains 30.

## Validation and limits

test/rpcs3_savestate_native_test.py compiles the actual patched ZSTD handler
declaration and methods with portable file/thread/queue adapters and the pinned
real ZSTD sources. It exercises partial and failed writes, drain completion,
repeated writer use, 1,000 decoder lifetimes, corrupt input, legacy level-8/new
level-3 round trips, and concurrent native operation ownership.

Synthetic host timing is reported only as a compression microbenchmark, never as
an iPhone FPS claim. CI also compiles the full arm64 iOS core and host application.
Device validation still requires repeated save/reload cycles in the same scene,
with the new savestate_complete diagnostic and memory/FPS measurements.

This does not repair already incomplete files, make incompatible historical
savestates compatible, or make every game safe to snapshot during HLE video or
in-game disk saving. Keep conventional game saves as well.

Build 252 fairy removal/unchanged rainbow halo, Build 253 diagnostics/GOW profiles,
ISO integrity, SPU bounds, JIT, audio policy, export and upscale are preserved.
No other emulator's source or settings are modified.
