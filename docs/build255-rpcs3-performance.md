# Build 255 — RPCS3 ARM64 performance iteration

## Scope

Build 255 preserves the Build 254 native savestate lifecycle and serialization
fixes. It changes only RPCS3 ARM64 contention/copy paths, the serial-keyed God
of War III profile, and device-side diagnostics.

The ARMSX3-derived changes are intentionally limited to two reviewed commits:

- `27819fba80beee9beabfa741983cb20d61fccf7f`: notify and park on RPCS3's
  existing VM range-lock word instead of yielding blindly. Exclusion semantics
  are unchanged.
- `9b33316982e34c7d9fa05a4fa8a843a344b13028`: copy 128-byte SPU reservation
  lines as eight explicit 16-byte NEON vectors on ARM64.

The remaining ARMSX3 experiments were not copied because the pinned XITRIX
source already includes them, they were later removed upstream, or there is no
physical-device evidence that they are safe for NeoStation's savestates.

## God of War III serial profile

Only `BCUS98111`, `BCES00510`, and `BCAS25003` receive these additional partial
overrides:

- `Video / Shader Mode`: `Async Recompiler (multi-threaded)`
- `iOS Experimental / RSX FIFO Read Cache`: `4 KiB`
- `iOS Experimental / GETLLAR Mobile Backoff`: `Enabled`

All unspecified values still inherit the global RPCS3 configuration. A user's
per-game resolution scale remains preserved by the native profile merger.

## Measurement

After a successful boot, NeoStation writes one buffered `performance_sample`
per second to `RPCS3-diagnostic.log`. It records the Core's FPS, normalized
process CPU, approximate RSX load, physical footprint, currently available iOS
memory, and `NSProcessInfo` thermal state (`0` nominal through `3` critical).
Stopping the game writes a `performance_summary` with average/minimum sampled
FPS, peak footprint, minimum available memory, and worst thermal state.

This telemetry is observational and is not a replacement for an Instruments
Time Profiler, System Trace, or Metal System Trace capture. CI proves source,
ABI, compilation, packaging, and regression contracts; only a physical iPhone
16 Pro Max can establish the 30 FPS target.

## Protected behavior

- The selection halo remains unchanged.
- The fairy remains removed from every playlist and view.
- Build 254 savestate fixes and Build 251 upscale controls remain unchanged.
- Dolphin and every non-PS3 emulator remain unchanged.
