NeoStation - Emulation Hub
Copyright (C) 2025-2026 Miguel Soto <miguelsotobaez@gmail.com>

Modified iOS port and iOS-specific adaptations:
Copyright (C) 2026 TarbleFR
Modified for iOS beginning August 2026.

This repository contains a modified version of the upstream NeoStation project.
The upstream project and its contributors retain attribution for their original
work. The iOS-specific changes in this repository are maintained independently
and do not imply endorsement by the upstream maintainers or by any integrated
third-party project.

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version where the original licensing permits.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program. If not, see <https://www.gnu.org/licenses/>.

---

CURRENT STABLE IOS BASELINE — BUILD 322

Source commit:
a36a01bc519300369c0d8f9ba9073753c884786f

Successful Actions run:
35970470533
https://github.com/TarbleFR/neostation-ios/actions/runs/35970470533

Artifact:
NeoStation-iOS-Build-322-Dusklight-Warm-Resume

IPA SHA-256:
beb546f5b98b25f27b1903067f1c46956f57a3d2e92ff7fd79b6b34838e9236c

Build 322 remains the documented restoration point until a later experimental
build is explicitly device-validated and promoted. A successful CI run alone
does not make an experimental build the new stable baseline.

The corresponding source for an IPA is the exact Git commit whose source tree
was used to produce that binary. Documentation/CI maintenance commits do not
retroactively become the source revision of an earlier IPA.

Public source repository:
https://github.com/TarbleFR/neostation-ios

When redistributing an IPA, preserve applicable licenses and notices and give
recipients access to matching source, integration modifications and build
scripts.

---

UPSTREAM NEOSTATION ATTRIBUTION

Upstream NeoStation repository:
https://github.com/misobadev/neostation-frontend

Lead:
https://github.com/misobadev

Upstream co-maintainer:
https://github.com/androosio

Upstream collaborator:
https://github.com/ItsRetroPup

All upstream authors and contributors retain attribution for their respective
contributions. See the upstream repository history and contributor list for the
complete authorship record.

NeoStation iOS port / maintainer:
https://github.com/TarbleFR

---

DOLPHIN / DOLPHINIOS — EMBEDDED GAMECUBE AND WII ENGINE

Copyright their respective Dolphin Emulator and DolphiniOS contributors.

Pinned embedded source revision:
7cac54161659421ed95c2cd1c0b0746539a4cd38

Source:
https://github.com/OatmealDome/dolphin-ios/tree/7cac54161659421ed95c2cd1c0b0746539a4cd38

Most original Dolphin code is GPL-2.0-or-later. Preserve upstream COPYING,
LICENSES/ and individual file SPDX/copyright notices; other bundled components
retain their own licenses. This notice does not relicense third-party code.

NeoStation's Dolphin engine modifications live primarily in
build-utils/patch_dolphin_internal_core_v2.py,
packages/dolphin_internal_bridge/ and related native helper code.

---

RPCS3 / XITRIX RPCS3 IOS — EMBEDDED PLAYSTATION 3 ENGINE

NeoStation's current RPCS3 materialization path uses a pinned RPCS3 iOS release
published by XITRIX and extracts the verified core for NeoStation packaging.

XITRIX iOS release repository:
https://github.com/XITRIX/RPCS3-iOS-Releases

Pinned release currently referenced by the materializer:
v0.8.1

RPCS3 upstream:
https://github.com/RPCS3/rpcs3

XITRIX's own project credits the RPCS3 project for the emulator core, ARMSX3 for
ARM64 CPU optimizations, StikDebug for iOS JIT work, and the wider iOS emulation
community. Those upstream credits remain applicable.

NeoStation-specific RPCS3 lifecycle, JIT, diagnostics, save-state, input,
performance and UI modifications are maintained in build-utils/rpcs3*,
packages/rpcs3_internal_bridge/ and related native helper files.

---

ARMSX2 / PCSX2 — EMBEDDED PLAYSTATION 2 ENGINE

ARMSX2 repository:
https://github.com/ARMSX2/ARMSX2

Pinned NeoStation source revision:
8b5fad23dc290660aa394e75b0fd23e31099eaec

ARMSX2 identifies itself as a native ARM64 JIT fork of PCSX2 and explicitly
credits the PCSX2 project whose long-running emulator work it builds upon.

PCSX2:
https://github.com/PCSX2/pcsx2

Preserve ARMSX2/PCSX2 upstream licenses and copyright notices for the source
revision used by a particular build.

---

DUSKLIGHT — EMBEDDED TWILIGHT PRINCESS REIMPLEMENTATION

Dusklight repository:
https://github.com/TwilitRealm/dusklight

Pinned NeoStation source revision:
ad979d3dae092d0f5cbdaf49eabca7b4f1db4838

Dusklight describes itself as a reverse-engineered reimplementation of Twilight
Princess. Its upstream credits include the Twilight Princess decompilation
team/community, Aurora developers and other contributors.

