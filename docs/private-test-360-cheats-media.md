# Private test 360 — cheats and frontend media

This candidate is not a GitHub Release. The existing release 0.0.1, its tag and
NeoStation.ipa remain unchanged. The build uploads only CMS-encrypted IPA bytes
for delivery to the requesting maintainer, not a plaintext downloadable IPA.

## Changes

- Opaque, explicitly dark Dolphin/ARMSX2 settings surfaces; readable adaptive
  footer text, no game controls showing through the Dolphin menu.
- Dolphin exact-ID catalogues: WiiRD/Gecko plus exact GameID/revision GameINI
  files from Dolphin. Missing entries are distinct from network/format errors.
  No PAL/NTSC or revision substitution. G4BP08 currently has no record at the
  queried Gecko endpoint (HTTP 404), so an empty catalogue is not proof that no
  compatible cheats exist elsewhere.
- Manual paste/file import from both native menus: Gecko, raw/encrypted Action
  Replay and Dolphin INI; PS2 PNACH. Strict syntax/size checks, atomic storage,
  previous Dolphin INI backup, creator credits preserved and new codes OFF.
- PS2 imported files deliberately use a CRC-only filename. The pinned upstream
  ARMSX2 loads serial_*.pnach cheats across CRC revisions; CRC-only names avoid
  accidentally loading a user import into another revision.
- Shared frontend media barrier around the launch service used by library,
  favorites, recents, search and system-card launches. It awaits disposal of
  primary previews, background videos and secondary-screen previews and rejects
  late initialization/timers throughout the session.
- Native Dolphin/RPCS3 liveness replaces unsupported iOS process polling. Pause,
  in-game menus, foreground callbacks and transient probe errors cannot imply
  that the game ended or restore frontend audio. Existing KartPad/Dusklight/
  ARMSX2 teardown bodies and native emulator binaries are retained.
- Previous license/credits changes from main are included in this future build.

## Automated evidence

The dedicated workflow executes C++ parser fixtures, actual Foundation INI/PNACH
atomic storage tests, real iOS arm64 compilation of the native menu/editor code,
Flutter analysis and frontend-media/native-liveness regression tests. Native
core ABI declarations and retained KartPad lifecycle code are checked separately
from the changed UIKit host code. Passing packaging is not physical-device play
testing and does not establish that arbitrary imported cheat addresses work.

## Device checks still required

1. Keep an audible gameplay preview selected, launch Dolphin, open/close its menu,
   background/foreground NeoStation, play for longer than the old polling delay,
   then quit. Only game audio should be heard during the session.
2. Repeat through PS2, PS3, both Ports, favorites/recents/search and external
   RetroArch. No preview timer or background video should restart in gameplay.
3. Open RE4 G4BP08 cheats: footer must be readable, empty exact catalogues must
   be reported as unavailable (not a generic connection failure).
4. Paste/import compatible test codes. Inspect, save disabled, explicitly enable,
   relaunch and verify persistence. Wrong game/revision/CRC, malformed lines,
   duplicate names and Hardcore imports must be rejected without data loss.
5. Re-sign/install NeoStation.ipa with the same required entitlements as the
   existing installation. Do not publish this candidate as a release.
