<div align="center">

# NeoStation iOS

#### Emulation frontend for iPhone and iPad

[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE.md)
[![Platform](https://img.shields.io/badge/Platform-iOS%2018%2B-blue)](https://github.com/TarbleFR/neostation-ios)

![NeoStation iOS Preview](assets/readme/neostation-ios-preview.png)

</div>

**NeoStation iOS** is an independently maintained iOS/iPadOS fork of
[NeoStation](https://github.com/misobadev/neostation-frontend). It keeps the
Flutter library/frontend experience while adding iPhone- and iPad-specific
native cores, JIT workflows, sideloading support, external-emulator library
bridges and mobile-friendly game/session management.

The current iOS fork can work with embedded **Dolphin/DolphiniOS, ARMSX2,
RPCS3, Dusklight and KartPad** runtimes and embedded **Libretro cores**, alongside
external **RetroArch** and **MeloNX** integrations. Metadata and account-facing features use services and
datasets such as **ScreenScraper, RetroAchievements and GameDB-PS3**.

> **Modified version notice — August 2026 onward**  
> This repository contains a modified version of NeoStation. The upstream
> project and its contributors retain credit for the original frontend and
> shared project history. The iOS-specific port, bridges, packaging, native
> runtime adaptations and experimental integrations in this repository are
> developed and maintained independently by [@TarbleFR](https://github.com/TarbleFR).
> Attribution does not imply endorsement by any upstream project.

NeoStation iOS does **not** provide games, console firmware, encryption keys,
BIOS files, copyrighted game assets or paid content. Users are responsible for
providing legally obtained content required by the software they choose to use.

## Current iOS scope

### Embedded runtimes

- **Libretro cores** — the emulation cores also used by RetroArch run supported
  systems directly in NeoStation. Their on-screen controls support per-console
  default skins and optional imports from the Provenance skin catalog.
- **[DolphiniOS / Dolphin](https://github.com/OatmealDome/dolphin-ios)** —
  embedded GameCube/Wii engine with NeoStation session, touch, menu,
  RetroAchievements and JIT integration.
- **[ARMSX2](https://github.com/ARMSX2/ARMSX2)** — embedded PS2 core based on
  the ARMSX2 ARM64 JIT fork of PCSX2.
- **RPCS3 iOS** — embedded PS3 core materialized from the pinned
  [XITRIX RPCS3 iOS](https://github.com/XITRIX/RPCS3-iOS-Releases) release,
  with NeoStation-specific lifecycle, JIT, diagnostics, save-state and library
  integration.
- **[Dusklight](https://github.com/TwilitRealm/dusklight)** — embedded
  Twilight Princess reimplementation integration with NeoStation-owned
  lifecycle and game-library handling.
- **[KartPad](https://github.com/chrissotraidis/kartpad)** — embedded Mario
  Kart Wii runtime integration built around KartPad/WiiCompiled, with
  NeoStation-owned library, settings and lifecycle handling.

### External app integrations

- **[RetroArch](https://github.com/libretro/RetroArch)** — shared-library
  linking, playlist/library synchronization and direct launch flows.
- **[MeloNX](https://github.com/nurtrino/MeloNX)** — Nintendo Switch library
  synchronization, media association, direct launch and JIT-oriented handoff.

### JIT, metadata and account services

- **[StikJIT](https://github.com/StikDebug/StikJIT)** for supported iOS JIT
  workflows.
- A read-only JIT route check compatible with a separately installed and
  user-controlled **LocalDevVPN**. NeoStation does not bundle LocalDevVPN.
- **[ScreenScraper](https://www.screenscraper.fr/)** for game metadata/media.
- **[RetroAchievements](https://retroachievements.org/)** for supported
  achievement/account flows.
- **[GameDB-PS3](https://github.com/niemasd/GameDB-PS3)** as a cached fallback
  PS3 serial-to-title catalog when local metadata and ScreenScraper do not
  provide a usable title.
- Gamepad-focused landscape navigation and 12-locale coverage for iOS-specific
  settings and menus.

## Controller skins

The skin catalog is provided by **[Provenance](https://github.com/Provenance-Emu/skins)**.
It is used for NeoStation's **embedded Libretro consoles**. Each console has a
NeoStation default skin; community skins are downloaded only when you choose
to install them.

1. Open **Settings → Folders → Embedded consoles**, choose a console, then **Skins**.
2. Select **Browse the Provenance catalog**, or **Import from Files** for a
   compatible `.deltaskin`, `.manicskin` or single-skin `.zip` archive.
3. Choose **Use in portrait**, **Use in landscape** or **Use in both orientations**.

The default skin remains available. When an imported skin lacks a layout for
one orientation, NeoStation uses its default for that orientation. Compatibility
depends on the console, device layout and functions used by each skin.

See the **[skin guide](docs/SKINS.md)** for import instructions, in-game settings,
supported behavior, catalog sources and creator credits.

## Requirements

### To run

- iOS 18 or newer.
- An IPA signing/sideloading method such as
  [SideStore](https://sidestore.io/) or another compatible installer, or Apple
  Developer signing.
- A valid pairing/JIT setup when using a workflow that requires JIT.
- LocalDevVPN only when the user deliberately chooses that external route.
- RetroArch or MeloNX only when using those external integrations.

The embedded Dolphin, ARMSX2, RPCS3, Dusklight and KartPad integrations do not
require installing a second copy of those applications.

When upgrading from an older NeoStation build that included its own JIT tunnel,
remove the old **NeoStation Local JIT Tunnel** profile in iOS Settings and
reactivate or recreate LocalDevVPN if you still use it. The current project does
not embed the retired internal VPN tunnel.

### To build locally

- macOS with a compatible Xcode installation.
- Flutter SDK compatible with the version pinned by the project.
- ScreenScraper developer credentials when building with ScreenScraper enabled.

## Build from source

```bash
git clone https://github.com/TarbleFR/neostation-ios.git
cd neostation-ios
flutter pub get
```

The generated `ios/` Xcode scaffold is intentionally not committed. Create it
when needed:

```bash
flutter create --platforms=ios --org com.neogamelab --project-name neostation .
```

Create your local build environment file from `.env.example`, provide the
required ScreenScraper values and build with the project's normal iOS release
process. `.env` must never be committed.

## Stable iOS baseline

The currently documented stable iOS reference is **Build 350**:

- Packaging source: `5e6dc00b35b7bb7847c24198d9f4b08ade8ed9a0`
- Successful workflow run:
  [36323843067](https://github.com/TarbleFR/neostation-ios/actions/runs/36323843067)
- Artifact: `NeoStation-iOS-Build-350-KartPad-Relaunch-Candidate`
- IPA SHA-256:
  `e1017b96842ec970be3ed0cd981083ee945d069cf76e689a4ca3c81339299b46`

Build 350 remains the restoration point until a later experimental build is
explicitly device-validated and promoted. A successful Actions run by itself
does not make a build the new stable baseline.

## Books and manga

NeoStation iOS also allows users to import, organize and read books and manga.
Users must add their own files or independently configure compatible sources.
NeoStation iOS does not provide or host copyrighted content sources.

## Project structure

```text
assets/       bundled images, data, sounds, shaders and system resources
lib/          Flutter application source
native/       native iOS runtime/core integration code
packages/     vendored/local Flutter and native bridge packages
test/         automated Dart/Flutter/native contract tests
build-utils/  reproducible source-materialization and build tooling
docs/         integration, diagnostics and build notes
```

## Credits and upstream projects

NeoStation iOS exists because of the work of many upstream projects. Please
credit those projects when redistributing modified builds or extracted
components, and preserve their license/notices.

| Project | NeoStation iOS use / attribution |
| --- | --- |
| **NeoStation** | Original frontend/project by [@misobadev](https://github.com/misobadev), with upstream co-maintainer [@androosio](https://github.com/androosio), collaborator [@ItsRetroPup](https://github.com/ItsRetroPup), and all upstream contributors. |
| **NeoStation iOS** | iOS fork, native integrations and maintenance by [@TarbleFR](https://github.com/TarbleFR). |
| **Dolphin / DolphiniOS** | Dolphin Emulator contributors and [DolphiniOS](https://github.com/OatmealDome/dolphin-ios) / OatmealDome contributors. |
| **RPCS3 iOS / RPCS3** | iOS release/core work by [XITRIX](https://github.com/XITRIX/RPCS3-iOS-Releases), based on the [RPCS3](https://github.com/RPCS3/rpcs3) project. XITRIX also credits ARMSX3 and the wider iOS emulation/JIT community. |
| **ARMSX2 / PCSX2** | [ARMSX2](https://github.com/ARMSX2/ARMSX2) team and contributors; ARMSX2 is based on the long-running [PCSX2](https://github.com/PCSX2/pcsx2) project. |
| **Dusklight** | [TwilitRealm/Dusklight](https://github.com/TwilitRealm/dusklight) contributors; upstream also credits the Twilight Princess decompilation community and Aurora developers. |
| **KartPad / WiiCompiled** | [KartPad](https://github.com/chrissotraidis/kartpad) by [@chrissotraidis](https://github.com/chrissotraidis), built on [WiiCompiled](https://github.com/patchzyy/Wiicompiled) created by [@patchzyy](https://github.com/patchzyy). |
| **MeloNX / Ryujinx** | [MeloNX](https://github.com/nurtrino/MeloNX) contributors; MeloNX describes itself as based on Ryujinx/Ryubing. |
| **RetroArch / libretro** | [RetroArch](https://github.com/libretro/RetroArch) and libretro contributors. |
| **Provenance Skin Catalog** | [Provenance-Emu/skins](https://github.com/Provenance-Emu/skins) maintainers and contributors; external catalog used to discover community controller skins. |
| **Delta / DeltaCore** | [Riley Testut and DeltaCore contributors](https://github.com/rileytestut/DeltaCore); reference controller-skin format for compatible imports. |
| **Community skin creators** | Each skin's original author and download source are retained when available. Artwork remains subject to its creator's terms. |
| **StikJIT** | [StikDebug/StikJIT](https://github.com/StikDebug/StikJIT) and its contributors. |
| **ScreenScraper** | [ScreenScraper.fr](https://www.screenscraper.fr/) metadata and media service. |
| **RetroAchievements** | [RetroAchievements](https://retroachievements.org/) project, API and community. |
| **GameDB / GameDB-PS3** | **Niema / [@niemasd](https://github.com/niemasd)**, creator of [GameDB](https://github.com/niemasd/GameDB) and [GameDB-PS3](https://github.com/niemasd/GameDB-PS3). NeoStation uses `PS3.titles.json` as a fallback title catalog. GameDB asks downstream projects to credit GameDB and its source datasets; GameDB-PS3 lists **MiSTer Addons** and **Redump** as sources. |
| **NeoStation Assets** | Optional runtime-downloaded System Art from [misobadev/neostation-assets](https://github.com/misobadev/neostation-assets). Original creative assets are CC BY-NC-SA 4.0; trademarks remain with their owners. |
| **RiiSU / iiSU** | [RiiSU](https://github.com/mult1v4c/RiiSU) credits [iiSU Interpreted for ES-DE](https://github.com/VictorUnlocked/iisu-interpreted-es-de) for system art icons and [iiSU Network](https://iisu.network/) for the original inspiration. RiiSU remains remotely hosted and is downloaded only when selected. |

For lower-level dependencies, pinned revisions and additional license details,
see [NOTICE.md](NOTICE.md), [the complete legal/credits record](docs/LEGAL_AND_CREDITS.md),
package-specific license files and the upstream repositories.

For the first public GitHub release, the exact Build 350 binary/source identity
is recorded in
[RELEASE_0.0.1_SOURCE_MANIFEST.md](docs/RELEASE_0.0.1_SOURCE_MANIFEST.md).

## GameDB attribution

NeoStation iOS specifically thanks **Niema (@niemasd)** for creating GameDB and
making structured game metadata available for downstream tools.

The PS3 integration may download the GPL-3.0
[`PS3.titles.json`](https://github.com/niemasd/GameDB-PS3/releases/latest/download/PS3.titles.json)
mapping from GameDB-PS3 and cache it locally. In accordance with GameDB's
attribution request, NeoStation also acknowledges the sources named by
GameDB-PS3:

- [MiSTer Addons](https://misteraddons.com/)
- [Redump](http://redump.org/)

NeoStation does not claim authorship of that dataset.

## Licenses and third-party notices

### NeoStation iOS

NeoStation iOS is a modified version of the upstream NeoStation frontend. The
upstream project is GPL-3.0-or-later and its authorship remains preserved.
NeoStation's iOS-specific code and distribution notices do not relicense
third-party components. See [LICENSE.md](LICENSE.md), [NOTICE.md](NOTICE.md) and
[the complete legal/credits record](docs/LEGAL_AND_CREDITS.md).

### StikJIT

NeoStation iOS integrates
**[StikJIT](https://github.com/StikDebug/StikJIT)** for supported JIT
workflows. StikJIT is licensed under **Mozilla Public License 2.0 (MPL-2.0)**.
Bundled or referenced third-party components inside StikJIT retain their own
licenses. Executable redistribution must preserve the MPL notices and inform
recipients how to obtain the covered source.

### DolphiniOS / Dolphin

The embedded GameCube/Wii engine uses code from
**[DolphiniOS](https://github.com/OatmealDome/dolphin-ios)** and Dolphin
Emulator. The pinned DolphiniOS source states that most original Dolphin source
is licensed under **GPL-2.0-or-later** and that the repository aggregate is
GPLv3-compatible. Individual file/component SPDX notices and upstream
`LICENSES/` remain authoritative.

### RPCS3 / XITRIX

The embedded PS3 core is materialized from the exact XITRIX/rpcs3 revision
recorded in `build-utils/rpcs3/canonical-source.json`. That source carries
RPCS3's GNU GPL version 2 license; its README states that most files are
**GPL-2.0-only**, with some files licensed differently. NeoStation does not
claim to relicense RPCS3. Exact per-file notices and third-party terms must be
preserved.

### ARMSX2 / PCSX2

The embedded PS2 core is based on **ARMSX2**, which distributes GPLv3 material
and in turn builds on PCSX2. Preserve ARMSX2/PCSX2 attribution, copyright
history and component-specific notices.

### KartPad / WiiCompiled

KartPad's own `RIGHTS_AND_LICENSES.md` states that KartPad-owned software and
its WiiCompiled modifications are **GPL-3.0-only** where covered. The same
document separately notes that the software license does not grant rights in
Nintendo-owned game content or automatically clear rights in ahead-of-time
translated game logic.

NeoStation's pinned KartPad manifest also records that generated
translation/profile inputs required for a full KartPadCore are excluded from
the public source delivery. Do not describe the available public source as
complete Corresponding Source for that translated runtime unless the exact
required source for the distributed binary is actually available.

### Dusklight

Dusklight's root project is published under **CC0-1.0**. Aurora, Borealis, SDL
and other embedded dependencies retain their own licenses and notices.

### GameDB-PS3

The GameDB-PS3 repository is distributed under **GPL-3.0**. NeoStation downloads
its title mapping at runtime rather than claiming it as original NeoStation
data. Preserve GameDB and source-dataset attribution when redistributing a
cached or bundled copy.

### NeoStation Assets / RiiSU System Art

Optional System Art from **NeoStation Assets** is downloaded at runtime.
NeoStation Assets states that its original creative backgrounds and custom icons
are licensed under **CC BY-NC-SA 4.0**. Attribution, NonCommercial and
ShareAlike conditions apply to that creative material; console trademarks
remain with their owners.

**RiiSU** remains hosted by its original project and is downloaded/cached only
when selected. RiiSU credits iiSU Interpreted for ES-DE for its system art icons
and iiSU Network for the original inspiration. No standalone RiiSU license file
was visible when the integration was added, so NeoStation does not assert
general redistribution rights over that artwork.

### Future binary packaging

Future NeoStation iOS builds are required by CI to include a `Legal/` directory
inside the application bundle with the NeoStation license/notice, third-party
credits, exact build/source identity and pinned license texts for the principal
embedded components. The build fails when those legal files are missing or
stale relative to the source pins.

This policy does **not** modify the already-published `NeoStation.ipa` asset in
GitHub release 0.0.1.

All other third-party packages, artwork, trademarks and emulator projects retain
their own copyrights, licenses and terms. See [NOTICE.md](NOTICE.md) and
[docs/LEGAL_AND_CREDITS.md](docs/LEGAL_AND_CREDITS.md) for the expanded
attribution record.

## Trademark notice

Nintendo, PlayStation, Xbox, SEGA, RetroArch, Dolphin, DolphiniOS, RPCS3,
ARMSX2, MeloNX, Dusklight, KartPad, StikJIT and other referenced names/logos are
the property of their respective owners where applicable. NeoStation iOS is an
independent project and is not affiliated with or endorsed by those trademark
holders unless explicitly stated otherwise.

## License

**GNU General Public License v3.0.** See [LICENSE.md](LICENSE.md).