Twilight Princess decompilation:
https://github.com/zeldaret/tp

Aurora:
https://github.com/encounter/aurora

NeoStation's iOS host/lifecycle adaptations are maintained separately under
native/dusklight/, build-utils/dusklight/ and
packages/dusklight_internal_bridge/.

---

KARTPAD / WIICOMPILED — EMBEDDED MARIO KART WII RUNTIME

KartPad:
https://github.com/chrissotraidis/kartpad

KartPad creator/maintainer:
https://github.com/chrissotraidis

NeoStation's current pinned KartPad release/source metadata is recorded in:
build-utils/kartpad/source.json

KartPad states that it builds on WiiCompiled, the original Mario Kart Wii static
recompilation project created by patchzyy.

WiiCompiled:
https://github.com/patchzyy/Wiicompiled

WiiCompiled creator:
https://github.com/patchzyy

NeoStation's KartPad integration does not claim authorship of KartPad,
WiiCompiled or their translated/runtime work. NeoStation-specific embedding,
menu, lifecycle and storage adaptations are maintained in native/kartpad/,
build-utils/kartpad/ and packages/kartpad_internal_bridge/.

---

MELONX / RYUJINX — EXTERNAL NINTENDO SWITCH INTEGRATION

MeloNX repository:
https://github.com/nurtrino/MeloNX

NeoStation integrates with MeloNX through library synchronization, URL schemes,
media association and JIT-oriented handoff. NeoStation does not redistribute
the MeloNX application as an embedded core.

MeloNX describes itself as based on Ryujinx/Ryubing and preserves its own
third-party attribution list. Preserve those upstream notices when
redistributing MeloNX itself.

---

RETROARCH / LIBRETRO — EXTERNAL EMULATOR INTEGRATION

RetroArch:
https://github.com/libretro/RetroArch

NeoStation can link/synchronize a RetroArch library and use supported direct
launch flows. RetroArch remains a separately maintained project with its own
licenses, cores and third-party notices.

---

STIKJIT FRAMEWORK 1.5.0 — MOZILLA PUBLIC LICENSE 2.0

Copyright StikDebug and the StikJIT contributors.

Source:
https://github.com/StikDebug/StikJIT/tree/1.5.0

License:
https://github.com/StikDebug/StikJIT/blob/1.5.0/LICENSE

This component is the embedded StikJIT XCFramework, licensed under MPL-2.0.
It is distinct from the separate StikDebug application. Bundled idevice,
universal.js and legacy.js components retain their own licenses/notices.

NeoStation does not embed or redistribute LocalDevVPN. Users who choose that
route install, configure and control the separate application independently.

---

GAMEDB / GAMEDB-PS3 — PS3 TITLE CATALOG

GameDB creator:
Niema / @niemasd
https://github.com/niemasd

GameDB:
https://github.com/niemasd/GameDB

GameDB-PS3:
https://github.com/niemasd/GameDB-PS3

NeoStation may download GameDB-PS3's GPL-3.0 PS3.titles.json release asset and
cache it in the user-data directory to resolve PS3 serial numbers when local
metadata and ScreenScraper do not provide a usable title.

GameDB explicitly asks downstream projects to provide attribution to GameDB and
to the source datasets used by the individual database. GameDB-PS3 lists:

- MiSTer Addons — https://misteraddons.com/
- Redump — http://redump.org/

NeoStation does not claim authorship of GameDB or its dataset. Preserve GameDB,
GameDB-PS3 and source-dataset attribution when redistributing a cached or bundled
copy.

---

METADATA / COMMUNITY SERVICES

ScreenScraper:
https://www.screenscraper.fr/

RetroAchievements:
https://retroachievements.org/

NeoStation uses these services only through their supported integrations and
does not claim ownership of their data, artwork, APIs, trademarks or community
content.

---

OTHER THIRD-PARTY COMPONENTS

This project includes or depends on additional third-party software, including:

- flutter_soloud / SoLoud audio engine
- gamepads plugin family under packages/gamepads*
- 7-Zip / LZMA SDK through packages/flutter_7zip
- external_folder_access
- SDL and platform/runtime dependencies pulled by embedded upstream projects
- Aurora and other renderer/runtime dependencies used by applicable upstream
  projects

Preserve the license/notice files shipped with those packages and their upstream
projects. Additional Flutter/Dart dependencies are governed by their own
licenses and terms.

---

TRADEMARK NOTICE

All trademarks, service marks, trade names, product names and logos appearing
in this project — including Nintendo, Sony PlayStation, Microsoft Xbox, SEGA,
RetroArch, Dolphin, DolphiniOS, RPCS3, ARMSX2, MeloNX, Dusklight, KartPad,
StikJIT and other referenced projects — are the property of their respective
owners where applicable.

NeoStation iOS is an independent frontend project and is not affiliated with,
endorsed by, sponsored by, or otherwise associated with those trademark holders
unless explicitly stated otherwise. Names are used for identification,
interoperability and compatibility purposes.
