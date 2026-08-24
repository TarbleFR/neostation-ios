<div align="center">

# NeoStation iOS

<h4>iOS 18+ port of the NeoStation Flutter emulation frontend</h4>

[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE.md)
[![Stars](https://img.shields.io/github/stars/TarbleFR/neostation-ios?logo=github)](https://github.com/TarbleFR/neostation-ios/stargazers)
[![Issues](https://img.shields.io/github/issues/TarbleFR/neostation-ios)](https://github.com/TarbleFR/neostation-ios/issues)
[![Platform](https://img.shields.io/badge/Platform-iOS%2018%2B-blue)](https://github.com/TarbleFR/neostation-ios)

![NeoStation iOS Preview](assets/readme/neostation-ios-preview.png)

</div>

NeoStation iOS is an **iOS 18+ port** of the upstream [NeoStation](https://github.com/misobadev/neostation-frontend) project. It keeps the original Flutter frontend while adding iPhone file handling, emulator integration, library synchronization, sideloading support and iOS-specific launch flows.

> **Modified version notice — August 2026**  
> This repository contains a modified version of NeoStation. The upstream project and its contributors retain credit for the original work. The iOS-specific port and adaptations in this repository are developed and maintained by [@TarbleFR](https://github.com/TarbleFR). This does not imply endorsement by the upstream NeoStation maintainers. The covered modified work is distributed under the GNU General Public License v3.0.

## Highlights

- **iOS 18+** release target.
- **RetroArch** library linking/synchronization and direct game launching through deeplinks.
- **MeloNX** library synchronization, media association, direct launching and JIT-oriented launch flows.
- **ARMSX2** library synchronization, direct launching and JIT-oriented launch flows.
- **RPCS3 iOS** Data-folder synchronization, PARAM.SFO title repair, Title-ID ScreenScraper lookup and a conservative StikDebug Universal JIT launch. NeoStation currently opens RPCS3 normally; the user then presses **Start / Commencer** and selects the game inside RPCS3.
- Installed-emulator detection in NeoStation settings.
- iOS-specific document, media and external-folder handling.
- **Book and manga management** using local files and compatible sources configured by the user, with reading, cover artwork, metadata, search and collection organization.
- **Custom main-menu backgrounds** using PNG, JPG/JPEG, WebP, GIF, MP4, M4V or MOV files.
- **Optional main-menu music** using MP3, WAV, OGG or FLAC files, played only while the main Systems menu is active.
- ScreenScraper metadata and media scraping.
- RetroAchievements support.
- NeoSync account and cloud-save features inherited from NeoStation.
- Gamepad-focused landscape navigation.
- SideStore and compatible sideloading support.

The upstream NeoStation project supports additional platforms. This repository is maintained primarily as the **iOS port**; use the upstream repository for canonical non-iOS documentation and releases.

## Requirements

### To run

- iOS 18 or newer.
- An IPA signing/sideloading method such as SideStore or another compatible installer, or Apple Developer signing.
- RetroArch, MeloNX, ARMSX2 or RPCS3 when using the corresponding integration.

### To build locally

- macOS with a compatible Xcode installation.
- Flutter SDK **3.9.2 or newer**.
- ScreenScraper developer credentials when building with ScreenScraper enabled.

## Build from source

Clone this iOS port and resolve the Flutter workspace:

```bash
git clone https://github.com/TarbleFR/neostation-ios.git
cd neostation-ios
flutter pub get
```

The generated `ios/` Xcode scaffold is intentionally not committed. Create it when needed:

```bash
flutter create --platforms=ios --org com.neogamelab --project-name neostation .
```

Set the generated iOS deployment target to **18.0** in the Xcode project/Podfile before producing the release build.

Create your local build environment file:

```bash
cp .env.example .env
```

Fill the two ScreenScraper values in `.env`, then build:

```bash
flutter build ios --release --no-codesign --dart-define-from-file=.env
```

`.env` is intentionally excluded from Git and **must never be committed**.

The official fork build pipeline also runs `build-utils/force_ios_fork_icon.sh` after Flutter's icon generator so the iOS AppIcon catalog is forcibly replaced with `assets/images/fork-icon-valid.jpg` on every release build.

## ScreenScraper configuration

ScreenScraper requires developer credentials before NeoStation can communicate with the API. These build-time credentials are separate from each user's ScreenScraper account credentials.

```text
SCREENSCRAPER_DEV_ID=your_developer_id
SCREENSCRAPER_DEV_PASSWORD=your_developer_password
```

NeoStation consumes these values through Dart compile-time defines. The application does **not** read a runtime `.env` file after installation.

The current ScreenScraper user-credential path uses the project's established SQLite/Base64 persistence.

## Main-menu customization

The primary Systems screen can use a user-selected custom background. Supported static/animated media are copied into NeoStation's user-data directory so the selection survives file-provider access changes. The background is intentionally limited to the main Systems menu; pushed game playlists and other top-level screens retain their normal theme surfaces.

A user-selected menu-music track is likewise copied into NeoStation user data. Menu music loops only while the primary Systems menu is visible, stops when NeoStation leaves that menu or is backgrounded, and yields to the normal music player.

## Books and manga

NeoStation iOS allows users to import, organize and read books and manga. Users must add their own files or independently find and configure compatible sources.

NeoStation iOS does not provide, host or reference any source of copyrighted content. Content availability depends exclusively on the files and sources added by the user.

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
├── services/      business logic and integrations
├── sync/          cloud synchronization
├── themes/        UI color themes
├── utils/         helpers
└── widgets/       reusable UI
```

See [`ARCHITECTURE.md`](ARCHITECTURE.md) for implementation details and [`THEMES.md`](THEMES.md) for UI-theme guidance.

## Support and feedback

- Bugs and feature requests: [GitHub Issues](https://github.com/TarbleFR/neostation-ios/issues)
- iOS-port discussion / experimental-build feedback: [TarbleFR on Patreon](https://www.patreon.com/cw/TarbleFR)
- Reddit: [u/Mysterious_Air2053](https://www.reddit.com/user/Mysterious_Air2053/)

For issues that reproduce only in the original non-iOS NeoStation project, report them upstream instead.

## Upstream project and attribution

NeoStation iOS is based on the upstream **NeoStation** project:

- Upstream repository: https://github.com/misobadev/neostation-frontend
- Lead: **[@misobadev](https://github.com/misobadev)**
- Official co-maintainer: **[@androosio](https://github.com/androosio)**
- Official collaborator: **[@ItsRetroPup](https://github.com/ItsRetroPup)**

All upstream authors and contributors retain attribution for their contributions. The upstream repository history and contributor list remain the authoritative record for the original project.

### iOS port

- iOS port developer / maintainer: **[@TarbleFR](https://github.com/TarbleFR)**
- Patreon: **[TarbleFR](https://www.patreon.com/cw/TarbleFR)**
- Modified iOS version maintained since **August 2026**.

## GPL-3.0 and corresponding source

NeoStation and this modified iOS port are distributed under the **GNU General Public License v3.0 (GPL-3.0)**. See [`LICENSE.md`](LICENSE.md) for the complete license text and [`NOTICE.md`](NOTICE.md) for copyright, modification and third-party notices.

The **corresponding source** for an IPA is the exact source commit or tag used to produce that binary. When redistributing an IPA elsewhere, keep the GPL and applicable notices available to recipients and provide a clear reference to that source revision.

Third-party components, packages, artwork, trademarks and emulator projects can have their own licenses or terms. Preserve their notices where applicable.

## Contributing

Please read [`CONTRIBUTING.md`](CONTRIBUTING.md) before opening a bug report, feature request or pull request.

## Security

Please follow [`SECURITY.md`](SECURITY.md) for responsible vulnerability reporting.

## License

GNU General Public License v3.0. Nothing in this README restricts or replaces the rights granted by the GPL-3.0.
