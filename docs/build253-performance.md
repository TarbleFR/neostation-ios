# Build 253: targeted RPCS3 performance candidate

Baseline: Build 252 (`f7b390403b6eb2245c4fce9fe7b5554467ed1ba6`).

## Changes

- GOW III only (`BCUS98111`, `BCES00510`, `BCAS25003`, resolved from real
  metadata): explicitly select PPU/SPU LLVM and disable the diagnostic PPU
  profiler. These match native defaults but override stale custom diagnostic
  configurations. They do not improve an already-correct default configuration.
- Use automatic preferred SPU concurrency (0) instead of the previous fixed 2
  for those serials. This removes the optional SPU concurrency throttle; actual
  benefit depends on game workload, CPU contention and device thermals.
- Reuse the native diagnostic file descriptor for ordinary core messages,
  combine each JSON line into one write, and bound autoreleased objects on
  native threads. Milestones still synchronize and close the descriptor;
  rotation and exception recovery remain enabled. No diagnostic is deliberately
  dropped. This reduces file operations, not the underlying emulation workload.

## Preserved

- Existing 75% GOW III resolution profile, Mega blocks, approximate XFloat,
  multithreaded RSX and asynchronous texture streaming.
- Per-game manual resolution choice (50/75/100/125/150/200) and compatibility
  profile layering; no write to global RPCS3 settings.
- Dynasty Warriors 6 compatibility fallback, ISO integrity checks, savestates,
  JIT/memory safeguards, audio policy and every other emulator.
- Build 252 removal of the fairy in every playlist/view; rainbow halo untouched.

## Verification limits and device protocol

CI checks compilation, profile isolation and existing regression tests. A native
Foundation test exercises concurrent JSON writes, visibility before flush,
milestone close/reopen and bounded file rotation in an owned temporary directory.
It is not a GPU/CPU benchmark and cannot establish a 30 FPS result on iPhone.

Compare Build 252 and 253 using the same GOW III serial/version, save, resolution,
scene, controller and warmed shader cache. Use the same thermal state, power
mode and recording setting. Record at least five minutes (including frame-time
spikes and end-of-run thermals), not only the first seconds. Compare 75% and 50%
resolution separately: a substantial gain at 50% suggests GPU pixel workload is
important; little difference does not by itself prove a specific CPU bottleneck.
Revert the SPU concurrency candidate if repeated comparable runs regress.

There is no on-device benchmark supplied for this patch. No FPS gain or stable
30 FPS claim is made.
