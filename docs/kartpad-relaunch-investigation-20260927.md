# KartPad immediate relaunch: post-Build 348 investigation

## Device evidence

The new `app(20260927-104419).log` identifies Build 348 and PID 71077.
The matching lifecycle transcript records:

- 10:42:15 UTC: first native session created.
- 10:42:26.767: explicit user return requested.
- 10:42:27.398: RuntimeMain returned; HLE, files and guest memory reset completed.
- 10:42:27.399: host window restore called and clean termination emitted.
- 10:42:27.403: Flutter removed the owned launch route.
- 10:42:27.575: menu audio recreation and session finalization completed.
- Next launch: `KARTPAD_HOST_VIEW_MISSING`, stage `presentation`; no second
  native session was created. The subsequent Flutter finalization is logged at
  10:42:47.458.

The device log did not record which host-window predicate failed. The restore
message proves that the restore function ran, not that UIKit subsequently
preserved an attached, visible foreground host window. The video shows a launch
screen followed by the error during application switching; it does not establish
the precise time at which the native rejection occurred.

Inspection of the Build 348 IPA's `kartpad_internal_bridge.framework` confirms
that the retained-window selection and diagnostic format strings from fdb938b
are present. This is not evidence of a stale plugin binary.

## Expanded behavioral probe

`kartpad-flutter-lifecycle.yml` creates a real Flutter 3.47.2 application with
its generated UIScene integration. It loads the exact Build 348 donor artifact
from run 36312123689. Only the test copy's Mach-O platform load command changes
from iOS to simulator; runtime text instructions remain unchanged.

The native probe creates the actual SDL/Metal window, installs the shipped
KartPad overlay, submits frames, tears down Aurora/SDL and restores Flutter.
Dart then waits 150 ms, checks that frames resume and immediately starts another
cycle. Window attributes and timestamps are persisted independently of stdout.
This covers a boundary absent from the earlier standalone UIKit probes.

First probe revision fd0139408a2f97edca9f55dded27320997b1f0dd, run 36314171915,
failed inside the test's renderer drain before reaching window restoration.
Its sampled stacks showed an idle frame worker while the main thread waited for
EncoderReady. The fixture had omitted the final `aurora_begin_frame` used by
the guest frame boundary and existing native lifecycle test. Revision
129cfd5fd680917bf96d6823862a605c9c157cfb corrects this fixture ordering. The first
probe failure is not a reproduction of the device's host-window error.

Run 36314717716 (revision 129cfd5) passed five cycles with 152–154 ms
post-return Dart delays and 8–9 resumed Flutter frames in each interval.
The expanded fixture also routes an asynchronous background completion through
the main dispatch queue, matching the disc-identity method-channel boundary.
Run 36315306749 (revision 47254ce) passed those five automatic cycles on both:

- Xcode 16.4 / iOS 18.5: delays 154, 254, 153, 154, 155 ms.
- Xcode 27.0 (27A266a) / iOS 27: delays 150, 153, 153, 153, 151 ms.

The menu XCTest in that run did not execute: the newly generated test target
had no PRODUCT_NAME, causing duplicate `.xctest` output paths. Revision c628717
sets the test bundle identity and builds it before simulator startup. Its
workflow run is 36315738366. Do not report the automatic cycles as menu tests
or full Mario Kart gameplay validation.

## Diagnostic gap closed in pending host changes

Host launch receipt, host selection/rejection and clean session end now record
the registrar window, retained window, connected scene windows, visibility,
alpha, scene activation and current run-loop mode to the lifecycle log. Host
selection failures also preserve that snapshot in Flutter's technical details.
These are diagnostic fields, not new user-facing strings.
The Dart presentation delay, storage preparation, disc identity and native
launch request/result also receive timestamps to locate a delayed handoff.

No device root cause or new IPA validation is claimed by this investigation
record. Add the behavioral result and exact candidate identity before packaging.

## Further probe observations

- c628717 / run 36315738366: iOS 18 XCTest injected Main Thread Checker
  and aborted the unmodified donor before the first tap. The faulting stack is
  `UIKit_GetWindowSizeInPixels -> SDL_GetWindowSizeInPixels ->
  aurora::window::get_window_size -> frame_worker_main`. This confirms an
  off-main UIKit read in the shipped renderer; it does not reproduce the device
  host-window rejection. iOS 27 reported the same reads as warnings.
- The iOS 27 XCTest animation-idle gate delayed the first menu action by 60 s,
  exceeding the fixture's 60 s menu deadline. Its failure is not a completed
  return/relaunch. db7fdff changes only the XCTest runner to exclude animations
  from quiescence waiting; UIKit animations in the app remain enabled.
