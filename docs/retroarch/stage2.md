# RetroArch application integration — candidate behavior

Work remains on `feature/retroarch-embedded`. Existing DolphiniOS, RPCS3,
ARMSX2, StikJIT and NeoSwap binary inputs are unchanged. Changes to `ios-ci.yml`
prepare embedding for a later integration; this branch does not trigger that
workflow's `experimental` push build.

## Libraries and emulator selection

Fresh installations display only the consoles selected during onboarding.
The same picker handles the curated RetroArch systems, PS3, PS2, GameCube,
Wii and Ports. Settings can show or hide them later without deleting games,
BIOS or saves. Existing users retain their prior visible libraries.

When embedded RetroArch is selected, each console's activation row includes
its compatible packaged cores. The choice remains editable beside Import
and in game settings, with an optional per-game override. Compatible legacy
SQL core choices are read without rewriting the old database. Explicit new
preferences take priority. Mega Drive/Genesis share one visibility choice
while retaining their original library identifiers and game data.

External RetroArch keeps its existing game URL and playlist core choice.
The interface explains that those cores are selected inside external
RetroArch, since its verified game URL does not accept a core override.
Missing or unverified native metadata prevents offering an embedded core.

The catalogue has 87 cores and 84 existing library identifiers. Alternative
SNES and Mega Drive cores, PSP and N64 are included. Incompatible renderers,
experimental entries and absent framework binaries are excluded. This is a
reviewed candidate catalogue; gameplay and performance still require iPhone
qualification for each offered runtime profile.

## Files and migration

`Documents/RetroArch` exposes `system`, `games`, `saves`, `states`, `config`,
`shaders`, `overlays`, `cheats` and `logs` through Files. New installations and
accepted migrations initialize these folders before the first game. Imports
support files and folders, including relative sidecars and shader/overlay
assets. Already authorized readable external game folders remain usable.
Executable cores remain inside the signed bundle.

An existing user is offered a one-time optional switch to embedded RetroArch.
The dialog follows the language selected in NeoStation; every added label and
error has all twelve translations. Declining preserves external launch mode.
Settings can reopen migration later.

The user selects the source folder through Files. Migration copies files and
preserves originals, verifies size and SHA-256, writes through atomic staging,
and offers skip or backup for collisions. Folder overlap and escaping links
are rejected before writes. Relative references are repaired; original
configuration files are retained and executable paths are not imported.
The frontend reads raw, RASTATE1 and supported RZIP state files through the
pinned upstream decoders. State compatibility requires the same actual core
and compatible game/version; emulator variants are not converted.

## Session and native menu

NeoStation owns the UIKit controller and session. Availability does not start
a game. Launch is acknowledged after a real submitted game frame; shutdown
retains ownership until backend acknowledgement and view dismissal. Late
callbacks are isolated by session generation.

The native menu provides save/load states, core options, GLSL shader presets,
overlays, supported cheats and quit. Unsupported commands report translated
errors with separate technical details. Select+Start opens the same menu.
Initial protected options prevent switching selected cores to JIT or
incompatible renderers through imported configuration or the menu.

## Validation before experimental

The application workflow runs focused library, preference, migration, import,
locale and session behavior tests, plus existing media-barrier and emulator
routing regression checks. Native checks use the real Apple SDK and UIKit
lifecycle harness, the production Ruby host configurator, and the actual
hosted frontend compiled from its pinned source. File decoder checks compile
the production importer with genuine upstream RZIP and RASTATE code under
address and undefined-behavior sanitizers.

Embedding validates frontend ABI/identity, core and asset hashes, dependent
libraries, source provenance and Files flags. Final IPA verification is a
required gate. Every workflow artifact includes the exact candidate SHA.

Before merging into `experimental`, verify the complete generated host and
IPA, then first launch, quit/relaunch, emulator alternation, imports, old save
formats, shaders, overlays, cheats and representative PSP/N64/software games
on an iPhone. Simulator and compilation results are not device gameplay proof.
