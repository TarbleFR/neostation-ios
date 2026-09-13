# RPCS3 iOS Build 258 — diagnostic-driven runtime resilience

## Scope and evidence

This change is based on `RPCS3-diagnostic(20260913-110728).log`, captured with
God of War III EU (`BCES00510`). The file contains 3,327 JSONL records: 2,917
native Core log records and 410 performance samples.

The capture does **not** contain a process-crash signature: there is no fatal
RPCS3 record, signal, `EXC_BAD_ACCESS`, `std::bad_alloc`, jetsam, watchdog or OOM
termination. It ends with a controller disconnect. It therefore proves a
terminal emulation/presentation stall, not the mechanism by which iOS may have
closed the app after the capture stopped.

| Observation | Measured value | Interpretation |
|---|---:|---|
| FPS | 0–61.99; mean 31.90 | Cinematics can be presentation-light while gameplay remains CPU/SPU/RSX heavy. |
| Samples below 10 FPS | 128 / 410 | The gameplay regression is sustained, not a single shader hitch. |
| Samples at 50 FPS or above | 159 / 410 | The renderer and display path can reach the target in lighter sequences. |
| Process footprint | 1,677.47 → 5,037.24 MiB | Working-set growth is material. |
| Minimum reported headroom | 1,618.76 MiB | The capture does not show imminent jetsam/OOM. |
| Thermal state | 74 nominal, 235 fair, 101 serious | Thermal throttling is a substantial secondary limiter. |
| SPU indirect-branch warnings | 1,684 | SPU analysis/compilation and logging are unusually active. |
| Reciprocal/FMA TODO diagnostics | 299 | More repetitive compile-path logging. |
| Video consumer waits | 20 | The decoded-frame queue is blocked downstream. |
| RSX semaphore timeouts | 2 at `0x60300510` | Direct precursor to the permanent zero-FPS state. |
| Moderate memory-pressure reports | 14 | Vulkan allocation pressure persists for about 70 seconds. |

The second cinematic (`PSDNINT.M2V`) opens immediately before cached-texture
dimension mismatches and a video queue that reaches 61 frames. The queue stays
full because its consumer does not advance. Near the end, FPS drops from about
40 to 5, then 1.08; two `nv406e::semaphore_acquire` waits time out one second
apart at the same guest address. Every later sample reports FPS 0 and RSX 0,
while CPU usage falls to roughly 17–23%. This orders the failure as:

1. guest/RSX synchronization stops presentation;
2. the video consumer stops draining;
3. the decoder waits on its already-full output queue.

The decoder warning is therefore a symptom, not evidence of a decoder crash.
The exact producer that failed to update guest semaphore `0x60300510` cannot be
recovered from this old log because it did not record expected and observed
values. Build 258 now records both values and total wait time.

## High-impact runtime changes

### Memory-pressure scheduling

Previously `VKGSRender::advance_queued_frames()` sampled pressure twice and
called the expensive `on_vram_exhausted()` cache-reclamation path on every
presented frame for the entire moderate-pressure interval. Logging was limited
to once every five seconds, but eviction work was not. Repeatedly discarding
temporary textures and surfaces can immediately force their recreation and
shader/pipeline work.

Build 258 now separates the cheap per-frame sample from scheduled reclamation:

- escalation bypasses the cooldown;
- fatal pressure remains immediate;
- severe pressure may reclaim every 125 ms;
- effective moderate passes wait 750 ms;
- moderate no-op passes back off for 1,500 ms;
- recovery to low pressure resets the state;
- render-target trimming reuses the same severity sample.

This is an architectural cadence change, not a larger timeout or a reduction
in rendering quality.

### SPU persistence and compile-path control

The existing SPU disk format stores guest program metadata, not safely
relocatable ARM64 machine code. Native SPU objects currently embed process
addresses, so loading them in a later ASLR process would be unsafe. Build 258
does not mislabel or re-enable that path.

Instead it makes the safe persistent layer robust:

- serialized readers and appenders;
- CRC and local-store range validation for every record;
- repair by truncating an incomplete tail before any later append;
- rollback of a partial gathered write;
- 128 MiB and 65,536-record guards per title;
- persistent metadata prewarm for the three God of War III serials;
- at most three automatic LLVM workers through the existing iOS memory policy;
- repetitive SPU diagnostics sampled for the first 8 occurrences and then once
  per 256 occurrences, while their full count remains in telemetry.

God of War III now enables `LLVM Precompilation` deliberately: the first run
collects safe guest blocks, and later runs rebuild those known blocks before
gameplay. This shifts work away from combat and cinematics. ARM64 code generation
still occurs in the current process; the cache avoids discovery/analysis work
and runtime surprises but cannot yet eliminate all SPU code generation.