- 4d3ce3a / run 36316344376 removes the artificial continuous Flutter ticker
  and uses NeoStation's landscape/immersive configuration. Five automatic
  cycles pass on iOS 18 and iOS 27. Setting MTC_CRASH_ON_REPORT=0 did not prevent
  the iOS 18 XCTest abort; do not describe that menu run as successful.
- 7f173db adds the production ordering: launch acknowledgement inside the live
  SDL run loop, a separate sessionEnded callback after restoration, and removal
  of the owned Flutter dialog route. Its run is 36316639900; db7fdff is the same
  fixture with immediate XCTest taps, run 36316823615. Results remain pending.

The instrumentation also records UIApplication/UIScene activation and window
visibility/key notifications after the first launch. This establishes whether
host rejection preceded or followed the user's app-switcher gesture. The
existing reports cannot determine that ordering. No host-selection predicate,
shutdown sequence, audio behavior, renderer instruction or game data changes
are included in these diagnostic changes.

## Confirmed premature presentation rejection

The iOS 27 automatic probe at 7f173db (run 36316639900, artifact 10930224018)
failed with `host_missing` on its first launch, before loading SDL. The system
trace places the rejection at 11:49:31.507 UTC and the removal of UIKit's
application deactivation reasons at 11:49:32.087–32.093. Thus a usable Flutter
scene was still completing activation when the snapshot-based selector rejected
it. This is a confirmed presentation precondition race; it is not a reproduction
of the user's post-game freeze or proof of the failed device predicate.

The candidate now keeps one launch pending while UIKit makes the validated host
window available. It never starts SDL in an inactive scene, reserves the pending
transaction against a second launch, and cancels readiness waiting on stop.
After three seconds of active application time without a valid host, it returns
the original presentation error with the window snapshot. Inactive/background
time does not consume that foreground budget. No unsafe window fallback or
manual UIScene lifecycle notification is introduced.

The real Flutter fixture uses the identical readiness helper. It also checks
cancellation without late completion, active-window timeout, and delayed
readiness. Candidate build/relaunch results must be recorded before packaging;
physical-device validation and the source of the long post-game wait remain
outstanding.

## Behavioral evidence after readiness change

- db7fdff783f288182318a57ee1eec7d0b74951dd / run 36316823615 /
  artifact 10930399540: iOS 27 XCTest executed five real UIKit menu returns
  and passed its assertions (81.620 s). The independent native report records
  five menu exit requests, five relaunch acknowledgements, and final success;
  resumed Dart delays were 154, 153, 152, 152, 151 ms. xcodebuild did not finish
  after the passing suite, so the job hit its 10-minute step timeout. The job
  itself is **not** reported as green. This revision predates readiness waiting.
- dcf58ecb8e2115ba679da4789dbb7b5b7c46d8f4 / run 36317379071 /
  iOS 18 artifact 10931367004: five automatic Flutter/SDL cycles passed
  (153, 153, 152, 153, 152 ms; two resumed Flutter frames each), and the shared
  production readiness helper passed delayed availability, cancellation and
  active-time timeout checks. The menu XCTest still aborts in the unchanged
  donor's off-main UIKit reads before its first tap; this is not a passing
  iOS 18 menu test. The iOS 27 automatic step also passed at 12:10:02 UTC
  in job 108614541846 (all five cycles and readiness assertions). Artifact
  10931770499 records automatic delays 157, 153, 152, 153, 153 ms. The same
  revision's iOS 27 menu test also passed its assertions in 71.619 s at
  12:11:52 UTC: five real menu exits, five new launch acknowledgements, five
  delays of 151, 152, 151, 152, 151 ms, readiness contract passed, final success.
  As with db7fdff, xcodebuild hung after its passing suite and the step timed
  out; the entire workflow is not described as green.
- Native candidate run 36317379227 / artifact 10931063108 records host source
  dcf58ecb8e2115ba679da4789dbb7b5b7c46d8f4. Its Core and Runtime binaries are
  byte-for-byte identical to Build 348: Core SHA-256
  38774d9c4c20d21998235d493f5d73699cd4c6f6a2bacd1273fc9ea5793fc8b5; Runtime
  SHA-256 c16134c93328dd7b5aeb17e0c660b767f614b760e11d36065f6aaaa00a510229.
  Renderer/audio instructions therefore have not changed in this candidate.

These probes run the shipped SDL/Aurora instructions in a real Flutter host,
without the game's copyrighted assets or full gameplay. They cannot certify
the user's physical-device reproduction. The production logs are necessary
to locate any remaining delay before/inside host-window selection.

## Build 349 packaging decision

