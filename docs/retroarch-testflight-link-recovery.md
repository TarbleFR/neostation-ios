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

## Candidate behavior

- Open the harmless `retroarch://start` first, then send one functional URL
  to the running scene after one second. A native background task keeps this
  sequence alive across the app switch; expiration or rejection fails the
  handoff. Functional game launches are never blindly duplicated.
- Buffer incoming URLs until the Dart listener is installed, including cold
  callbacks while NeoStation is restoring its storage.
- A sync succeeds only after a valid nonempty export is persisted. Duplicate
  requests share one pending export, and a missing response expires after
  15 seconds. Empty or malformed exports preserve the previous cache. The
  UI explains each outcome in all twelve existing language catalogs.
- Re-resolve RetroArch's bookmark before scans. Rebase known roots and ROM
  paths transactionally, preserving row IDs, favorites, play time and metadata.
  The previous root comes from the same native bookmark (captured before its
  refresh) or the persisted RetroArch root. Matching a ROM filename or another
  app's container UUID does not establish ownership. Access denial or path
  collisions retain the existing library and stop destructive pruning.

No emulator core, JIT helper, save file, firmware or pairing file is changed.
The protocol does not echo request IDs, so a callback cannot prove which of
two separated requests produced it. The implementation serializes requests,
does not automatically retry exports, and does not revive an expired waiter.

## Verification and practical limits

Local validation completed with Flutter 3.47.2 and Swift 6.2 on Linux:
22 Flutter tests passed, including persistent cache and real SQLite behavior;
6 Swift handoff behavior cases passed with warnings treated as errors.
Analysis of the changed integration returned no errors or warnings (four
informational findings remain in existing context-handling/documentation).
The iOS UIKit plugin has not been type-checked locally; that check and IPA
packaging require the macOS CI runner. Remote push was initially blocked by
automatic approval review; the maintainer authorized publication and Build420
on 8 October. The first CI gate caught the obsolete Build419 scope contract.
Its update admits only the reviewed RetroArch additions, preserving every
existing native identity and gate. CI and IPA results remain pending here.

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
