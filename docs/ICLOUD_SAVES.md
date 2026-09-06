# Personal iCloud Saves — candidate 208

Base: `09b3fb3ac851b327732aeb8aa8f6e3e4749dfce6` (build 207).
Candidate: `feature/icloud-saves-build208`. Stable main/backup are not changed.

## User flow

The only built-in cloud save provider is iCloud Drive. A signed-in Apple Account,
iCloud Drive enabled in Settings, and explicit initial authorization in Files are
required. The switch does not grant unrestricted access to the user's iCloud.
Select an iCloud Drive directory (or the existing NeoStation or Saves folder).
The native broker validates iCloud resource metadata and creates:

```
iCloud Drive/NeoStation/Saves/
  DolphiniOS/GameCube/
  DolphiniOS/Wii/
  ARMSX2/PlayStation 2/
  MeloNX/Switch/
  RPCS3/PlayStation 3/
  RetroArch/<native core folder>/
  <explicitly linked emulator>/<console>/
```

Emulator folders appear when actual native saves are discovered. Missing saves
are not invented. Future emulators register a `SaveAdapter`, or users authorize
only their native save directory using **Link another emulator**. Installing an
app alone does not expose its sandbox. No account password or application-owned
CloudKit entitlement is required for this Files-picker approach.

The same two-panel cloud screen is retained: connection/options on the left,
revision inventory and restore/remove actions on the right. Titles are display
metadata; console, native ID, profile, slot and path determine ownership. It shows
NeoStation bytes, not a guessed iCloud account quota. Pending copying/uploading,
confirmed upload, and errors remain distinct. Apple controls actual replication.

## Backup and restore

Native saves remain in each emulator's working directory, never on a live cloud
mount. On app startup/return and native Dolphin saves-flushed events, the provider
scans authorized sources and snapshots changed content. All game routes wait for
an in-progress restoration before launching. Disabling the feature cancels cloud
operations but does not delete native saves or previously published revisions.

Immutable payloads and their separate commit markers are coordinated by Swift
`NSFileCoordinator`, off the main thread. Paths reject traversal and symbolic
links. SHA-256 verifies staging, transfer and restoration. Native modification
dates are preserved. Unchanged bytes do not manufacture a new current-day save.
A durable, separately scoped private outbox is retained until Apple reports both
payload and marker uploaded. Partial listings never erase a known inventory.
Pending outboxes cannot be silently sent into a different newly authorized folder.

Two independent devices create separate revisions; there is no time-based
last-writer-wins overwrite. **Restoration is explicit**, after downloading and
verifying a complete revision and checking that local data did not change during
the operation. An old local copy and recovery journal are retained. Directory-root
restores stay within the authorized folder (no ungranted parent rename). Interrupted
root-folder restores with unexpected contents require review and keep the complete
private original rather than overwriting newer unknown data. An unresolved restore
journal blocks automatic backup/restoration until reviewed, so incomplete native
contents are not silently published as a valid new save.

Removing a revision moves its cloud files to `.Trash` and records an immutable
content tombstone. Native saves remain unchanged. Identical removed content does
not get uploaded again at the next startup. A genuinely changed save can create a
new revision. Version history has no automatic destructive pruning in this build.

## Native units

- DolphiniOS: verified per-game GCI groups, regional shared raw memory cards,
  complete single-title Wii data directories, and numbered four/six-character
  native savestates. Existing core/JIT/save locks and format validators remain.
- ARMSX2: shared PS2 memory cards and positively identified or explicitly
  unidentified native savestates. Memory cards are never mislabeled as one game.
- MeloNX: committed LibHac Account/Device save units with ExtraData, profile,
  title and save IDs. Restore requires the matching locally registered save unit;
  the app does not fabricate emulator profile IDs on a fresh installation.
- RPCS3: complete per-profile savedata directory bundles, including extensionless
  members and native metadata, not arbitrary Data/NAND/ROM content.
- RetroArch: configured saves/states, complete PSP savedata groups and shared
  Flycast VMU cards. Native core folder paths remain separate.
- Other emulators: complete explicitly selected save directories. Opaque formats
  are not guessed from file extensions or assigned to a random library title.

General native bundles use a streaming `NSCS0001` envelope (schema 1, JSON member
manifest plus native bytes). Limits are 512 MiB and 8192 members per unit, not a
claim of unlimited cloud storage. Native Dolphin limits remain format-specific.
The folder contains versioned restore bundles rather than emulator live files.

## Removal and data preservation

There is no old server provider, HTTP API, authentication/billing/subscription
flow, account WebSocket, quota plan, or account-dependent save gate in the app.
No old remote saves are deleted or automatically imported. Remote-only saves must
be recovered using the previous app before moving exclusively to this build.

A tiny `LegacySaveMigration` shim only reads old catalog keys, adds a neutral
SQLite column and removes the retired account token. Old data columns are retained
inert for rollback; other secrets, existing folder grants and library rows are not
deleted. Database version stays 112 because older builds destructively recreate
unknown newer versions. Git history and third-party copyright/license notices are
not rewritten to hide provenance.

## Validation boundary

Automated tests exercise real snapshot bytes, identity isolation, corruption,
outbox retry/confirmation, account-scope changes, cancellation, explicit restore,
and unchanged-content deduplication. Native folder-provider/account traffic in
Dart tests is a test double. Full Flutter analysis/tests, Python isolation tests,
iOS Simulator menu tests, Xcode compilation and the actual IPA Mach-O audit remain
required. Passing them is not proof of a successful real iCloud transfer.

Before a stable release: test one actual GameCube save and one Wii save through
save, fully close, upload confirmation, second-device download and restoration;
then repeat console by console. Test no account, disabled iCloud Drive, a revoked
bookmark, offline restart, insufficient storage, simultaneous devices and a
cancelled/interrupted restore. Keep the previous IPA and independent save copies.
