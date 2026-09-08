# NeoStation iOS

#### iOS/iPadOS emulation frontend

NeoStation iOS is an iPhone and iPad port of NeoStation. It keeps the Flutter frontend while adding iOS-specific library linking, sideloading, launch flows and an embedded DolphiniOS engine.

> Modified version notice — August 2026  
> This repository contains a modified version of NeoStation. The upstream project and its contributors retain credit for the original work. The iOS-specific port and adaptations in this repository are developed and maintained independently by @TarbleFR.

## Highlights

- Embedded **DolphiniOS** engine for GameCube and Wii.
- **RetroArch** library linking/synchronization and direct launching.
- **MeloNX** library synchronization, media association and JIT-oriented launch flows.
- **ARMSX2** PS2 library synchronization, direct launching and JIT-oriented launch flows.
- **RPCS3** PS3 Data-folder library synchronization, PARAM.SFO metadata repair and JIT-assisted launch flow.
- **StikJIT** integration for supported iOS emulator workflows.
- ScreenScraper metadata/media scraping and RetroAchievements.
- Gamepad-focused landscape navigation and multi-language UI.

## NeoSync on iOS

NeoSync remains available for **RetroArch saves and states**.

NeoSync is deliberately disabled for the following iOS emulator integrations:

- **DolphiniOS**
- **ARMSX2**
- **MeloNX**
- **RPCS3**

NeoStation does not scan, upload, download, restore or track save folders from those four integrations. Their library, launch and JIT functionality is independent from NeoSync.

## Requirements

### To run

- iOS 18 or newer.
- An IPA signing/sideloading method such as SideStore or another compatible installer, or Apple Developer signing.
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

NeoStation iOS is based on the upstream NeoStation project:

- Upstream repository: https://github.com/misobadev/neostation-frontend
- Lead: @misobadev
- Official co-maintainer: @androosio
- Official collaborator: @ItsRetroPup

All upstream authors and contributors retain attribution for their contributions.

### iOS port

- iOS port developer / maintainer: @TarbleFR
- Modified iOS version maintained since August 2026.

## GPL-3.0 and corresponding source

NeoStation and this modified iOS port are distributed under the GNU General Public License v3.0 (GPL-3.0). See `LICENSE.md` and `NOTICE.md` for the applicable license and attribution notices.

Third-party components, packages, artwork, trademarks and emulator projects can have their own licenses or terms. Preserve their notices where applicable.

## License

GNU General Public License v3.0.
