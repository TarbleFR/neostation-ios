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
- First native run `35897475214` reproduced the original audio interference and
  passed the new 100-cycle Foundation regression. The iOS compile gate then
  rejected the macOS-only `mach_vm.h` import in the diagnostic reader. No IPA
  was produced. The reader now uses `vm_region_recurse_64` from the iOS Mach
  interface with arm64 `vm_address_t`/`vm_size_t`; a separate iPhoneOS SDK
  syntax check is required before starting the native build.
- Native candidate `2ba746a7728e6d1eb116e79ec84aa342a49e8643`, run
  `35898031842`, passed all required tests and the iOS arm64 compilation.
  The downloaded artifact `10768120936` has ZIP SHA-256
  `2ab24dba8f682aab1d3a20ed1dd393b2f96657c0b5ba9def0a8d0aeceadce6a0`.
  Framework SHA-256:
  `dd1dfd1402409ae0d88c4d6d9972bbd465937fe66931a326a8ae44767c856a22`.
  ABI 3, all 26 canonical source hashes and all 35 resources were verified
  locally against the downloaded artifact. The host packaging gate also
  checks the complete canonical-source set and hashes before assembling an IPA.

## Packaged candidate identity

- Host commit: `66ef2445374777539a78b991d37e9459ed8b6ed2`.
- Full iOS CI run `35898960828`, job `107309907765`: successful. Required
  behavior tests, twelve-language tests, iOS compilation and IPA validators
  passed. Flutter analysis retained 60 informational notices under the existing
  `--no-fatal-infos` policy; no analysis gate was weakened for this candidate.
- Artifact `10767952811`, `NeoStation-iOS-Build-316-Dusklight-Handoff`.
  ZIP SHA-256:
  `72215d35582e5696ae6c0e1aa1c13093a182c9d1b003cd72080f51bb4bf23175`.
- IPA `NeoStation-iOS-Build-316-Dusklight-Handoff.ipa`, 102,351,168 bytes.
  SHA-256:
  `30d0c0ae6d330ad8896486fef803f1a59faff16aab53dba1dd0bf60c70c8bdef`.
- The downloaded IPA reports build 316 and bundle
  `com.neogamelab.neostation`. Its Dusklight binary matches the native artifact;
  all 35 bundled resources and the passive-load boundary were revalidated.
- Byte comparison with the delivered Build 315 confirms unchanged RPCS3,
  Dolphin and ARMSX2 cores, the three helper executables, both helpers'
  JavaScript files and StikJIT's two debugger scripts. RPCS3 still has SHA-256
  `bafe4e8ac378179b930379b2720f1a076890543b3c392c364fd043284465dcfc`.

Device validation remains pending. Test Dusklight first, return to NeoStation,
check music/navigation sounds, launch RPCS3 without restarting, then try another
Dusklight session. If PS3 initialization still fails, the new application logs
must be used to identify retained mappings; this release does not claim that
the unresolved memory failure has been corrected.
