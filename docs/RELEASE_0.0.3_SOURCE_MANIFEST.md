# NeoStation iOS 0.0.3 — source and binary provenance

## Original executable source and delivery

- Original source: `6bfc9ddcb8fbf2be2c21c8c1c68ab2026cf81cb4`
- Repository: https://github.com/TarbleFR/neostation-ios
- Build: 427; original bundle version: 0.0.2.
- Successful CI run: https://github.com/TarbleFR/neostation-ios/actions/runs/37947994686
- Artifact ID: 11625391348; decrypted IPA size: 205515753 bytes.
- Original IPA SHA-256: `acb17ed250b7149d9b38ee91d2eaf70c33d81fc82b006cf78b3ce497a2ea4ab9`.

## Release packaging

The release packaging commit adds legal notices and release documentation,
sets the marketing version to 0.0.3 and retains internal build 427. It does
not compile or replace the host or emulator code. Modified app/extension
bundles are re-sealed with ad hoc signatures; installation still requires
Apple re-signing/provisioning by the user's sideloading tool.

`Release-0.0.3-identity.json` in the IPA records the packaging commit.
`BUILD_SOURCE_IDENTITY.json` and native donor identities retain the original
source attribution. `release-validation.json` records the before/after
comparison, executable-section hashes and signature checks.

## Embedded cores

The IPA preserves `Libretro-native-identity.json`: 14 official buildbot cores,
retrieved 2026-10-09, with archive hashes, pre-signing binary hashes and URLs.
It does **not** attest the exact source commit for each compiled core.
`assets/legal/libretro/license-sources.json` records license-reference
snapshots only, not binary-matching source revisions. The source archives
provided here cover the NeoStation host and packaging changes, not a complete
Corresponding Source archive for all embedded third-party binaries.

See `assets/legal/libretro/LIBRETRO_CORES.md` for the core authors, licenses,
non-commercial restrictions (including FBNeo's donation condition) and source
limitations. Existing KartPad/RPCS3 boundaries in LEGAL_AND_CREDITS.md remain.

## NeoPlay Windows

- Version: 0.8.0.
- Source: `15c72a94c1295ae73dc6c25251469683a16c65e5`, `tools/neoplay-receiver/`.
- Successful CI: https://github.com/TarbleFR/neostation-ios/actions/runs/37750706176
- Installer: 115272144 bytes.
- SHA-256: `4f611f9103cacbe8f3625b8f9e08814bc74425a992735b02d4936b062ca22960`.
- Existing CI unit tests and Electron smoke test are retained as prior evidence.
  No new live iPhone-to-Windows playback test is claimed by this packaging.
