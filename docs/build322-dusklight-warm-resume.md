# Build 322 candidate — Dusklight warm resume after Build 321 JIT escrow

## Device outcome that motivates this candidate

Build 321 is retained as the RPCS3 baseline for this change: after leaving
Dusklight, RPCS3 can now start in the same NeoStation process. The remaining
UX regression is intentional behavior introduced by the terminal Dusklight
shutdown: after a normal return to the library, the native session becomes
`NEO_DUSKLIGHT_ENDED` and a second Dusklight launch asks the user to restart
NeoStation.

This candidate changes only the lifetime policy needed to remove that restart
requirement. It does not alter RPCS3, its helpers, StikJIT, or the early JIT
virtual-address escrow added by Build 321.

## Lifetime policy

A normal **Return to Library** is now a logical session boundary, not a cold
engine destruction:

1. Stop host frame scheduling at a frame boundary.
2. Suspend Dusklight input/audio.
3. Drain GPU work and mapping callbacks.
4. Destroy the transient frame buffers and render targets (the same warm
   handoff path previously validated for repeated recreation).
5. Restore NeoStation's window and finish the logical session in
   `NEO_DUSKLIGHT_IDLE`.
6. A launch of the same unchanged disc reserves a new logical session and
   resumes the retained engine without entering `game_main` again.

Cold reinitialization is deliberately **not** attempted. Dusklight still owns
process-lifetime game/JSystem singletons that are not proven safe to construct
twice in one process. The retained engine is therefore restricted to the same
disc identity.

A native runtime failure remains terminal. The existing destructive barrier is
kept for that path: workers, audio, disc, UI/config, Aurora, thread/mutex/message
records, ARAM and MEM1 are released, including the explicit kernel `munmap`
barrier from Builds 319-320. Only this terminal path reports
`runtimeReleased=true` and requires a NeoStation restart.

## Contract / ABI

The embedded Dusklight contract is bumped to ABI v7 with session policy:

`host_frame_loop_warm_resume_rpcs3_jit_escrow`

This prevents a Build 322 host from silently pairing with the older one-shot
ABI v6 Core.

## Pre-build validation

The native gate must prove before packaging an IPA:

- 100 logical stop/resume cycles without a second `game_main` entry.
- Fresh first-frame ownership for every resumed presentation.
- GPU drain/release/recreate ordering across 100 cycles.
- Normal return does not execute the terminal shutdown.
- Fatal failure still executes the complete kernel-unmap barrier.
- The host event distinguishes retained `IDLE` from terminal `ENDED`.

The first CI stage is native-Core-only. A full IPA must not be started until
that gate succeeds. Device validation remains required after a successful IPA,
especially for the sequence Dusklight → NeoStation → RPCS3 → NeoStation →
Dusklight.
