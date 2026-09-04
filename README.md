<div align="center">

# NeoStation iOS

<h4>iOS 18+ fork of the NeoStation Flutter emulation frontend</h4>

[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE.md)
[![Stars](https://img.shields.io/github/stars/TarbleFR/neostation-ios?logo=github)](https://github.com/TarbleFR/neostation-ios/stargazers)
[![Issues](https://img.shields.io/github/issues/TarbleFR/neostation-ios)](https://github.com/TarbleFR/neostation-ios/issues)
[![Platform](https://img.shields.io/badge/Platform-iOS%2018%2B-blue)](https://github.com/TarbleFR/neostation-ios)
[![JIT](https://img.shields.io/badge/JIT-StikJIT%20%2B%20StikDebug-success)](https://github.com/TarbleFR/neostation-ios)

![NeoStation iOS Preview](assets/readme/neostation-ios-preview.png)

</div>

NeoStation iOS is an **iOS 18+ fork** of the upstream [NeoStation](https://github.com/misobadev/neostation-frontend) project. It keeps the original Flutter frontend while adding iPhone and iPad file handling, emulator-library synchronization, sideloading support, direct-launch integrations and dedicated iOS JIT workflows.

> **Modified version notice — August 2026**  
> This repository contains a modified version of NeoStation. The upstream project and its contributors retain credit for the original work. The iOS-specific fork and adaptations in this repository are developed and maintained by [@TarbleFR](https://github.com/TarbleFR). This does not imply endorsement by the upstream NeoStation maintainers. The covered modified work is distributed under the GNU General Public License v3.0.

## Current validated baseline

The current device-tested baseline is **Build 167**, source commit:

`0ce1e501bf5faf4295510b49c64b04d777132d38`

A permanent recovery branch points to the same source revision:

`backup/stikjit-all-emulators-working-build-167`

This baseline includes the permanent Pairing File configuration, integrated StikJIT support for MeloNX, ARMSX2 and RPCS3, plus the global StikDebug emergency fallback.

## Main features

### Pairing File management

- NeoStation asks for a Pairing File during first-time setup.
- Import can be skipped and completed later from **Settings → Tools**.
- The stored file can be replaced without reinstalling NeoStation.
- The Pairing File is reused by every integrated StikJIT emulator path.
- NeoStation does not ship or distribute Pairing Files; users must provide the file created for their own device.

### Integrated JIT routing

NeoStation can prepare StikJIT internally and target the exact emulator process instead of opening StikDebug for every launch.

| Emulator | Integrated StikJIT behaviour | Current game handoff |
|---|---|---|
| **MeloNX** | Launches MeloNX suspended, enables JIT on its PID and completes the frontend handoff | Direct game launch from the synced MeloNX library |
| **ARMSX2** | Launches ARMSX2 suspended, enables JIT on its PID and sends the exported ARMSX2 launch URL | Direct PS2 game launch |
| **RPCS3 iOS** | Launches RPCS3 suspended and enables JIT on its PID | RPCS3 currently continues to its native **Start / Commencer** and game-selection screen |

Installed bundle identifiers are discovered through the device rather than relying only on hard-coded identifiers, which helps with sideloaders that rewrite bundle IDs.

### Global StikDebug emergency fallback

A single switch is available in **Settings → Tools**, directly below the Pairing File entry.

- **Disabled — Integrated StikJIT:** MeloNX, ARMSX2 and RPCS3 use their built-in NeoStation StikJIT paths.
- **Enabled — StikDebug fallback:** all compatible emulators bypass the integrated bridges and return to their existing StikDebug launch method.

The choice is persistent and is evaluated before an emulator is launched, so StikJIT and StikDebug are never started together. MeloNX and ARMSX2 use their existing Apple Shortcuts in fallback mode; RPCS3 uses its existing direct StikDebug Universal JIT request.

### Emulator libraries and launch integration

- **RetroArch:** folder linking, library synchronization, playlist import and direct game launching through deeplinks. Folder linking and library synchronization remain separate because the linked root is also used for configuration, saves, states and NeoSync path resolution.
- **MeloNX:** library synchronization, media association, direct game launching and integrated JIT.
- **ARMSX2:** library synchronization, virtual PS2 library rows, direct game launching and integrated JIT.
- **RPCS3 iOS:** `Data`-folder synchronization, `PARAM.SFO` parsing, title repair, Title-ID metadata lookup, integrated JIT and StikDebug fallback.
- Installed-emulator detection in NeoStation settings.

### Additional NeoStation iOS features

- iOS-specific document, media and security-scoped external-folder handling.
- First-install RetroArch synchronization and immediate library refresh.
- ScreenScraper metadata and media scraping.
- RetroAchievements support.
- NeoSync account and cloud-save features inherited from NeoStation, including iOS paths for supported emulator saves.
- Custom main-menu backgrounds using PNG, JPG/JPEG, WebP, GIF, MP4, M4V or MOV files.
- Optional main-menu music using MP3, WAV, OGG or FLAC files.
- Gamepad-focused landscape navigation.
- SideStore and compatible sideloading support.
- Pairing File and JIT fallback interface translated into the 12 NeoStation languages: English, French, German, Spanish, Italian, Portuguese, Indonesian, Russian, Japanese, Korean, Simplified Chinese and Traditional Chinese.

The upstream NeoStation project supports additional platforms. This repository is maintained primarily as the **iOS fork**; use the upstream repository for canonical non-iOS documentation and releases.

## Requirements

### To run

- iOS 18 or newer.
- An IPA signing/sideloading method such as SideStore, Feather, another compatible installer or Apple Developer signing.
- The emulator applications required by the systems you use: RetroArch, MeloNX, ARMSX2 and/or RPCS3 iOS.
- A valid Pairing File for the current device when using integrated StikJIT.
- A working LocalDevVPN/RSD setup for the integrated StikJIT path.
- StikDebug and the corresponding launch Shortcuts when using emergency fallback mode for MeloNX or ARMSX2.

### To build locally

- macOS with a compatible Xcode installation.
- Flutter SDK **3.9.2 or newer**.
- ScreenScraper developer credentials when ScreenScraper is enabled.
- `StikJIT.xcframework` 1.5.0 restored under `packages/stikjit_bridge/ios/Frameworks/`. The GitHub Actions workflow downloads and validates this framework automatically; it is not committed to the repository.

## GitHub Actions build

The repository keeps one manual workflow:

**Actions → Build NeoStation iOS IPA → Run workflow**

The workflow builds `main`, restores the validated StikJIT framework, verifies the isolated MeloNX/ARMSX2/RPCS3 paths and the global fallback preference, generates a clean iOS scaffold, compiles an unsigned release and uploads the IPA as a workflow artifact.

The workflow requests a build number when started manually. The default remains aligned with the validated Build 167 baseline and can be incremented for later releases.

## Build from source

Clone this iOS fork and resolve the Flutter workspace:

```bash
git clone https://github.com/TarbleFR/neostation-ios.git
cd neostation-ios
flutter pub get
```

The generated `ios/` Xcode scaffold is intentionally not committed. Create it when needed:

```bash
flutter create --platforms=ios --org com.neogamelab --project-name neostation .
```

Set the generated iOS deployment target to **18.0** in the Xcode project and Podfile.

Create your local build environment file:

```bash
cp .env.example .env
```

Fill the ScreenScraper values, restore the StikJIT framework, then build with the three integrated paths enabled:

```bash
flutter build ios \
  --release \
  --no-codesign \
  --dart-define-from-file=.env \
  --dart-define=NEOSTATION_EXPERIMENTAL_STIKJIT_MELONX=true \
  --dart-define=NEOSTATION_MELONX_BUNDLE_ID=com.nur.nx \
  --dart-define=NEOSTATION_EXPERIMENTAL_STIKJIT_ARMSX2=true \
  --dart-define=NEOSTATION_ARMSX2_BUNDLE_ID=com.armsx2.ios \
  --dart-define=NEOSTATION_EXPERIMENTAL_STIKJIT_RPCS3=true \
  --dart-define=NEOSTATION_RPCS3_BUNDLE_ID=com.xitrix.RPCS3
```

`.env` is intentionally excluded from Git and **must never be committed**.

The official fork pipeline also runs `build-utils/force_ios_fork_icon.sh` after Flutter's icon generator so the iOS AppIcon catalog is replaced with `assets/images/fork-icon-valid.jpg` on every release build.

## ScreenScraper configuration

ScreenScraper requires developer credentials before NeoStation can communicate with the API. These build-time credentials are separate from each user's ScreenScraper account credentials.

```text
SCREENSCRAPER_DEV_ID=your_developer_id
SCREENSCRAPER_DEV_PASSWORD=your_developer_password
```

NeoStation consumes these values through Dart compile-time defines. The application does **not** read a runtime `.env` file after installation.

## Main-menu customization

The primary Systems screen can use a user-selected custom background. Supported static and animated media are copied into NeoStation's user-data directory so the selection survives file-provider access changes. The background is intentionally limited to the main Systems menu; game playlists and other top-level screens retain their normal theme surfaces.

A user-selected menu-music track is likewise copied into NeoStation user data. Menu music loops only while the primary Systems menu is visible, stops when NeoStation leaves that menu or is backgrounded, and yields to the normal music player.

## Diagnostics

NeoStation writes separate on-device diagnostic files for the integrated JIT paths:

```text
stikjit_melonx_debug.txt
stikjit_armsx2_debug.txt
stikjit_rpcs3_debug.txt
```

These files help distinguish pairing, device preparation, bundle discovery, PID attachment and post-JIT handoff failures without mixing the three emulator paths.

## Project structure

```text
assets/       bundled images, data, sounds, shaders and system resources
lib/          Flutter application source
packages/     vendored/local Flutter packages used by the workspace
test/         automated Flutter/Dart tests
android/      inherited Android platform implementation
linux/        inherited Linux platform implementation
macos/        inherited macOS platform implementation
windows/      inherited Windows platform implementation
build-utils/  auxiliary build/source tooling
```

Within `lib/`:

```text
lib/
├── data/          SQLite access and migrations
├── l10n/          localization
├── models/        data models
├── providers/     application state
├── repositories/  data-access layer
├── screens/       UI screens
├── services/      business logic and emulator integrations
├── sync/          cloud synchronization
├── themes/        UI color themes
├── utils/         helpers
└── widgets/       reusable UI
```

See [`ARCHITECTURE.md`](ARCHITECTURE.md) for implementation details and [`THEMES.md`](THEMES.md) for UI-theme guidance.

## Support and feedback

- Bugs and feature requests: [GitHub Issues](https://github.com/TarbleFR/neostation-ios/issues)
- iOS-fork discussion and experimental-build feedback: [TarbleFR on Patreon](https://www.patreon.com/cw/TarbleFR)
- Reddit: [u/Mysterious_Air2053](https://www.reddit.com/user/Mysterious_Air2053/)

For issues that reproduce only in the original non-iOS NeoStation project, report them upstream instead.

## Upstream project and attribution

NeoStation iOS is based on the upstream **NeoStation** project:

- Upstream repository: https://github.com/misobadev/neostation-frontend
- Lead: **[@misobadev](https://github.com/misobadev)**
- Official co-maintainer: **[@androosio](https://github.com/androosio)**
- Official collaborator: **[@ItsRetroPup](https://github.com/ItsRetroPup)**

All upstream authors and contributors retain attribution for their contributions. The upstream repository history and contributor list remain the authoritative record for the original project.

### iOS fork

- iOS developer and maintainer: **[@TarbleFR](https://github.com/TarbleFR)**
- Patreon: **[TarbleFR](https://www.patreon.com/cw/TarbleFR)**
- Modified iOS version maintained since **August 2026**.

<!-- DOLPHIN_ISOLATION_BEGIN: native_component_credits -->
## Third-party components and licenses · Composants tiers et licences

- **[Dolphin / DolphiniOS](https://github.com/OatmealDome/dolphin-ios/tree/7cac54161659421ed95c2cd1c0b0746539a4cd38)** — embedded GameCube/Wii engine, by the Dolphin Emulator and DolphiniOS contributors. Most original code is GPL-2.0-or-later; see the upstream [COPYING and per-file license notices](https://github.com/OatmealDome/dolphin-ios/blob/7cac54161659421ed95c2cd1c0b0746539a4cd38/COPYING).
- **[StikJIT 1.5.0](https://github.com/StikDebug/StikJIT/tree/1.5.0)** — JIT support, by StikDebug and contributors, under the [Mozilla Public License 2.0](https://github.com/StikDebug/StikJIT/blob/1.5.0/LICENSE).

Integration changes and exact source references are documented in [NOTICE.md](NOTICE.md).
<!-- DOLPHIN_ISOLATION_END: native_component_credits -->

## GPL-3.0 and corresponding source

NeoStation and this modified iOS fork are distributed under the **GNU General Public License v3.0 (GPL-3.0)**. See [`LICENSE.md`](LICENSE.md) for the complete license text and [`NOTICE.md`](NOTICE.md) for copyright, modification and third-party notices.

The **corresponding source** for an IPA is the exact source commit or tag used to produce that binary. When redistributing an IPA elsewhere, keep the GPL and applicable notices available to recipients and provide a clear reference to that source revision.

Third-party components, packages, artwork, trademarks and emulator projects can have their own licenses or terms. Preserve their notices where applicable.

## Contributing

Please read [`CONTRIBUTING.md`](CONTRIBUTING.md) before opening a bug report, feature request or pull request.

## Security

Please follow [`SECURITY.md`](SECURITY.md) for responsible vulnerability reporting.

## License

GNU General Public License v3.0. Nothing in this README restricts or replaces the rights granted by the GPL-3.0.
