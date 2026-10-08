# RetroArch TestFlight link recovery — 8 October 2026

## Confirmed source defects and scope

The official RetroArch URL scheme and export format remain unchanged:
`retroarch://library?scheme=neostation`, `neostation://retroarch?games=<base64url>`,
and `retroarch://game/<filename>`.

Upstream commit `630b36bd774c873b73bfaa59183822837dbc9aac`, dated
16 September 2026, introduced `UIApplicationSceneManifest` and
`RetroArchSceneDelegate`. Its `scene:willConnectToSession:options:` creates
a window but never consumes `connectionOptions.URLContexts`. UIKit delivers
the initial URL there when a scene is created; the separate
`scene:openURLContexts:` only processes URLs for an existing scene. This defect
still exists in the official sources inspected at
`a69980050e2d99c8877a84bf7e516d2bd5353f15` on 8 October. The exact TestFlight
binary installed on the user's phone was not available for inspection.
This is a confirmed upstream cold-launch defect and a plausible explanation
for the reported new beta regression, not a verified identification of that
binary's revision.

NeoStation previously sent the functional URL as the first cold-launch URL.
It returned transport acceptance without monitoring a response timeout, accepted
empty exports over a usable cache, and resolved folder bookmarks without
rebasing the registered SQLite ROM roots. These defects are directly visible
in the inspected NeoStation sources at
`12fb62f979f5e6a2317e75e9dcfc01e268bfa018`.

## Superseded handoff sequence

The start-then-delay sequence below was the Build421 candidate, not the current
correction. It moves the functional request into the sender's background state.
See `retroarch-library-repair.md` and the UIKit transport regression harness for
the replacement: one functional URL while NeoStation is active. The original
unit fixture accepted all opens and did not model sender visibility.

## Build421 candidate behavior (historical)

- Open the harmless `retroarch://start` first, then send one functional URL
  to the running scene after one second. A native background task keeps this
  sequence alive across the app switch; expiration or rejection fails the
  handoff. Functional game launches are never blindly duplicated.
- Buffer incoming URLs until the Dart listener is installed, including cold
  callbacks while NeoStation is restoring its storage.
- A sync succeeds only after a valid nonempty export is imported into SQLite
  and persisted. The last valid cache restores missing catalog rows at startup. Duplicate
  requests share one pending export, and a missing response expires after
  15 seconds. Empty or malformed exports preserve the previous cache. The
  UI explains each outcome in all twelve existing language catalogs.
- Re-resolve RetroArch's bookmark before scans. Rebase known roots and ROM
  paths transactionally, preserving row IDs, favorites, play time and metadata.
  The previous root comes from the same native bookmark (captured before its
  refresh) or the persisted RetroArch root. Matching a ROM filename or another
  app's container UUID does not establish ownership. Access denial or path
  collisions retain the existing library. Unavailable bookmarks and five stale
  manual roots cannot block native indexing or prevent a newly linked managed
  RetroArch source from registering. Exact trailing spaces and Unicode are kept.
- Prune only directories whose complete walk succeeded on iOS; preserve rows
  from inaccessible/unscanned sources and all emulator-owned virtual catalogs.
  Keep system detections and their hidden states while retained games exist.
- Always expose GameCube, Wii, PS2, PS3 and Ports from the iOS catalog, including
  before scanning and after failures. A failed scan ends its loading phase;
  stored systems can render even while the startup scan has not completed.
- Imported virtual RetroArch rows carry the exact exported system and filename;
  native GC/Wii, PS3, Switch and Ports retain independent ownership. Matching a
  physical filename only reuses rows under an authoritative RetroArch bookmark.


No emulator core, JIT helper, save file, firmware or pairing file is changed.
The protocol does not echo request IDs, so a callback cannot prove which of
two separated requests produced it. The implementation serializes requests,
does not automatically retry exports, and does not revive an expired waiter.

## Verification and practical limits

Build421 reproduces the user-supplied five stale source paths, the missing
source-slot exception and the blank home phase reported on Build420. Local
Flutter validation covers 36 behavior/contract cases, including 4,842 synthetic
export entries restored twice without duplication, SQLite metadata retention,
actual callback-to-database import, cold-cache restoration, complete/failed walks,
exact space/Unicode filenames and embedded tiles. Analysis has no errors or
warnings; existing informational findings are distinguished from failures.
The unchanged Swift handoff has six behavior cases. macOS exact-SHA gates and
IPA validation are mandatory before delivery; physical iPhone validation is
still pending and cannot be inferred from these synthetic fixtures.

`retroarch-link-check.yml` runs behavioral Flutter tests for real callback
parsing and persistent cache preservation, serialized requests, missing and
malformed responses, SQLite relocation/rollback, archive launch identifiers,
and all twelve translations. Existing resolver and ARMSX2 isolation tests
also run. The native test executes the production Swift handoff with a
simulated cold scene, expiration, rejected routes and delayed callbacks.

The native test does not emulate SpringBoard or authorize URL opening from a
background task. The complete IPA build type-checks the UIKit plugin, but
physical-device validation remains necessary: RetroArch killed then sync;
RetroArch already running then sync; launch a normal ROM and a zipped ROM;
update RetroArch then rescan; unavailable or empty playlists; return to
NeoStation after the 15-second timeout. Check that each game starts once,
favorites survive, and the previous library remains visible on failure.

Primary references:

- https://github.com/libretro/RetroArch/commit/630b36bd774c873b73bfaa59183822837dbc9aac
- https://github.com/libretro/RetroArch/blob/a69980050e2d99c8877a84bf7e516d2bd5353f15/ui/drivers/ui_cocoatouch.m
- https://github.com/libretro/RetroArch/blob/a69980050e2d99c8877a84bf7e516d2bd5353f15/ui/drivers/cocoa/RetroArchPlaylistManager.m
- https://developer.apple.com/documentation/uikit/uiscene/connectionoptions-swift.class/urlcontexts
- https://developer.apple.com/documentation/foundation/nsurl/resourcevalues(forkeys:frombookmarkdata:)
