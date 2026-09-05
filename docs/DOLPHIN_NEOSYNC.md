# NeoSync for the embedded Dolphin engine

This candidate extends the Build 200 native-save adapter with numbered Dolphin
savestates and restores filenames in the NeoSync cloud list. It retains the
existing account, JIT policy and separate emulator integrations.

## Use

Enable NeoSync for the GameCube/Wii game using the existing per-game cloud switch.
The account must be authenticated and its subscription/quota must permit the
operation. No external DolphiniOS folder or application is required.

The in-game DolphiniOS menu has separate **Save state** and **Load state** entries
on both Wii and GameCube. Each lists slots 1–10 with filenames and dates. Empty
or unreadable slots cannot be loaded. Replacing a slot or loading one asks for
confirmation; navigation waits for the native operation to finish. Creating a
checkpoint writes a native Dolphin state; loading a
checkpoint resumes that exact emulator state. NeoSync synchronizes those slots
using the same per-game cloud switch as ordinary in-game saves.

With auto-sync enabled, NeoStation checks this game's saves before launch and
uploads changes after native Dolphin shutdown has joined the emulation thread
and released the session. Closing a settings panel, pausing, or backgrounding the
app is not a completed session and never authorizes a live-save overwrite.

An already running Dolphin session defers synchronization. A cloud problem does
not change the JIT policy or redirect the game to another emulator. A missing
save is not uploaded as an empty replacement.

## Build 203 session controls

Save and load slots show the library game title as well as the unchanged native
filename. NeoSync displays game titles for Dolphin savestates; internal GameCube
save objects use **GC Memory cards** instead.

The chart button beside the in-game menu toggles a passive performance overlay:
real Dolphin FPS/VPS, speed, average frame time and variation, a 60-second graph
of frame intervals sampled twice per second, and the allocated internal EFB
resolution. It does not measure every frame spike, and stops sampling while
hidden or while settings are open. No GPU readback or CPU pause is used.

Graphics selections persist in the session preferences and override game INI
values on the next boot. The GPU's reported dimensions allow the selected scale
to be checked after resuming. Cached shader compilation is completed before
play where supported, so startup may take longer. This reduces a source of
stutter; it does not guarantee a fixed frame rate on every device or game.

The Wii playlist import menu also offers **Launch Wii Menu**. Import your own
extracted NAND containing the installed System Menu, its ticket and content
files. Keys or boot2 alone do not contain the menu. Dolphin supplies IOS HLE;
no separate installed IOS binary is required. This uses the same embedded JIT
checks as a game and does not create a game-specific NeoSync upload session.
Game save-state actions are omitted in this system session.

A stopped game releases CPU/GPU/audio/NAND resources before UIKit removes its
view. Process-wide Dolphin input/config services remain initialized, following
the upstream frontend lifecycle. The next console waits until UIKit has finished
closing the previous game and settings, including a transition already in flight.

## Build 204 relaunch and cloud presentation

Every new game requires a fresh, authenticated `pid_attached` event from that
launch's StikJIT helper before executing Dolphin's legacy breakpoint handshake.
The event must name the current process. The persistent `CS_DEBUGGED` flag alone
does not prove that the new debugger has attached after a previous game.

Metal shutdown drains pending GPU work and retires its completion callbacks
before destroying the objects those callbacks reference. These address concrete
relaunch and teardown hazards; the reported device crash still requires an
on-device retest.

Cloud presentation accepts the API's short filename plus canonical `file_path`
form, so old Dolphin savestates can recover their game title from the local
library's native game identity. This lookup does not rewrite their cloud keys or
upload their content again. Internal GameCube saves retain the generic card
label. The individual numbered slots remain distinct.

`ICON0.PNG`, `PARAM.SFO`, `PIC1.PNG`, `SYSDATA` and `PLAYDATA` can be constituent
files of PlayStation save directories, not stray Dolphin files. Such components
must remain available for restoration; a recognized common save path supplies
their display context. The subsequent user-requested saves-only cleanup checks
provenance before deleting non-save objects; savedata components are preserved.
If the server omits the upload date, an available file timestamp is displayed
instead of replacing it with today's date; legacy Unix-second values are
normalized to the millisecond representation used by current uploads.

The pinned Metal backend does not implement or link MetalFX. MetalFX upscaling
requires a separate rendering integration; it is not an existing graphics
setting this build can enable.

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
- GameCube and Wii savestates: individual `User/StateSaves/<GAMEID>.s01` through
  `.s10` files, scoped to the native game identity and numbered slot. Wii game
  channels with four-character IDs are included when those bytes match the
  native title ID. State headers must belong to that exact game. Temporary
  writes, undo states, movie recordings, backups and another game's slots are
  never uploaded. Missing slots do not become empty uploads or cloud deletions.

