# KartPad candidate after Build 338 — audio lifecycle

The user's `console(6).log` identifies Build 338. Manual return was requested
at 20:48:56.387; the guest title transition and AX/GPU drain completed at
20:48:56.878 (491 ms). The file ends with the donor's normal transcript-close
marker. It contains neither the earlier language-restart crash nor host cleanup
after RuntimeMain. It cannot establish the cause of the remaining ~15-second
UI delay or prove all native resources were released.

## Confirmed defect and correction

The packaged donor's `aurora::window::shutdown` calls SDL_Quit. Its persistent
AudioBackend retains the stream at offset 0x40 and initialized flag at 0x5c.
The actual ARM64 EnsureInitializedLocked guard returns success for a repeated
32000 Hz/stereo initialization without checking whether SDL destroyed that
stream. SetPausedForHost also dereferences the retained stream. No exported
AudioBackend::Shutdown exists in this donor.

The host now joins AX, locks the backend's Darwin mutex, destroys its audio
stream, balances its SDL audio subsystem reference, and clears only its stream,
sample-rate/channel and initialized fields, before Aurora's global SDL teardown.
Volume, mute preference, mutex and conversion storage remain intact. The exact
84-byte donor instruction witness is checked before accepting this private ABI;
a mismatched donor fails initialization instead of accepting guessed offsets.

The HUD return button is removed. The settings menu retains Return to NeoStation
and Return to Game, using the existing twelve-language catalog.

`neostation-kartpad-lifecycle.log` in Documents/Ports/KartPad records low-volume
host boundaries independently of the donor's redirected console, including
audio release and the host steps after RuntimeMain returns.

## Evidence and remaining work

- Production audio helper: 1,000 release/release cycles; no double destroy;
  preferences and unrelated bytes preserved.
- Actual packaged ARM64 donor: stale stream reuse reproduced, and real helper
  output forces the reinitialization branch, across three ASLR slides.
- Existing frame-return machine tests: passed (100 register/stack cases).
- Bridge/menu lifecycle contracts: passed.
- Xcode build and on-device acceptance: pending at time of this source change.

These are focused tests, not complete in-game cycles. The language-restart crash,
frontend silence and long return still require device verification; the audio
defect is not claimed to explain all three. Do not call the candidate validated
on iPhone or overwrite the Build 338 artifact with it.
