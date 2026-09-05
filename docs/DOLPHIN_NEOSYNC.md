# NeoSync for the embedded Dolphin engine

This candidate adds native-save synchronization to the existing NeoSync account
and UI. It starts from stable Build 198. It does not modify the published stable
IPA, the StikJIT policy, controls, rendering, or other emulator integrations.

## Use

Enable NeoSync for the GameCube/Wii game using the existing per-game cloud switch.
The account must be authenticated and its subscription/quota must permit the
operation. No external DolphiniOS folder or application is required.

With auto-sync enabled, NeoStation checks this game's saves before launch and
uploads changes after native Dolphin shutdown has joined the emulation thread
and released the session. Closing a settings panel, pausing, or backgrounding the
app is not a completed session and never authorizes a live-save overwrite.

An already running Dolphin session defers synchronization. A cloud problem does
not change the JIT policy or redirect the game to another emulator. A missing
save is not uploaded as an empty replacement.

## Included saves

- GameCube GCI directories: per native game ID, region (USA/EUR/JAP), and slot
  (A/B). GCI headers determine ownership; ROM filenames and scraped titles do not.
  Restoring one game preserves the other games in that slot.
- Existing GameCube raw memory cards: shared objects, separate by region and
  card filename. A raw card contains multiple games: enabling a game using one
  synchronizes the complete shared card, not an individually extractable save.
- Wii: a complete `data` directory for the native title ID, including nested
  files and directories. Disc and supported game-channel title namespaces only.
  Other titles, IOS, installed program content, tickets and device files are not
  part of the snapshot.

Games, IPL, firmware/system content outside the title's save directory, pairing
files, credentials, JIT data, global configurations and shader caches are excluded.
Save states / instant emulator checkpoints are **not included** in this version.

DiscIO reads native IDs from the image before core/JIT initialization, including
supported compressed image formats. Unreadable identities are reported instead
of guessing a restore destination. The integration uses the stock private User
layout of the embedded build; manually overridden Dolphin save locations outside
this layout are not scanned or migrated.

## Cloud format and compatibility

The existing NeoSync v2 transport carries deterministic version-1 `.nsav` JSON
snapshots in `v2/saves/gc/dolphinios/...` or `v2/saves/wii/dolphinios/...`.
Each object binds its console/native identity and contains relative paths,
base64 file bytes and SHA-256 entry checksums. It is not an executable or ZIP.
The object uses the existing API's MD5 content checksum for sync comparisons.
No absolute local paths, device IDs or account identifiers are embedded.

These objects can be restored by NeoStation versions implementing this adapter.
They are not claimed to be automatically compatible with the original desktop
NeoStation, external DolphiniOS, or RetroArch's existing cloud-save formats.
The native files inside retain their original format; no cloud migration is
performed on older objects. A cloud export of `.nsav` preserves the envelope.

## Integrity and conflicts

The client compares local content, cloud content and the last common checksum,
with history isolated per account and native key. Different first-sync content,
or independently modified copies, is reported as a conflict rather than using
timestamps to choose an arbitrary winner. The existing explicit cloud-restore
control chooses the cloud copy and retains the previous local snapshot. To keep
local content instead, first export the cloud object, then delete that object
using the existing NeoSync file manager and synchronize again.

A restore validates the object key, version, sizes, complete file checksums and
all paths before replacing live data. Traversal, symbolic links, case-folded
collisions and file/directory conflicts are refused. GCI headers and block counts
are validated. Directory replacements are staged with rollback/recovery; previous
native snapshots are retained. Raw-card replacement uses a flushed temporary file
and retains a previous local copy. Large file encoding/restoration runs in an
isolate rather than on Flutter's UI isolate.

Cloud listing is paginated for Dolphin and fails closed on transport errors or
repeated pages. Upload success is confirmed from cloud content before recording
success. This is client-side conflict protection using the existing NeoSync API,
not a new server-side compare-and-swap protocol: simultaneous writes from two
connected devices still require care. Do not play the same save on two devices
at once; check the per-game status before switching.

## Diagnosis and validation scope

Logs identify `[NeoSync][DolphiniOS]` and `neosync.*` stages in Dolphin's persistent
log: listing, upload, restore, explicit restore, conflict/failure, quota and busy
state. Unknown native running state refuses save access. No JIT is required for
an offline save-directory operation or for reading DiscIO identity.

Tests cover native-key isolation, deterministic snapshots, multi-file Wii saves,
GCI ownership, preservation of adjacent games, corruption, unsafe paths, backups,
interrupted replacements, account-scoped history, and exclusive access.
CI compiles all existing integrations and verifies the native identity ABI in
the actual IPA. Unit fixtures and compilation do not prove an authenticated
round trip against a real NeoSync account or a launch on an iPhone/iPad. Those
remain device/account validation steps for this candidate.
