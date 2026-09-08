<div align="center">

# NeoStation iOS

#### iOS/iPadOS emulation frontend

[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE.md)
[![Platform](https://img.shields.io/badge/Platform-iOS%2018%2B-blue)](https://github.com/TarbleFR/neostation-ios)

![NeoStation iOS Preview](assets/readme/neostation-ios-preview.png)

</div>

NeoStation iOS is an iPhone and iPad port of [NeoStation](https://github.com/misobadev/neostation-frontend). It keeps the Flutter frontend while adding iOS-specific library linking, sideloading, launch flows and an embedded [DolphiniOS](https://github.com/OatmealDome/dolphin-ios) engine.

> **Modified version notice — August 2026**  
> This repository contains a modified version of NeoStation. The upstream project and its contributors retain credit for the original work. The iOS-specific port and adaptations in this repository are developed and maintained independently by [@TarbleFR](https://github.com/TarbleFR).

## Highlights

- Embedded **[DolphiniOS](https://github.com/OatmealDome/dolphin-ios)** engine for GameCube and Wii.
- **[RetroArch](https://www.retroarch.com/)** library linking/synchronization and direct launching.
- **MeloNX** library synchronization, media association and JIT-oriented launch flows.
- **ARMSX2** PS2 library synchronization, direct launching and JIT-oriented launch flows.
- **RPCS3** PS3 Data-folder library synchronization, PARAM.SFO metadata repair and JIT-assisted launch flow.
- **[StikJIT](https://github.com/StikDebug/StikJIT)** integration for supported iOS emulator workflows.
- [ScreenScraper](https://www.screenscraper.fr/) metadata/media scraping and [RetroAchievements](https://retroachievements.org/).
- Gamepad-focused landscape navigation and multi-language UI.

## Requirements

### To run

- iOS 18 or newer.
- An IPA signing/sideloading method such as [SideStore](https://sidestore.io/) or another compatible installer, or Apple Developer signing.
- RetroArch, MeloNX, ARMSX2 or RPCS3 when using the corresponding external integration.

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

The generated `ios/` Xcode scaffold is intentionally not committed. Create it when needed:

```bash
flutter create --platforms=ios --org com.neogamelab --project-name neostation .
```

Create your local build environment file from `.env.example`, provide the required ScreenScraper values and build with the project's normal iOS release process. `.env` must never be committed.

## Books and manga

NeoStation iOS allows users to import, organize and read books and manga. Users must add their own files or independently find and configure compatible sources. NeoStation iOS does not provide or host copyrighted content sources.

## Project structure

```text
assets/       bundled images, data, sounds, shaders and system resources
lib/          Flutter application source
packages/     vendored/local Flutter packages used by the workspace
test/         automated Flutter/Dart tests
build-utils/  auxiliary build/source tooling
```

## Upstream project and attribution

NeoStation iOS is based on the upstream [NeoStation repository](https://github.com/misobadev/neostation-frontend).

- Lead: [@misobadev](https://github.com/misobadev)
- Official co-maintainer: [@androosio](https://github.com/androosio)
- Official collaborator: [@ItsRetroPup](https://github.com/ItsRetroPup)

All upstream authors and contributors retain attribution for their contributions.

### iOS port

- iOS port developer / maintainer: [@TarbleFR](https://github.com/TarbleFR)
- Modified iOS version maintained since August 2026.

## Licenses and third-party components

### NeoStation iOS

NeoStation and this modified iOS port are distributed under the **GNU General Public License v3.0 (GPL-3.0)**. See [LICENSE.md](LICENSE.md) and [NOTICE.md](NOTICE.md) for the applicable license and attribution notices.

### StikJIT

NeoStation iOS integrates **[StikJIT](https://github.com/StikDebug/StikJIT)** for supported JIT workflows. StikJIT is licensed under the **Mozilla Public License 2.0 (MPL-2.0)**. See the upstream [StikJIT LICENSE](https://github.com/StikDebug/StikJIT/blob/main/LICENSE). Bundled or referenced third-party components inside StikJIT retain their own applicable licenses.

### DolphiniOS / Dolphin

The embedded GameCube/Wii engine uses code from **[DolphiniOS](https://github.com/OatmealDome/dolphin-ios)** and the Dolphin Emulator project. The DolphiniOS repository states that most original Dolphin source code is licensed under **GNU GPL v2 or later (GPLv2+)**, while individual files may use other compatible licenses identified through SPDX tags; the repository as a whole is compatible with GPLv3. See the upstream [DolphiniOS COPYING notice](https://github.com/OatmealDome/dolphin-ios/blob/master/COPYING) and [LICENSES directory](https://github.com/OatmealDome/dolphin-ios/tree/master/LICENSES).

Third-party packages, artwork, trademarks and emulator projects may have their own licenses or terms. Their copyright, attribution and license notices must be preserved where applicable.

## License

**GNU General Public License v3.0.** See [LICENSE.md](LICENSE.md).
