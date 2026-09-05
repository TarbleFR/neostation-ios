NeoStation - Emulation Hub
Copyright (C) 2025-2026 Miguel Soto <miguelsotobaez@gmail.com>

Modified iOS port and iOS-specific adaptations:
Copyright (C) 2026 TarbleFR
Modified for iOS beginning August 2026.

This repository contains a modified version of the upstream NeoStation project.
The upstream project and its contributors retain attribution for their original
work. The iOS-specific changes in this repository are maintained independently
and do not imply endorsement by the upstream maintainers.

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

STABLE BUILD 198 AND CORRESPONDING SOURCE

Original binary source: d23c681b84826fa694c07fa48d3a60d78282d0ef
Source/release tag: ios-stable-198
Original successful Actions run: 33933842637
IPA SHA-256: 0754f5967fa07370802271931c58004fa1dd782bdf577bac2db064c0d3292f5f
Release: https://github.com/TarbleFR/neostation-ios/releases/tag/ios-stable-198

The original IPA is preserved without recompilation or binary modification.
Its matching source archive, signing entitlements and build evidence are release
assets, independent of historical Actions runs and artifact expiration.
The maintainer reported this build working on their device; automated CI did not
perform physical-device testing or establish universal game compatibility.

The corresponding source for an IPA is the exact Git commit or tag whose source
tree was used to produce that binary. Documentation/CI maintenance commits on
main and backup do not retroactively become the source revision of the original
Build 198 binary. The public source repository is:
https://github.com/TarbleFR/neostation-ios

When redistributing an IPA, preserve applicable licenses and notices and give
recipients access to the matching source, integration modifications and build
scripts. Never identify an unrelated or later runtime tree as its source.

---

UPSTREAM ATTRIBUTION

Upstream NeoStation repository:
https://github.com/misobadev/neostation-frontend

Upstream authors and contributors retain attribution for their respective
contributions. See the upstream repository history and contributor list for the
complete authorship record.

---

DOLPHIN / DOLPHINIOS — EMBEDDED GAMECUBE AND WII ENGINE

Copyright their respective Dolphin Emulator and DolphiniOS contributors.
Embedded source revision: 7cac54161659421ed95c2cd1c0b0746539a4cd38.
Source: https://github.com/OatmealDome/dolphin-ios/tree/7cac54161659421ed95c2cd1c0b0746539a4cd38
Most original Dolphin code is GPL-2.0-or-later. Preserve upstream COPYING,
LICENSES/ and individual file SPDX/copyright notices; other bundled components
retain their own licenses. This notice does not relicense third-party code.

NeoStation's engine modifications are in build-utils/patch_dolphin_internal_core_v2.py;
its host bridge and in-game interface are in packages/dolphin_internal_bridge/.
The original DolphiniOS touchscreen widgets, nib layouts, button artwork and
input profiles are adapted from the same pinned revision. Their source headers
are preserved; ci/touch_resources.json records the original resource hashes.
NeoStation adds C ABI input synchronization, cancelled-touch release, safe nib
initialization and controller-dependent visibility. Session profile and console
preference changes are in packages/dolphin_internal_bridge/core/.

The embedded engine is limited to GameCube and Wii. It does not require a second
DolphiniOS installation. User-provided GameCube IPL/system files and games are
not included or licensed by this repository.

---

STIKJIT FRAMEWORK 1.5.0 — MOZILLA PUBLIC LICENSE 2.0

Copyright StikDebug and the StikJIT contributors.
Source: https://github.com/StikDebug/StikJIT/tree/1.5.0
License: https://github.com/StikDebug/StikJIT/blob/1.5.0/LICENSE

This component is the embedded StikJIT XCFramework, licensed under MPL-2.0.
It is distinct from the separate StikDebug application, whose upstream license
is AGPL-3.0. Do not label the framework with the application's license.
As stated by StikJIT upstream, bundled idevice, universal.js and legacy.js retain
their own licenses and notices. Preserve these separately where applicable.

The distributed 1.5.0 framework is used with Swift interface compatibility
adjustments documented in packages/dolphin_internal_bridge/ci/build_support.py.
The Dolphin helper is in packages/dolphin_jit_helper/ and
native/dolphin_internal_helper/. It uses the Dolphin-specific legacy mechanism
and targets the host NeoStation PID. Existing external-emulator bridges keep
their own JIT behavior. No Pairing Files or signing credentials are distributed.

---

OTHER THIRD-PARTY COMPONENTS

This project includes or depends on third-party software, including:

- flutter_soloud / SoLoud audio engine (hosted Flutter dependency)
  Preserve the license/notice distributed by that package and SoLoud.

- gamepads plugin family (vendored under packages/gamepads*)
  Preserve the license files shipped with those packages.

- 7-Zip / LZMA SDK through packages/flutter_7zip
  Preserve packages/flutter_7zip/LICENSE and applicable upstream notices.

- external_folder_access (vendored under packages/external_folder_access)
  Preserve its package license and notices.

- GameDB-PS3 title catalog (runtime cached lookup)
  NeoStation may download PS3.titles.json from the GPL-3.0 GameDB-PS3 project
  to resolve PS3 serial numbers when local metadata and ScreenScraper do not
  provide a usable title. Preserve that project's license/attribution when
  redistributing a cached or bundled copy of that data.

Additional Flutter/Dart dependencies and emulator-related integrations may be
governed by their own licenses or terms. Preserve required third-party notices.

---

TRADEMARK NOTICE

All trademarks, service marks, trade names, product names and logos appearing
in this project (including Nintendo, Sony PlayStation, Microsoft Xbox, SEGA,
RetroArch, Dolphin, DolphiniOS, StikJIT, MeloNX, ARMSX2 and other referenced
projects) are the property of their respective owners where applicable.

NeoStation iOS is an independent frontend project and is not affiliated with,
endorsed by, sponsored by, or otherwise associated with those trademark
holders unless explicitly stated otherwise. Names are used for identification
and compatibility purposes.
