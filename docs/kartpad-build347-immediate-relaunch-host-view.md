# KartPad immediate relaunch: Build 346 trace and Build 347 candidate

The device trace on 27 September 2026 (Build 346, pid 70861) confirms the
`userReturn` session finished normally at 09:19:56 UTC: the guest returned,
audio/GPU reset completed, the game window was hidden, and NeoStation's host
window was restored. NeoStation then immediately opened a new launch route.
The next native `launch` failed at `presentation` with
`KARTPAD_HOST_VIEW_MISSING`; the game data preflight reported
`preparedGameData=true`. This is not evidence of a failed disc import, language
write, or terminal guest runtime. The launch dialog lingered while the failure
diagnostics read a prior runtime transcript.

The bridge's old `ActiveViewController()` accepted only a foreground window
whose `isKeyWindow` flag was set, then used that window's top presented
controller. SDL creates a separate game window. UIKit's key designation can
be transient during the donor's immediate hide/restore handoff and does not
identify NeoStation's Flutter view. This source-level defect is sufficient to
explain the observed failure; the trace did not record UIKit's complete window
set at the failed instant, so it cannot independently prove which window held
the key designation.

The candidate uses the Flutter registrar's view controller as the primary
ownership witness, with a visible Flutter root in a foreground scene as a
fallback. Neither selection depends on SDL's key-window state. Hidden,
detached and background views are rejected. Native logging records whether
the selected host was key and how many Flutter candidates were considered,
without publishing a user-facing diagnostic. No donor runtime, guest state,
language or audio path is changed.

Validation: the shared host-selection policy is exercised with 100 repeated
close/relaunch decisions, including a donor window that remains key, missing
registrar view, detached/hidden Flutter views and a second foreground Flutter
scene. The iOS gate syntax-checks the actual Objective-C++ bridge against a
registrar interface with `viewController`; the full IPA must also compile the
bridge and pass its usual integrations. Device confirmation remains necessary.