Package the verified readiness change as an explicitly labelled relaunch
candidate, preserving the native binaries above. The IPA workflow now requires
the exact dcf58ec automatic/readiness report and binds its presentation sources
to that tested SHA, in addition to existing language/session, UIKit/CoreAudio
and canonical-source gates. This does not turn the known iOS 18 menu failure
into a pass, or establish resolution of the long physical-device wait.

Build 349 packaging source is 5f3bc06f7b9dd4ceeaa914871ca06d1cc145320b,
workflow run 36318146423. The subsequent documentation update records results
without changing the packaged application sources.

Build 349 completed successfully at 12:26:44 UTC, artifact 10931114859.
Verified downloaded IPA: 143538628 bytes, SHA-256
`efad74783a4260cfa8e07a7c3987bf1684c3adc134cd985564406d361d868181`.
ZIP CRC, build number 349, ARM64 executable, readiness class and diagnostic
markers passed. KartPadCore, KartPadRuntime, DolphinCore, DusklightCore,
ARMSX2Core, StikJIT and libRPCS3Core.dylib are byte-identical to Build 348.
This unsigned sideload IPA requires the user's usual signing workflow.
Physical-device resolution of the recorded delay is still unverified.

## Build 349 device follow-up: the presentation error is gone, the stall remains

The user's next video is `ScreenRecording_09-27-2026 14-40-14_1.mp4`,
with `neostation-kartpad-lifecycle(4).log`, `console(4).log`, and subsequently
`app(20260927-125230).log`. Match process/session boundaries, not just filenames:
the app log contains earlier builds and does not cover all four recorded exits.

- Recorded process PID 71368: the first quit is requested at 12:40:31.387 UTC.
  Full native cleanup and `session_ended` occur at 12:40:32.029 (642 ms later).
  The host snapshot already shows the attached, visible, key Flutter window,
  an active scene/application and the default run-loop mode. Scene deactivation
  from the user's gesture does not occur until 12:40:39.913.
- All four native sessions in that process end cleanly in approximately
  0.62–0.64 s. The second relaunch does not require an intervening activation
  notification, so the evidence does not support a permanently stopped engine.
- The same app log's immediately preceding process has a fully traced return:
  native end 12:39:49.843; Dart closing 49.846308; closed 49.846682; route removal
  49.846724; audio/session finalization 12:39:50.067473.
- Its next Dart `presentation_begin` is 12:39:50.779667, but the 150 ms
  `Future.delayed` completes at 12:40:05.974898, reporting **15,194 ms**.
  This follows scene deactivation at 12:40:05.965. Storage, identity and native
  launch then take only 9 ms. This stall precedes the native relaunch call;
  changing native window selection or adding a longer launch timeout cannot
  correct its cause.
- For the recorded PID 71368, app.log stops after the initial launch reply at
  12:40:21.968453 and `Game started — monitoring active`. It has no matching
  Dart end-event/route-removal trace for that process's four native exits.
  Do not assert that the recording's first route was removed promptly based on
  the preceding process's successful removal, or treat a missing log tail as
  proof that Dart stopped executing.

The prior Flutter probe uses a regular UIKit stack and an Aurora frame loop,
not the game's guest fibers. Commit 698bfbf4a7cf852a499ac9d727bd764c2f363413
adds a separate five-cycle probe that uses the pinned donor's exported
`KartPadSwitchIOSFiber` and exact 176-byte context/256 KiB stack ABI to execute
the same SDL/Aurora frame calls from a guest stack. It preserves the original
normal-stack probe and menu tests. Workflow run 36321081068 compares iOS 18 and
iOS 27. On both systems the normal five cycles pass, but the guest-stack test
stalls after native `returned`, with no Dart launch acknowledgement or end-event
handling. Both jobs deliberately fail; their later menu steps are skipped.
The iOS 27 artifact 10932572974 records normal delays 155, 153, 153, 157, 153 ms,
then guest-stack begin 13:11:05.555, end 13:11:06.559, native return 13:11:07.122
and no further Dart progress. The host window is attached, visible, key and
active. The sampled main thread is idle in UIApplication's CFRunLoop rather
than stuck in donor cleanup. The iOS 18 job 108624904305 ends identically at
`returned`. This is a controlled integration reproduction, not proof of the
precise Flutter internal failure or physical-device resolution.

DuskLight is architecturally different at this boundary: its host CADisplayLink
calls `NeoDusklight_TickGame`, returns to UIKit between frames, and leaves SDL's
nested iOS pump disabled. KartPad calls a long-lived RuntimeMain from an NSTimer
and lets SDL pump nested UIKit loops, potentially from a guest fiber. The new
negative control establishes that changing only the event-pump stack can cause
the same class of Flutter stall.

