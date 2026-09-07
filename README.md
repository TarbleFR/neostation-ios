<div align="center">

# NeoStation iOS

<h4>An iPhone and iPad emulation frontend with embedded DolphiniOS and integrated StikJIT</h4>

[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE.md)
[![Platform](https://img.shields.io/badge/Platform-iOS%2018%2B-blue)](https://github.com/TarbleFR/neostation-ios)

![NeoStation iOS Preview](assets/readme/neostation-ios-preview.png)

</div>

NeoStation iOS is an independent iOS fork of [NeoStation](https://github.com/misobadev/neostation-frontend), maintained by [TarbleFR](https://github.com/TarbleFR). It combines the original Flutter library frontend with iPhone/iPad file handling, emulator-library synchronization, sideloading and dedicated JIT bridges.

## Current baseline — Build 207

The maintained project is based on Build 207 with NeoSync and the embedded DolphiniOS integration.

- Source baseline: `09b3fb3ac851b327732aeb8aa8f6e3e4749dfce6`
- Active branches: `main` and `backup`
- GameCube/Wii: embedded Dolphin/DolphiniOS engine
- Cloud saves: NeoSync
- JIT: integrated StikJIT path for Dolphin

No IPA or GitHub Release is published automatically. Any IPA upload or GitHub Release requires explicit approval from the maintainer before publication.

## Embedded GameCube and Wii

GameCube and Wii run through an embedded Dolphin/DolphiniOS engine inside NeoStation. A separate DolphiniOS application is not required for these systems.

NeoStation keeps the existing RetroArch, MeloNX, ARMSX2 and RPCS3 integrations for the other supported systems.

## Features

- Embedded DolphiniOS engine for GameCube and Wii.
- StikJIT integration for the embedded Dolphin execution path.
- NeoSync cloud-save support.
- RetroArch, MeloNX, ARMSX2 and RPCS3 integrations.
- ScreenScraper media and metadata.
- RetroAchievements support.
- iOS external-folder handling.
- Gamepad-oriented landscape navigation.
- Custom backgrounds and menu music.

## Requirements

- iPhone or iPad running iOS/iPadOS 18 or newer.
- A compatible sideload signing method with the required entitlements.
- Your own legally obtained game and system files.
- Pairing File and LocalDevVPN/RSD preparation when required for JIT.

## Build and distribution policy

The repository is not an automatic public IPA distribution channel. Builds may be produced for development and device validation, but an IPA must not be uploaded to GitHub and a GitHub Release must not be created unless the maintainer explicitly authorizes it.

## Credits and licenses

NeoStation iOS is based on [NeoStation](https://github.com/misobadev/neostation-frontend). Credit remains with Miguel Soto / misobadev and the upstream contributors.

The embedded GameCube/Wii engine uses work from the [Dolphin Emulator and DolphiniOS contributors](https://github.com/OatmealDome/dolphin-ios). StikJIT integration uses the [StikJIT framework](https://github.com/StikDebug/StikJIT). Preserve all applicable upstream copyright, license and third-party notices.

See [LICENSE.md](LICENSE.md) and [NOTICE.md](NOTICE.md) for project and third-party licensing information.

No copyrighted games, BIOS/IPL, firmware or device Pairing Files are distributed with this project.

## Support

[GitHub Issues](https://github.com/TarbleFR/neostation-ios/issues) · [Patreon](https://www.patreon.com/cw/TarbleFR) · [Reddit](https://www.reddit.com/user/Mysterious_Air2053/)
