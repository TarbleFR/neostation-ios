# RPCS3 Build 258 — core architecture cycle 1

## Scope

Build 258 changes only the embedded RPCS3 core, its build pipeline, native
profiling, and benchmark tooling. It does not change NeoStation behavior,
GameDB, the UI, or per-game settings.

The source baseline remains XITRIX/RPCS3 commit
`22f1152783cef1f7e04af7b1c895173e28fd5b03`. This is intentional: changing the
fork snapshot and the scheduler simultaneously would make an A/B result
impossible to attribute.

## Audit result

The baseline already contains the highest-value ARM64 work that is safe to
retain:

- concurrent PPU LLVM module compilation with the requesting thread joining
  the work;
- parallel SPU cache precompilation and bounded compile ownership;
- ARM64 SPU checksum lowering and local-store mirrors;
- persistent Vulkan driver pipeline cache;
- partial and merged RSX host-memory flushes;
- command-buffer-granular Vulkan ring-heap reclamation;
- ARM64 hot atomic/DMA performance meters that avoid unconditional counter
  reads;
- Build 256's notified VM range-lock wait, NEON reservation-line copy, and SPU
  byte-operation folds.

Reapplying these changes under a new name would not create a new performance
gain. The current ARMSX3 graphics-pipe conversion work is restricted to
Qualcomm/Turnip because it addresses an Adreno engine interaction; enabling it
on Apple/MoltenVK would be an unmeasured compatibility gamble.

## Ranked architecture backlog

### High impact — cycle 1 implementation

1. **RSX pipeline compilation dispatch.** The old dispatcher assigns work by
   round robin. It does not account for a worker already compiling a long
   driver pipeline, so later work can wait behind it while another worker is
   idle. Build 258 tracks queued plus in-flight jobs and assigns each new job
   to the least-loaded worker, with a rotating origin for fair ties.
2. **Subsystem profiler outside the render thread.** Build 258 samples Mach
   thread utilization at 2 Hz on a dedicated sleeping thread. The presentation
   hot path records one counter timestamp in a lock-free 2,048-frame ring.
   Existing GPU-fence and notified VM waits are timed only at points that are
   already blocking. No public frontend ABI is changed.
3. **Measurement gate before the next optimization.** A structured `COREPROF`
   record is emitted every five seconds. The next core rewrite is selected by
   the largest measured milliseconds per frame, not by a generic RPCS3 tuning
   assumption.

### High impact — gated on device evidence

- **PPU/SPU scheduler redesign:** proceed only if PPU or SPU milliseconds per
  frame dominate while other performance cores remain underused. Candidate:
  separate execution, JIT, and helper QoS/work classes rather than applying
  one affinity policy to every ARM64 thread.
- **SPU block lifetime/cache redesign:** proceed only if JIT time and compile
  counts remain material after warm-up. ARM64 SPU object files currently cannot
  be reused safely across processes because generated objects embed absolute
  host addresses. Persistent reuse requires symbolic relocation, not simply
  turning the unsafe cache back on.
- **RSX submission/fence pipeline:** proceed if RSX CPU time or GPU-fence wait
  time dominates. Candidate: decouple recording, submission, and completed
  resource retirement without weakening guest ordering.
- **Vulkan GPU timestamp profiler:** proceed after confirming timestamp support
  and stable query results on the target MoltenVK/iOS combination. Physical GPU
  time must not be inferred from RSX CPU load or fence waits.
- **Memory transfer path:** proceed if Instruments attributes a material share
  to texture upload, swizzle, readback, or page protection. Candidate: bounded
  staging reuse and conversion on the correct GPU queue, validated separately
  from the Adreno-specific path.

### Medium impact — deferred

- 512–1,024 MiB and low-address JIT arena improvements: important for JIT
  capacity/boot compatibility, but not a per-frame throughput gain.
- fixed-storage replacement for small vectors in occasional pipeline creation;
- reduced diagnostic logging and allocation cleanup outside measured hot paths;
- additional shader cache metadata and cache pruning.

### Low impact — deferred

- constant changes, arbitrary worker-count increases, spin-count tuning, and
  per-game defaults;
- instruction-level cleanup without an Instruments or `COREPROF` attribution;
- UI-side FPS smoothing.

## Metrics and interpretation

Each `COREPROF` window contains:

- average FPS and frame-weighted 1% low;
- mean, P95, and P99 present-to-present frametime;
- estimated PPU, SPU, RSX, and JIT CPU milliseconds per presented frame;
- GPU-fence wait milliseconds, wait count, and timeout count;
- VM range-lock wait milliseconds and count;
- pipeline queue latency, compile time, completed jobs, and peak backlog;
- average PPU/SPU/RSX/JIT native thread counts;
- physical memory footprint and available iOS process headroom.

`gpu_time_ms=-1` deliberately means unavailable. It prevents RSX load or CPU
fence time from being mislabeled as physical GPU execution time.

The comparison command is:

```sh
python3 build-utils/compare_rpcs3_core_profiles.py \
  --before build257-diagnostic.log \
  --after build258-diagnostic.log \
  --title BCUS98111 \
  --output build258-comparison.md
```

Use the same device, iOS version, game build, save, scene, run duration, thermal
state, power mode, and cold/warm cache condition. Three five-second windows are
the parser minimum; ten or more are preferred.

## Non-device benchmark

The deterministic two-worker queueing benchmark isolates the dispatch policy:

| Metric | Round robin | Least loaded | Delta |
|---|---:|---:|---:|
| Mean pipeline queue wait | 31.071 ms | 0.000 ms | -31.071 ms |
| P95 pipeline queue wait | 110.000 ms | 0.000 ms | -110.000 ms |
| Maximum pipeline queue wait | 110.000 ms | 0.000 ms | -110.000 ms |
| Batch makespan | 150.000 ms | 125.000 ms | -25.000 ms |

This validates the scheduler mechanism, not game FPS. A performance claim is
accepted only after the matched device comparison passes and emulation remains
accurate and stable.
