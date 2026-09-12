# NeoStation iOS Build 257 — RPCS3 profile engine

Build 257 starts from the exact successful Build 256 commit `a4df913` and
keeps its ten save-state slots, ARM64 SPU LLVM fast paths, RSX wait changes,
MoltenVK command-buffer reclamation, JIT path, firmware/library/import paths,
controller bridge, native in-game UI and telemetry.

## Architecture and priority

The launch pipeline is now:

1. NeoStation's conservative global iOS configuration.
2. The current, iOS-sanitised RPCS3 title recommendation.
3. A small NeoStation title override when device evidence exists.
4. Sparse settings explicitly selected by the user.

Legacy full per-game configurations stay fully user-owned and suppress the
database, matching upstream RPCS3. New edits use an atomically written YAML
sidecar under RPCS3's custom-config directory. Only the edited keys are stored,
so a later GameDB update can improve other settings without taking precedence
over the user.

## ARMSX3 and GameDB

ARMSX3's configuration implementation was audited in full. Its key reusable
design is the official RPCS3 endpoint (`api.rpcs3.net/config/?api=v1`), an
offline cache, mobile-specific sanitation and a final explicit-user layer.

The bundled snapshot contains 2,187 usable configurations from 2,194 API
records. Seven records became empty or unusable after validation. Profiles are
classified as balanced, compatibility, GPU/RSX, shader-heavy or SPU-heavy from
their actual settings. The source generator is deterministic and fails closed
on truncated databases.

iOS sanitation removes only evidenced incompatibilities:

- `Renderer: OpenGL`, because the embedded core is Vulkan through MoltenVK.
- `Frame limit: Off` and `Infinite`, because unbounded presentation is unsafe
  for a handheld thermal and battery envelope.

ARMSX3 removes `Max SPURS Threads` globally based on an eight-core Android
measurement. Build 257 deliberately retains it until Apple-SoC data shows the
same conclusion; copying that Android rule to six-core iPhones would not be an
evidence-based change.

The database refreshes at most every seven days, is validated before use,
writes through a `.part` file and atomically replaces the previous cache. Game
launch uses the bundled/cached copy immediately and never waits for a network
request.

## CPU, SPU, GPU and stutter policy

Build 256's audited ARMSX3 SPU LLVM eight-bit operations, ARM64 128-byte copy,
range-lock wait/notification path, expanded SPU gateway scratch and save-state
coordination remain enabled. The SPU object cache remains disabled on ARM64
because its generated objects contain process-specific addresses and are not
safe across ASLR. RPCS3's disk SPU cache, shader cache and Vulkan pipeline cache
remain intact.

God of War III (`BCUS98111`, `BCES00510`, `BCAS25003`) now merges the complete
official recommendation—Ultra shader precision, write-color-buffer handling,
async texture streaming and Mega SPU blocks—with NeoStation's guarded iOS
profile instead of replacing it with a short hand-written document.

The two Dynasty Warriors 6 serials retain the scoped PPU interpreter fallback
for the observed ARM64 LLVM boot failure. Tales of Symphonia Chronicles
(`BLUS31213`, `BLES01935`) adopts ARMSX3's platform-independent PS3-native frame
pacing fix; Android-specific Uncharted/Yakuza workarounds were not copied
without iOS evidence.

## UI

PS3 game information now shows the automatic configuration origin and the
resolved profile family. The copy is available in all twelve NeoStation UI
locales and avoids exposing the individual low-level switches.

## Verification and performance measurements

Static and contract verification covers:

- complete-database size, family values and unsafe-value removal;
- deterministic regeneration of the bundled snapshot;
- nested YAML merges that preserve list entries and unrelated settings;
- legacy custom-config priority and sparse override replay order;
- atomic and bounded native override storage;
- Build 256 save-state and performance-patch preservation;
- Build 257 IPA version and CI wiring.

`compare_rpcs3_telemetry.py` produces an A/B Markdown table from two real
`RPCS3-diagnostic.log` captures. It reports average/minimum FPS, sampled p95
frame time, sustained dips, boot time, CPU/RSX load, peak/available memory,
shader-compilation events, thermal state and fatal events.

No iPhone or licensed PS3 game image is available in the build environment, so
no device FPS number is claimed here. The macOS CI result establishes build and
contract validity, not gameplay performance. A performance verdict requires
matched Build 256/257 captures on the same device, game, scene, duration,
thermal state and cache state; inventing those measurements would invalidate
the comparison.

## Known regression risk

The main new native risk is parsing and replaying a sparse override sidecar.
Malformed, oversized or unknown-key files fail closed instead of being partly
applied. Legacy configurations remain on their old path, providing a backward-
compatible escape hatch. No Dolphin, RetroArch or NeoSync code path is changed.
