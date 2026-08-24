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

CORRESPONDING SOURCE

The corresponding source for an IPA is the exact Git commit or tag whose source
tree was used to produce that binary. The public repository is:

https://github.com/TarbleFR/neostation-ios

When redistributing an IPA from another location, distributors should preserve
this license and the applicable notices and give recipients clear access to the
matching source revision. A release/build artifact should never be represented
as corresponding to a different or older source tree.

---

UPSTREAM ATTRIBUTION

Upstream NeoStation repository:
https://github.com/misobadev/neostation-frontend

Upstream authors and contributors retain attribution for their respective
contributions. See the upstream repository history and contributor list for the
complete authorship record.

---

THIRD-PARTY COMPONENTS

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
  NeoStation may download `PS3.titles.json` from the GPL-3.0 GameDB-PS3
  project to resolve PS3 serial numbers when local metadata and ScreenScraper
  do not provide a usable title. Preserve the GameDB-PS3 license/attribution
  when redistributing a cached or bundled copy of that data.

Additional Flutter/Dart dependencies and emulator-related integrations may be
governed by their own licenses or terms. Preserve all required third-party
notices when redistribution requires it.

---

TRADEMARK NOTICE

All trademarks, service marks, trade names, product names and logos appearing
in this project (including but not limited to Nintendo, Sony PlayStation,
Microsoft Xbox, SEGA, RetroArch, MeloNX, ARMSX2 and other referenced projects)
are the property of their respective owners where applicable.

NeoStation iOS is an independent frontend project and is not affiliated with,
endorsed by, sponsored by, or otherwise associated with those trademark
holders unless explicitly stated otherwise. Names are used for identification
and compatibility purposes.