Games, IPL, firmware/system content outside the title's save directory, pairing
files, credentials, JIT data, global configurations and shader caches are excluded.

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

Savestates use separate `v2/states/gc/dolphinios/game/<GAMEID>/` and
`v2/states/wii/dolphinios/game/<TITLEID>/` namespaces. Each object is named
`<GAMEID>.sNN.nsav` and is uploaded with `is_state=true`. Its deterministic binary
version-2 envelope contains `NSDSV002`, a little-endian 32-bit JSON-header length,
a small UTF-8 header (format, version, exact cloud key, native filename, size and
SHA-256), then the unmodified native state bytes. Snapshot creation streams the
large native data rather than expanding it into base64. Each native state may be
up to 192 MiB, covering Wii checkpoints larger than the ordinary-save 40 MiB
limit. Existing account quotas and transport limits still apply.

These objects can be restored by NeoStation versions implementing this adapter.
They are not claimed to be automatically compatible with the original desktop
NeoStation, external DolphiniOS, or RetroArch's existing cloud-save formats.
The native files inside retain their original format; no cloud migration is
performed on older objects. A cloud export of `.nsav` preserves the envelope.
Savestates require a compatible Dolphin state version when loaded; NeoSync does
not convert emulator state formats. The embedded core reports incompatible
versions instead of resuming them. Older NeoStation versions without the state
adapter cannot restore these new objects and must not route them to RetroArch.

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
and retains a previous local copy. Savestate restore validates the complete
envelope and native header, retains a previous local slot, then atomically
renames a flushed temporary file over that slot. Large file encoding/restoration runs in an
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
State fixtures also cover all ten native slots, Wii game-channel identities,
exact binary round trips above 40 MiB, corruption, wrong-game/slot rejection,
temporary/undo/backup exclusion, symlinks and preservation of adjacent slots.
The Build 202 bridge explicitly enables Objective-C ARC and copies slot-list JSON
before leaving the host queue. Native state compression uses independent 1 MiB
LZ4 blocks in the existing format to bound its additional workspace. Executable
codec tests cover block boundaries, old single-block files and write failures.
Simulator tests exercise separate save/load pages for both consoles, deferred
callbacks, unavailable slots, duplicate input and recovery after a failed write.

CI compiles all existing integrations and verifies the native identity ABI in
the actual IPA. Unit fixtures and compilation do not prove an authenticated
round trip against a real NeoSync account or a launch on an iPhone/iPad. Those
remain device/account validation steps for this candidate.


## Saves-only rule and source investigation (build 204)

NeoSync's two upload gateways now reject anything not identified as an internal
save or savestate. Scans do not follow links. The MeloNX resolver previously
accepted a Title ID anywhere under the linked folder, including installed DLC;
it now requires the actual `user/save/0000000000000000/.../<application-id>/`
source tree. Packages (`.nsp`, `.nca`, `.xci`, etc.) never enter that save stream.
Restore directory lookup uses the same restriction.

Opening or refreshing NeoSync obtains a complete v2 inventory and investigates
origins before cleanup. The historical v1 inventory is checked too. Only proven
non-save IDs are deleted, with the inventory's authentication token bound to
all requests. Account changes stop cleanup; failed deletes stay visible and are
retried on the next refresh. The UI reports deleted, failed and unresolved counts.
No local emulator data, installed game or DLC is deleted by cloud cleanup.

PS3 saves retain the native `dev_hdd0/home/<profile>/savedata/<save-directory>/`
structure and original bytes. Each profile/save directory is grouped separately;
exports reconstruct that native structure rather than exporting loose metadata
files. Recovered canonical paths drive restoration without changing API IDs or
transport filenames. If only a basename remains, the app searches linked RPCS3
savedata and MeloNX native user-save trees for an exact filename, size and checksum match; multiple matches remain
unresolved. Ambiguous Switch config/content members are also investigated instead
of being deleted on filename alone. VMU, Saturn backup RAM and RTC saves are retained. A game title or a familiar icon is insufficient evidence. PS3/PSP
bundle members (including PARAM.SFO/PFD, PNGs and extensionless data) are preserved.

Unknown historical objects are not automatically destroyed. They are excluded
from new uploads/restoration until identified and reported as unresolved. These
rules intentionally distinguish a blocked upload from evidence sufficient for
irreversible deletion. Actual account cleanup runs on the authenticated device;
CI does not hold or access the user's NeoSync account.
