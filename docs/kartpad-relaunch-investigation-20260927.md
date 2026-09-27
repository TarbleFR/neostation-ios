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