### RSX cache integrity

Raw vertex programs, raw fragment programs and pipeline records are now written
through neighboring pending files followed by an atomic commit. Reads reject
zero-length, oversized, misaligned and truncated payloads. Raw shader hashes are
recomputed against the pipeline metadata; mismatches remove only the affected
raw files and skip that pipeline. This prevents a terminated iOS process from
leaving a zero-byte destination that poisons every later launch.

Semaphore behavior remains guest-correct. A timeout never writes the expected
value into guest memory. The error now includes address, expected value,
observed value and elapsed microseconds, and the profiler records total waits
and timeouts.

## Persistent cache matrix

| Domain | Persistent payload | Validation / invalidation | Bound |
|---|---|---|---:|
| PPU LLVM | Relocatable compressed object | Code hash, settings hash, CPU identity, NeoStation object-version prefix, LLVM object validation | Shared title cache budget |
| SPU LLVM | Guest block metadata and code bytes | Format version in filename, CRC, SPU local-store range, repaired tail | 128 MiB / 65,536 records per title |
| RSX shaders | Raw VP/FP programs | Maximum size, alignment/completeness, recomputed program hash | 1 MiB per raw program |
| RSX pipelines | Backend pipeline metadata | Exact structure size, shader hashes, backend/version directory | Shared title cache budget |
| Vulkan driver | Native driver pipeline blob | Magic/version, vendor, device and pipeline-cache UUID | Existing 128 MiB limit |

RPCS3's cache root is already separated by title/Game ID. iOS now enables the
existing disk-cache limiter by default with a 4 GiB shared budget; established
cleanup removes obsolete title-cache directories without invalidating current
compatible entries. User overrides and desktop defaults are unchanged.

## Instrumentation and comparison

The existing allocation-free `COREPROF` stream already reports frame timing,
1% low, PPU/SPU/RSX/JIT CPU time, fence and range-lock waits, pipeline queue and
compile time, active thread groups, memory footprint and process headroom.

Build 258 adds an independent `COREPROF_RESILIENCE` record every five-second
window. It continues to be emitted when no frame is presented, so a terminal
stall does not silence the evidence:

- attempted, effective and deferred memory reclaims plus peak severity;
- Vulkan allocation/free count and allocation traffic;
- RSX semaphore wait duration, stalls and timeouts;
- PPU object-cache hit/miss;
- successful SPU blocks, guest bytes and cumulative compilation time;
- SPU metadata writes, loads, rejects and repaired bytes;
- total SPU diagnostics (including sampled-out messages);
- RSX runtime shader-cache hit/miss.

`build-utils/compare_rpcs3_core_profiles.py` aggregates both record types. A
valid performance claim requires two comparable real-device runs, the same game
revision, route, save, temperature class and capture interval. No post-change
God of War III device capture was available while implementing this patch, so
the diagnostic above is the baseline and no FPS uplift is claimed yet.

## Local JIT VPN control

Settings → Tools now contains a dedicated Local JIT VPN row on iOS. The first
authorization/enable action saves a `NETunnelProviderManager`, which invokes the
native iOS authorization flow. NeoStation neither bypasses nor simulates that
permission.

The native manager reports configured, authorized, enabled, on-demand and live
connection status independently. Disable first persists on-demand as off, then
stops the tunnel; it retains the accepted manager so a later enable does not
create a duplicate configuration or unnecessarily repeat authorization. Enable
and disable operations are serialized, duplicate managers are removed, signer
bundle-ID rewrites are repaired, active third-party VPNs are rejected, and both
connection directions have bounded waits.

Cold-start and resume refreshes are best-effort and never display a permission
prompt in the background. The Tools screen refreshes on every foreground return,
including after the system authorization sheet or changes in iOS Settings.

All actions, states, descriptions and error explanations are present in the 12
NeoStation locales: English, German, Spanish, French, Indonesian, Italian,
Japanese, Korean, Portuguese, Russian, Simplified Chinese and Traditional
Chinese. A locale-completeness test rejects missing keys and fallback text.

## Remaining limitations

- This capture proves a permanent RSX/guest-semaphore stall but not an iOS
  process crash. A new capture is required if the app is actually terminated.
- The next capture's expected/observed semaphore values are needed to identify
  whether the missing producer is PPU, SPU, flip/presentation or a stale guest
  mapping.
- SPU ARM64 machine code is not cross-process persistent until all embedded host
  addresses have proper relocation records.
- MoltenVK physical GPU timestamp queries remain unvalidated, so `gpu_time_ms`
  stays unavailable; GPU fence wait is reported separately and is not presented
  as GPU execution time.
- Serious thermal state dominates 101 samples. Software changes cannot remove
  device-level frequency throttling; before/after runs must control temperature.
