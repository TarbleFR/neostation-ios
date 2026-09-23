# Build 316 candidate — Dusklight audio ownership and return diagnostics

## Evidence from the supplied application logs

The uploaded RPCS3 JSON log contains separate processes, not one continuous
session. Build 315 PID 54045 fails arena preparation at epoch 1790183868.978,
9.791 seconds after Dusklight reports its return at 1790183859.187. The
Dusklight log has no PID/build fields, so that association is chronological,
not a proven same-PID join. RPCS3 succeeds at 1790183896.693 in a different
Build 315 process, PID 54060. Build 314 shows the same ordering.

There are no `NEOSTATION_JIT_REJECTED_GAP_V1` events in the supplied log. The
failed scan reaches the 64 GiB upper bound without reporting an attempted
256 MiB in-range gap. Thus the Build 315 recovery of a kernel-rejected hole
does not explain this device failure. These logs contain neither the VM map
nor allocation owners; they cannot identify which retained Dusklight resource
occupies the required address ranges. No further RPCS3 allocator change is made.

## Confirmed audio defect and targeted correction

Dusklight closes its SDL output on return while retaining game/DSP state for
warm resume. Pinned SDL assumes it owns the application: it changes the shared
AVAudioSession category on open and deactivates it on last-device close. Either
operation can stop another audio engine's device. Reactivating AVAudioSession
and unpausing SoLoud voices later does not necessarily restart that device.

The private embedded SDL backend now owns only its AudioQueues and their
interruption observers. NeoStation remains the sole audio-session policy owner.
Queue destruction and reopening are retained; no muted preference is overridden,
no second DSP is allocated, and no repeated generic audio restart is added.
The full reviewed SDL source is hash-gated and materialized by the existing
canonical-source mechanism, not patched during CI.

The native Foundation regression executes the production SDL iOS section with
fake hardware/session endpoints and real notifications. The session double
stops host audio on deactivation and deliberately does not resurrect it on
activation. Pristine pinned SDL must reproduce interference (exit 42); the
modified backend must pass 100 open/close/interruption cycles without touching
host category/activation and without leaving a live listener. This is a native
behavior test, not a claim of audible playback on an iPhone.

## Remaining memory investigation

Read-only VM snapshots in the existing Dusklight application log record the
state before game-runtime initialization, at each session's first frame, and
on return. They include PID/build, memory tags, region bounds, resident-page
counts, footprint and the largest visible hole in the relevant low range.
Snapshot completeness/truncation is explicit. A visible hole is not reported
as an allocatable arena. Diagnostics do not reserve, move or unmap memory.

This candidate fixes the identified audio ownership defect. It does **not**
claim to fix the remaining Dusklight → RPCS3 failure. Retained game, heap and
renderer state remain in place; blindly calling full shutdown would regress
the second Dusklight session because cold reinitialization is not implemented.
The next device sequence must distinguish audio recovery from memory failure.

No user-facing label, option or error is introduced. Existing native labels
remain covered by the twelve-language tests. RPCS3, Dolphin, ARMSX2 and all
JIT helper inputs must retain Build 315 identities in the candidate IPA.

## Validation record

- Local Linux: native session, queue/thread shutdown, audio suspend/resume,
  nested menus, language selection/twelve catalogs, and VM-hole arithmetic pass.
- The new Foundation audio test and Mach VM API smoke test require macOS CI;
  Linux source checks are not substituted for those tests.
- Compilation, exact native/host hashes and device outcomes are recorded below
  when available. No iPhone validation has yet occurred for this candidate.
