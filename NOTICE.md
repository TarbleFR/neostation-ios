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

CURRENT STABLE IOS BASELINE — BUILD 350 / GITHUB RELEASE 0.0.1

Published release:
https://github.com/TarbleFR/neostation-ios/releases/tag/0.0.1

Release asset:
NeoStation.ipa

Packaging source commit:
5e6dc00b35b7bb7847c24198d9f4b08ade8ed9a0

Successful Actions run:
36323843067
https://github.com/TarbleFR/neostation-ios/actions/runs/36323843067

Workflow artifact ID:
10932894067

Original validated artifact:
NeoStation-iOS-Build-350-KartPad-Relaunch-Candidate

IPA size:
143538718 bytes

IPA SHA-256:
e1017b96842ec970be3ed0cd981083ee945d069cf76e689a4ca3c81339299b46

Build 350 is the documented stable restoration point promoted on
27 September 2026. The GitHub release 0.0.1 publishes that already-validated
binary under the asset name NeoStation.ipa.

The corresponding source for an IPA is the exact Git commit whose source tree
was used to produce that binary. Documentation, attribution and CI-maintenance
commits made after publication do not retroactively become the source revision
of the 0.0.1 IPA and do not alter its bytes.

Public source repository:
https://github.com/TarbleFR/neostation-ios

Detailed attribution and source identity:
https://github.com/TarbleFR/neostation-ios/blob/main/docs/LEGAL_AND_CREDITS.md
https://github.com/TarbleFR/neostation-ios/blob/main/docs/RELEASE_0.0.1_SOURCE_MANIFEST.md

When redistributing an IPA, preserve applicable licenses and notices and give
recipients access to matching source, integration modifications and build
scripts required by the applicable licenses.

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

NeoStation's canonical RPCS3 materialization path uses the XITRIX RPCS3 fork
at the exact revision recorded in build-utils/rpcs3/canonical-source.json.

Pinned source:
https://github.com/XITRIX/rpcs3/tree/22f1152783cef1f7e04af7b1c895173e28fd5b03

XITRIX iOS release repository:
https://github.com/XITRIX/RPCS3-iOS-Releases

RPCS3 upstream:
https://github.com/RPCS3/rpcs3

The exact pinned XITRIX/rpcs3 source carries RPCS3's GNU GPL version 2 license;
its README states that most files are GPL-2.0-only and that some files may use
different licenses. NeoStation does not claim to relicense RPCS3. Preserve the
exact file-specific notices and third-party terms.

XITRIX's project credits the RPCS3 project for the emulator core, ARMSX3 for
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

KartPad's RIGHTS_AND_LICENSES.md states that KartPad-owned software and its
WiiCompiled modifications are GPL-3.0-only where covered, while rights in
Nintendo-owned game content and ahead-of-time translated game logic remain a
separate issue. NeoStation does not claim that the software license grants
rights in Mario Kart Wii or other commercial game content.

The pinned NeoStation source manifest also records that the public KartPad
source delivery excludes generated translation/profile inputs and that a full
KartPadCore requires an authorized RMCP01 translation graph. Do not describe
the public source set as complete KartPad Corresponding Source unless the exact
required source for the distributed binary is actually available.

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

STIKJIT FRAMEWORK 1.9.0 — MOZILLA PUBLIC LICENSE 2.0

Copyright StikDebug and the StikJIT contributors.

Source:
https://github.com/StikDebug/StikJIT/tree/1.9.0

License:
https://github.com/StikDebug/StikJIT/blob/1.9.0/LICENSE

This component is the embedded StikJIT XCFramework, licensed under MPL-2.0.
It is distinct from the separate StikDebug application. Bundled idevice,
universal.js and legacy.js components retain their own licenses/notices.

NeoStation does not embed or redistribute LocalDevVPN. Users who choose that
route install, configure and control the separate application independently.

For executable distribution of the embedded StikJIT component, recipients must
also be informed how to obtain the MPL-covered Source Code Form. NeoStation's
legal/source manifest records the exact StikJIT source location used by the
project.

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

SYSTEM ART / REMOTE CREATIVE ASSETS

NeoStation Assets:
https://github.com/misobadev/neostation-assets

The NeoStation Assets repository states that its original backgrounds and custom
icons are licensed under CC BY-NC-SA 4.0, with attribution required and a
non-commercial condition for those original creative assets. Console logos and
other trademarks remain the property of their respective owners.

RiiSU:
https://github.com/mult1v4c/RiiSU

RiiSU credits iiSU Interpreted for ES-DE for its system art icons and iiSU
Network for the original inspiration:
https://github.com/VictorUnlocked/iisu-interpreted-es-de
https://iisu.network/

No standalone RiiSU license file was visible when this integration was added.
NeoStation therefore keeps RiiSU remotely hosted by its original project and
only downloads/caches the artwork when selected by the user.

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

---

FUTURE BINARY PACKAGING POLICY

Future NeoStation iOS builds are required by CI to include an application-bundle
Legal/ directory containing the NeoStation license and notice, comprehensive
third-party credits, exact build/source identity, and the pinned license texts
for Dolphin/DolphiniOS, RPCS3, ARMSX2, Dusklight, KartPad/WiiCompiled and
StikJIT. The build fails if required legal files are absent or stale relative to
the pinned source revisions.

This policy applies to future builds. It does not modify the already-published
NeoStation.ipa asset in GitHub release 0.0.1.
