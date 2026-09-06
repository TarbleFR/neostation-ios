<div align="center">

# NeoStation iOS

<h4>An iPhone and iPad emulation frontend with embedded DolphiniOS and integrated StikJIT</h4>

[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE.md)
[![Stable baseline](https://img.shields.io/badge/Stable%20baseline-Build%20198-success)](https://github.com/TarbleFR/neostation-ios/releases/tag/ios-stable-198)
[![Platform](https://img.shields.io/badge/Platform-iOS%2018%2B-blue)](https://github.com/TarbleFR/neostation-ios)
[![StikJIT](https://img.shields.io/badge/StikJIT-1.5.0%20%7C%20MPL--2.0-blue)](https://github.com/StikDebug/StikJIT/tree/1.5.0)
[![DolphiniOS](https://img.shields.io/badge/Dolphin%20%2F%20DolphiniOS-GPL--2.0--or--later-blue)](https://github.com/OatmealDome/dolphin-ios/tree/7cac54161659421ed95c2cd1c0b0746539a4cd38)

![NeoStation iOS Preview](assets/readme/neostation-ios-preview.png)

</div>

NeoStation iOS is an independent iOS fork of [NeoStation](https://github.com/misobadev/neostation-frontend), maintained by [TarbleFR](https://github.com/TarbleFR). It combines the original Flutter library frontend with iPhone/iPad file handling, emulator-library synchronization, sideloading and dedicated JIT bridges.

**GameCube and Wii now run through an embedded Dolphin/DolphiniOS engine inside NeoStation.** There is no separate DolphiniOS app to install, no Dolphin deep link and no Dolphin launch Shortcut. Other systems retain their existing emulator integrations.

## Stable baseline — Build 198

[Download the original stable Build 198 and its source](https://github.com/TarbleFR/neostation-ios/releases/tag/ios-stable-198).

| Reference | Value |
|---|---|
| Original IPA source | `d23c681b84826fa694c07fa48d3a60d78282d0ef` |
| Permanent release/source tag | `ios-stable-198` |
| Original successful Actions run | `33933842637` |
| IPA SHA-256 | `0754f5967fa07370802271931c58004fa1dd782bdf577bac2db064c0d3292f5f` |
| Status | Maintainer-confirmed working baseline; automated compilation and structural audit passed |

The release preserves the original IPA **without rebuilding or modifying it**, together with its source archive, signing entitlements and build evidence. Deleting historical Actions runs does not delete these release assets.

`main` and `backup` are based on this stable source. Subsequent documentation and CI cleanup do not change the application code from Build 198. Later experimental touch/settings changes are not silently included in this baseline. The original IPA's corresponding source remains the exact commit and tag above, not a later maintenance commit.

The IPA is unsigned and requires compatible sideload signing. A working result reported on one device is not a guarantee for every device or game; automated CI does not claim to have tested physical hardware.

## Embedded GameCube and Wii

Open NeoStation, choose **GameCube** or **Wii**, import your games from the playlist, and launch them without leaving the frontend for a separate DolphiniOS installation.

- Native GameCube/Wii playlists and multiple-file import.
- User-supplied GameCube IPL imports for USA, EUR and JAP, validated before installation. No games, IPL or console firmware are supplied.
- No fictitious Wii BIOS/IPL requirement; only real Dolphin system data is handled when needed.
- Internal Dolphin configuration, saves, shader cache and persistent diagnostics.
- Original DolphiniOS touch-controller resources adapted to NeoStation, physical-controller support and an in-game settings menu.
- Dolphin's JITARM64 CPU backend and Metal rendering, with startup checks and a clean refusal when the required initialization fails.

The Dolphin launch path is isolated to GameCube and Wii. Its JIT policy, storage and session state do not replace the general launcher or the existing external-emulator paths.

## StikJIT integration

NeoStation embeds the **StikJIT framework 1.5.0**. For Dolphin, a bundled helper extension runs separately from the host process and targets **NeoStation's PID**, because that is where the embedded Dolphin engine runs.

```text
NeoStation library
  → bundled helper / StikJIT 1.5.0 (Dolphin legacy script)
  → NeoStation PID and executable-memory validation
  → embedded Dolphin JITARM64
  → Metal
  → GameCube / Wii game
```

The helper is part of the same IPA; a separate process does not mean a second emulator application. StikJIT enables the necessary execution conditions and does not replace Dolphin's own recompilation engine.

Dolphin uses its isolated `legacy` path and has no interpreter fallback. Other existing integrations retain their own script and JIT behavior. A status such as "attached" alone is not treated as proof that Dolphin can start.

A valid device Pairing File, suitable signing entitlements and a working LocalDevVPN/RSD setup are still required for the integrated JIT path. NeoStation does not provide Pairing Files or bypass these prerequisites. See [StikJIT's integration guide](https://github.com/StikDebug/StikJIT/blob/1.5.0/INTEGRATION.md).

### Existing emulator integrations

The stable source preserves the existing RetroArch, MeloNX, ARMSX2 and RPCS3 iOS paths, including their library synchronization, direct-launch mechanisms and applicable JIT bridges. Dolphin does not claim other systems or remove their URL schemes, imports, playlists or storage settings.

The existing **Settings → Tools** Pairing File management and optional StikDebug fallback for supported external paths remain separate from the mandatory Dolphin legacy path. Embedding Dolphin does not mean that every other emulator is also embedded.

## Other frontend features

NeoStation retains ScreenScraper media and metadata, RetroAchievements support, opt-in personal iCloud Drive save folders, iOS external-folder handling, gamepad-oriented landscape navigation, custom backgrounds and menu music. Existing language support and third-party integrations remain in the source tree.

The upstream project supports other platforms. This repository is maintained primarily as the iOS fork; use upstream for canonical non-iOS documentation.

## Requirements

- iPhone or iPad running iOS/iPadOS 18 or newer for this documented fork baseline.
- A compatible IPA signing/sideloading method. Retain the necessary entitlements when signing; the original release includes its signing-entitlements file.
- Your own game files and any legally obtained system files needed by the selected game/engine.
- Pairing File and LocalDevVPN/RSD preparation for integrated JIT.
- Separate emulator apps for systems that still use external integrations, such as RetroArch, MeloNX, ARMSX2 or RPCS3. **A separate DolphiniOS app is not needed for GameCube/Wii.**

## Build and CI

There is one maintained build workflow: **Actions → Build NeoStation iOS IPA → Run workflow**. It is manual-only so documentation changes and archived test branches do not automatically start expensive builds.

The pipeline retains the successful Build 198 build stages: locked dependencies, emulator-isolation checks, Flutter analysis/tests, pinned Dolphin build, original touch resources, iOS Simulator UI checks, Xcode compilation and an audit of the actual IPA/Mach-O linkage. It requires the existing ScreenScraper developer secrets. It does not print their values.

The manual build number defaults to **199**, the next build after the preserved stable 198. A new build is a candidate until tested; it does not replace the stable release automatically.

Toolchain used by the preserved build: **Xcode 16.4**, **Flutter 3.47.2 / Dart 3.13.2**, Dolphin revision `7cac54161659421ed95c2cd1c0b0746539a4cd38`, and StikJIT **1.5.0**. The workflow restores and verifies the native dependencies. Keep the lockfile, build scripts, helper extension and generated-project configuration together; a bare Flutter build is not a substitute for the native pipeline.

For the original source:

```bash
git clone https://github.com/TarbleFR/neostation-ios.git
cd neostation-ios
git checkout ios-stable-198
```

Use the workflow at that revision as the exact record of how the preserved binary was built. The generated `ios/` scaffold and build products are not the source of truth and are intentionally not committed. Never commit developer secrets or Pairing Files.

## Diagnostics

Dolphin keeps engine-specific persistent diagnostics for JIT preparation, executable-memory checks, core/Metal initialization, game loading and session termination. External StikJIT integrations retain their own diagnostics, including `stikjit_melonx_debug.txt`, `stikjit_armsx2_debug.txt` and `stikjit_rpcs3_debug.txt`.

The stable release includes the original build report and diagnostics archive. These distinguish build/structural checks from physical-device testing and remain available independently of Actions retention.

## Credits and licenses

### NeoStation and the iOS fork — GPL-3.0

Original project: [misobadev/neostation-frontend](https://github.com/misobadev/neostation-frontend). Credit remains with Miguel Soto / misobadev and the upstream contributors, including androosio and ItsRetroPup, as recorded in the original repository. iOS-specific adaptations are maintained independently by TarbleFR since August 2026. No upstream endorsement is implied.

See [LICENSE.md](LICENSE.md), [NOTICE.md](NOTICE.md) and the repository history. Maintenance of this fork does not replace the authorship or license of upstream components.

### Dolphin / DolphiniOS — GPL-2.0-or-later for most original code

Thanks to the **Dolphin Emulator and DolphiniOS contributors** for the emulation engine, iOS port, input profiles, touchscreen controls and resources used by this integration.

Source: [OatmealDome/dolphin-ios at the pinned revision](https://github.com/OatmealDome/dolphin-ios/tree/7cac54161659421ed95c2cd1c0b0746539a4cd38). Preserve upstream [COPYING](https://github.com/OatmealDome/dolphin-ios/blob/7cac54161659421ed95c2cd1c0b0746539a4cd38/COPYING), `LICENSES/` and individual file notices; bundled dependencies may have different licenses. NeoStation-specific engine patches are in `build-utils/patch_dolphin_internal_core_v2.py` and the host integration is in `packages/dolphin_internal_bridge/`.

### StikJIT framework 1.5.0 — MPL-2.0

Thanks to **StikDebug and the StikJIT contributors**. Source: [StikDebug/StikJIT 1.5.0](https://github.com/StikDebug/StikJIT/tree/1.5.0); license: [Mozilla Public License 2.0](https://github.com/StikDebug/StikJIT/blob/1.5.0/LICENSE).

This credit refers to the embedded **framework**, not the separate StikDebug application. StikJIT's bundled `idevice`, `universal.js` and `legacy.js` retain their own licenses. The framework compatibility adjustments and Dolphin helper are documented in [NOTICE.md](NOTICE.md). The separate StikDebug application's AGPL-3.0 license is not substituted for the framework's MPL-2.0 license.

### Redistribution

Preserve applicable copyright, license and third-party notices and provide recipients access to the corresponding source and build/integration scripts for the actual binary being distributed. Trademarks and logos remain the property of their respective owners. NeoStation iOS is not affiliated with Nintendo or the referenced emulator projects. No copyrighted games, BIOS/IPL, firmware or device Pairing Files are distributed with this project.

## Support and contributing

[GitHub Issues](https://github.com/TarbleFR/neostation-ios/issues) · [TarbleFR on Patreon](https://www.patreon.com/cw/TarbleFR) · [Reddit](https://www.reddit.com/user/Mysterious_Air2053/)

See [ARCHITECTURE.md](ARCHITECTURE.md), [THEMES.md](THEMES.md), [CONTRIBUTING.md](CONTRIBUTING.md) and [SECURITY.md](SECURITY.md) for the existing project guidance.

## Personal iCloud Saves (candidate 208)

Cloud save storage now uses a user-authorized **iCloud Drive / NeoStation / Saves**
folder. Activate iCloud Saves once and authorize its folder in Files. A signed-in
Apple Account and enabled iCloud Drive are required. No application cloud account,
subscription or backend token is used. Native emulator save locations remain local.

Changed saves from linked emulators are snapshotted at startup and after returning
from a game. Immutable revisions keep console/emulator/native identity separate.
Restoration is explicit, checksummed and preserves the previous local save. A copy
in the folder is shown as pending until Apple confirms its upload metadata.

DolphiniOS, ARMSX2, MeloNX, RPCS3 and RetroArch have dedicated adapters. Additional
emulators can use explicitly linked save folders; installing an unrelated app
alone does not grant access to its private storage. See [iCloud Saves architecture
and validation](docs/ICLOUD_SAVES.md). Real Apple-account/device testing is required
before describing this candidate as stable.