## Candidate: keep UIKit event processing on the original pthread stack

The canonical donor session patcher now guards the pinned `UIKit_PumpEvents`
entry. The host binds the main pthread stack bounds before starting RuntimeMain;
calls on a guest stack return without entering CFRunLoop. The existing
RKSystem frame boundary pumps SDL from the startup/scheduler stack. No private
Flutter lifecycle method, fake background/foreground event, forced cancellation,
audio policy change or delayed-close workaround is introduced.

The entire original UIKit pump is hash-checked. A host binding verifies the
exact branch, gate bytes and marker, and fails closed on an incompatible donor.
Counters record accepted host-stack and skipped guest-stack pumps. ARM64 tests
execute both bound and unbound paths at five ASLR slides and boundary stack
addresses, preserving ABI registers/SP/LR. All nine bridge tests pass against
a freshly converted official IPA (SHA-256
1474809c8e14447c159c30902aaf66b022db89d28a3181d69acfac3467508f58); the language BMG
and stale-callback reset tests also pass on that candidate runtime.

The Flutter workflow must now consume the donor built from its exact SHA.
It retains normal-stack cycles, explicitly verifies the unbound guest-stack
negative control, then requires five guarded guest-stack cycles with live Dart
timers/frames and both pump counters exercised. Real menu tests also use guest
stacks.

Candidate source is `3934ac9d333247d5374b9fb7d71f8ef49bbcd79e`.
Native run 36322395443 passes all mandatory donor tests and builds artifact
10932614137. Core SHA-256 is
`995e876715b98be8fde897a88f7b93fb2357b6c47826d99c1df0a0b05a98930c`;
Runtime SHA-256 is
`ad5c00a0a508bbfcc0dc3eb1ee04a17f10919cde0b5cccd90d1d9e6a31c39eb0`.
Byte comparison to the Build 349 runtime proves that only the UIKit entry
branch, 72-byte gate and marker differ. All other runtime instructions,
including audio, renderer and language code, are byte-identical.

Flutter run 36322395458 passes normal-stack cycles, the unbound negative
control and all five guarded guest-stack cycles on both iOS 18 and iOS 27.
The iOS 18 artifact 10932119768 records guarded return delays
154, 153, 153, 153, 152 ms, with two resumed Flutter frames per interval.
Each cycle exercises both paths: skipped guest pumps / accepted host pumps
152/152, 149/149, 161/161, 177/177, 168/168. The unbound control stops at native
`returned` with no Dart acknowledgement or post-return frame/timer progress.

The iOS 18 menu XCTest still fails before the first tap. Its crash report
`Runner-2026-09-27-133558.ips` identifies the same existing MTC abort as before:
`UIKit_GetWindowSizeInPixels -> SDL_GetWindowSizeInPixels ->
aurora::window::get_window_size -> frame_worker_main`, specifically an off-main
`UIViewController.view` access. No menu success is claimed for iOS 18, and the
whole Flutter workflow must not be described as green.

iOS 27 artifact 10933147219 confirms five guarded automatic return delays of
151, 152, 153, 152, 152 ms, with two resumed frames each. The real menu XCTest
passes all assertions in 101.814 s at 13:41:21 UTC: five menu exit actions, five
new launch acknowledgements, five guarded guest-stack sessions and five return
delays of 153, 152, 153, 159, 152 ms. All cycles record both accepted and skipped
pumps. As in the earlier baseline probes, xcodebuild remains open after its
passing suite and the step times out at ten minutes. Packaging requires the
actual complete menu event report, not an invented green workflow status.

Native UIKit/CoreAudio run 36322565781 uses the same 3934ac9 donor, with probe
source `d3e558fad05feeb0838b4d3d80fc854546eaf0a4`. Attempt 1 never starts the app:
simctl reports Mach error -308 (server died), with no probe events or report.
The identical job's attempt 2 succeeds (job 108630122929, artifact 10932827839):
20 HLE reset cycles, three SDL/Metal/audio sessions, three actual frontend
CoreAudio playback recoveries, stack guard bound and six accepted host pumps.
Because both attempts have artifacts of the same name, packaging must select
the successful artifact by numeric ID, not its ambiguous name.

Build 350 packaging now binds the exact successful native/CoreAudio artifact
and both Flutter artifacts by numeric ID, verifies positive/negative controls,
the iOS 27 menu flow, and exact Core/Runtime hashes. Guarded timers/frames pass
on both simulated systems; iOS 18 menu/MTC failure and iOS 27 post-suite runner
timeout remain recorded limitations. These probes execute the shipped SDL/Aurora
instructions and real ARM64 fiber switch, not full gameplay or the user's
physical iPhone. Physical-device resolution remains unverified.
