# NeoSync 207 — per-game ownership and confirmed inventory publication

Base: build 206, commit `3033ddea966ef72d64ac649460601ef16409afe7`.
Candidate branch: `fix/neosync-session-scope-build207`. Main and backup remain unchanged.

## Confirmed code defects addressed

- ARMSX2 per-game discovery accepted every savestate under a shared PS2 root.
  Both local and cloud matching now require a positive native serial or exact
  filename/title match for states. Upload checks ownership again. Memory cards
  remain shared and retain their native keys; a selected game never names a card.
- MeloNX's preferred-game resolver used the general library fallback when the
  save's native Title ID belonged to a different game. Mismatches now stop before
  fallback. Cloud matching uses the native profile/title/save ID path when present;
  old paths without that identity require an exact nonempty canonical game title.
  Missing Title IDs use an exact same-system database lookup, never a fuzzy LIKE.
- Hash-only synchronization wrote the current clock time as the save's modification
  time. Uploads now preserve native mtime irrespective of comparison strategy.
- The Dolphin adapter updated its private listing but not `onlineFiles`, which is
  what the account tab displays. All confirmed refreshes now publish to both views.
  Failed refreshes retain the previous inventory; no optimistic success is inserted.
- A native busy state was reported as a game error. It is now a distinct pending
  state, with bounded after-stop retries. Genuine file/network/conflict errors
  remain errors. Per-Dolphin bulk failures no longer colour every unchecked game
  red or prevent the other emulators from running their own synchronization.
- The internal launch hook now binds the console actually selected by the route
  even if the caller supplied a filesystem-only GameModel.

## Preservation and limits

No cloud save is deleted or renamed by this repair. Old ARMSX2 state display
metadata can be wrong; the list uses its native filename/slot rather than trusting
an old game_name. Original remote IDs, bytes, keys and metadata remain available.
An opaque PS2 state without a serial/exact title proof is not automatically attached
to a random game; the full-account backup path remains available.

Dolphin shutdown, native core/JIT, save formats, checksums, conflict protection and
restore backups are unchanged. `DiscIO::Volume::GetTitleID()` in the pinned Dolphin
revision already forwards to `GetTitleID(GetGamePartition())`; changing that call
would not fix anything and is deliberately not part of this patch.

The supplied user logs contain library import inventories, not failing cloud
transfers. The Dolphin visibility and deferred-state defects are fixed in code,
but these logs cannot prove they are the only device-side reason for zero saves.
Persistent Dolphin logging now records gate decisions, native identity, each
expected save path, local/cloud sizes and the selected sync decision. It does not
include tokens or native save payloads.

## Regression coverage

`neosync_game_scope_test.dart` covers the Hobbit/DBZ separation using explicitly
synthetic PS2 serials; exact/unknown/contradictory identities; unchanged legacy
metadata; three real-format MeloNX ExtraData directory fixtures with one selected
title; and forged or missing cloud ownership metadata.

`neosync_session207_test.dart` exercises the actual NeoSync multipart transport,
original timestamps, unchanged-hash no-op behaviour, actual native GCI and Wii
snapshot generation, typed cloud responses, immediate account-list publication,
and preservation of the previous inventory on a failed refresh. HTTP/cloud and
native ROM identity are test doubles, not an authenticated user-server/device test.
`neosync_status_regression_test.dart` additionally checks pending versus real-error
icons while keeping the existing real global-outage test.

Run the full Flutter suite, analyzer, Python/native isolation suite and the existing
Xcode/Mach-O IPA audit. Validate on device with one PS2 memory-card save, one Switch
title out of three, then one GC and Wii native save after fully quitting Dolphin.
