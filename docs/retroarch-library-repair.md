# Library identity and RetroArch handoff correction

This change is not a claim of successful gameplay on iOS. It addresses verified
storage and handoff defects; the remaining device checks are required.

- `user_roms` has no `id` column. Bookmark relocation now updates by `rom_path`.
- Embedded libraries reconcile their fixed source namespace and complete relative
  paths after a container move, before a scan inserts new rows. The target must
  exist and the old path must be inaccessible. A synchronous transaction archives
  the original rows before changing paths or merging compatible metadata.
- The offline `tools/retroarch_playlist_repair.py` compares original `.lpl` paths
  (including archive members) with a read-only database. It can create a separate
  backed-up candidate database and records persistent repair bindings. Repeated
  restoration and archive launch honor these full-path bindings; bookmark
  relocation updates their targets. Launch never replaces a verified binding
  with a filename alias.
  It never changes ROM files. Conflicting systems, histories, scraper metadata,
  ambiguous names and multi-content archives are not merged.
- Export records are retained separately from filename aliases. The external
  filename-only URL route cannot distinguish homonyms; these fail explicitly.
- Library and game requests send their functional URL once while NeoStation
  is active. The old preliminary `retroarch://start` followed by a one-second
  delay moved the actual request into the sender's background state. A finite
  background task does not establish the receiving application's readiness.
  The proposed mandatory library round trip before each game was removed.
- Native rejection, timeout, expiration and concurrent request failures retain
  their technical reasons under the existing translated launch error.

The external protocol was checked in libretro/RetroArch at
`a69980050e2d99c8877a84bf7e516d2bd5353f15`: `RetroArchPlaylistManager.m`,
`cocoa_common.m`, `ui_cocoatouch.m` and `libretro-common/file/file_path.c`.
That source revision is not asserted to be the exact TestFlight binary.

## Remaining limits

The unvalidated mandatory readiness round trip was discarded. Request,
transport acceptance, callback and timeout now have separate diagnostics.
`tools/test_retroarch_uikit_handoff.py` compares the production sender with the
original `af0d539` implementation in two disposable iOS simulator apps. The
receiver models the inspected scene routing, not a RetroArch core or playlist.
Its evidence distinguishes real UIKit transport from synthetic URL processing.

The upstream cold-scene URL omission is a separate limitation: a cold request
can be accepted by UIKit but discarded inside RetroArch. No unacknowledged game
request is automatically retried. A successful warm transport test cannot be
reported as proof of a successful cold launch or actual gameplay.

Follow-up device evidence: the user reports the same result after opening
RetroArch to its menu first, returning to NeoStation and requesting sync. The
attached screen shows RetroArch 1.22.2 at its main menu, no loaded core, and a
configuration-saved notification. That notification supplies no URL-delivery,
export, callback or game-start result. A cold-start-only explanation is therefore
insufficient; the failure also reproduces with RetroArch already running.

Automatic discovery and reconciliation of new full playlist identities is still
unfinished. The repair bindings prevent recurrence for the repaired pairs;
unbound mixed-source restoration still has an explicit audit reproduction.
An external library callback acknowledges an initialized catalog, not a running
core. UIKit open acceptance is not game-start confirmation. Actual iPhone
cold/warm launch, missing file/core/BIOS errors, archive/M3U execution and save
continuity still require device validation. Concurrent success scenarios are
covered; complete isolation of failures across all database users is not claimed.

## Repair and rollback

Run the tool only against a current offline copy. Omit `--repair-copy` for an
audit only. `--repair-copy candidate.sqlite` also creates
`candidate.original.sqlite` and refuses to overwrite existing copies. Preserve
that full backup and the original playlists. Review the unresolved entries and
validate device file access before deploying any repaired database.

Code rollback alone does not reverse database repair. With no later user changes,
restore the matching full database backup while the app is closed. If sessions
or metadata have changed, reconcile those changes before restoring any snapshot.
The `user_library_path_repair_v1` and `user_retroarch_repair_v1` tables retain
original rows for selective recovery. Never remove bindings from a repaired
library and then run an importer that will recreate its old virtual entries.
