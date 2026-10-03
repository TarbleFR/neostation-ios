# RetroArch integration — stage 1

Work is isolated on `feature/retroarch-embedded`, starting from NeoStation
`3be1b3a528345f25870fde25913bc7f4713d2255`. This stage does not merge into
`experimental` or alter NeoSwap inputs, native cores or workflow pins.

## Exact inputs

- Requested IPA: `2026-10-03_RetroArch.ipa`, 611,752,729 bytes.
- IPA SHA-256: `5803425e6b38dce7a34b1fa125f91879b1e3a5102111f5ac15de19835a330c42`.
- RetroArch source: `3a6a1e9c4fb4e90044945f84138ae7fad687e1a4`, extracted from
  the actual IPA frontend's Git version and resolved to its full upstream SHA.
- The standalone application executable is excluded. The hosted frontend is
  built from these sources and exposes only the versioned NeoStation ABI.
- Eleven pinned core frameworks are **smoke-test inputs for this stage**, not
  the final user catalogue. The complete compatible App Store subset, including
  alternate cores per console, is being inventoried separately. PSP requires a
  supplementary pinned core because the supplied IPA has its metadata but no
  PPSSPP core binary.

## Native boundary

The host owns UIApplication, the session controller, native menu, transactions,
Documents directories and frontend media barrier. RetroArch runs between UIKit
frames and returns to the host without calling the standalone application exit.
Availability loads and validates the ABI; it does not initialize a game or
allocate a render view. A successful launch requires a submitted game frame.
Stopping retains ownership until backend acknowledgement and view dismissal.

`Documents/RetroArch` holds `system`, `games`, `saves`, `states`, `config`,
`shaders`, `overlays`, `cheats` and `logs`. Executable cores remain packaged and
signed in the application; user-writable folders do not install executable code.
The initial frontend supports the OpenGL ES render path and GLSL shader presets.
The supplied IPA has no shader pack. Core updating and JIT are disabled in this
frontend; additional hardware cores require compatible rendering and explicit
non-JIT configuration before being offered.

## Verification

Local checks passed for the exact IPA hash and all eleven core binary hashes,
curation/source tool tests, shared ABI validation and controller-menu chord
consumption. `retroarch-embedded-stage1.yml` adds actual Apple SDK compilation of
the production bridge, an isolated UIKit lifecycle probe with a controllable
test backend, and compilation/linking of the real hosted RetroArch frontend.

The controlled backend verifies host state transitions and does not stand in
for RetroArch gameplay. Apple CI compilation and physical iPhone gameplay are
not yet claimed at this checkpoint. A complete corresponding-source archive
accompanies the GPL frontend artifact.

## Subsequent stages

1. Expand and pin the reviewed catalogue and PSP supplementary input.
2. Attach the native runtime to the Flutter launch path and first-run console
   picker, including per-console core selection and later changes.
3. Connect imports, the uniform game menu and optional external-to-embedded
   migration. The migration uses only the application's selected locale and
   copies user-selected files without deleting the originals.
4. Run full host checks and device validation before proposing integration
   into `experimental`.
