# NeoStation iOS — Legal, Licenses and Credits

This document is the central attribution and redistribution record for the
NeoStation iOS fork. It supplements `LICENSE.md`, `NOTICE.md`, per-file SPDX
headers and the license files shipped by each upstream project.

Attribution does **not** imply endorsement by any upstream project, creator,
console manufacturer or trademark holder.

## NeoStation and the iOS fork

- **NeoStation** — original frontend/project by Miguel Soto / @misobadev, with
  @androosio, @ItsRetroPup and all upstream contributors.
  Source: https://github.com/misobadev/neostation-frontend
- **NeoStation iOS** — iOS/iPadOS fork, native integrations and maintenance by
  @TarbleFR.
  Source: https://github.com/TarbleFR/neostation-ios
- NeoStation's upstream notice is GPL-3.0-or-later. NeoStation iOS preserves
  that attribution and does not claim authorship of upstream work.

## Embedded runtimes and native components

| Component | Authors / upstream | License / redistribution note |
| --- | --- | --- |
| **Dolphin / DolphiniOS** | Dolphin Emulator contributors; OatmealDome and DolphiniOS contributors | Most original Dolphin code is GPL-2.0-or-later. The exact fork states the aggregate repository is GPLv3-compatible; per-file SPDX and `LICENSES/` remain authoritative. |
| **RPCS3 / XITRIX iOS fork** | RPCS3 contributors; XITRIX; upstream work credited by XITRIX including ARMSX3 and the iOS JIT community | The pinned XITRIX/rpcs3 source contains the RPCS3 GPL-2.0-only `LICENSE`. No relicensing by NeoStation is claimed. Preserve file-specific notices and third-party licenses. |
| **ARMSX2 / PCSX2** | ARMSX2 team and contributors; PCSX2 contributors | ARMSX2 distributes GPLv3 material and derives from PCSX2. Preserve the exact upstream notices and per-component licenses. |
| **Dusklight** | TwilitRealm/Dusklight contributors; Twilight Princess decompilation community; Aurora and Borealis contributors | Dusklight's root work is CC0-1.0; embedded dependencies retain their own licenses. |
| **KartPad / WiiCompiled** | KartPad by @chrissotraidis; WiiCompiled by @patchzyy | KartPad-owned software and its WiiCompiled modifications are GPL-3.0-only where stated by KartPad. WiiCompiled and dependency notices remain applicable. Game-derived translated logic has separate rights considerations and is not relicensed by the software licenses. |
| **StikJIT** | StikDebug / StikJIT contributors | MPL-2.0. Recipients of executable form must be informed how to obtain the covered source. |
| **Dawn, SDL, Aurora, Borealis and other runtime dependencies** | Their respective projects and contributors | Their individual license files and notices apply. |

### Exact source identities used by the stable 0.0.1 binary

See [RELEASE_0.0.1_SOURCE_MANIFEST.md](RELEASE_0.0.1_SOURCE_MANIFEST.md). That
file records the exact NeoStation packaging commit, workflow artifact identity
and pinned upstream revisions used for the published Build 350 IPA.

## External integrations

The following applications/services are **not claimed as NeoStation-owned
software** merely because NeoStation interoperates with them:

- **RetroArch / libretro** — https://github.com/libretro/RetroArch
- **MeloNX** — https://github.com/nurtrino/MeloNX
- **ScreenScraper** — https://www.screenscraper.fr/
- **RetroAchievements** — https://retroachievements.org/
- **LocalDevVPN** — user-installed external application when that route is used.

Their own terms, licenses, privacy policies and service rules apply.

## Metadata and datasets

### GameDB / GameDB-PS3

NeoStation thanks **Niema / @niemasd** for GameDB and GameDB-PS3:

- https://github.com/niemasd/GameDB
- https://github.com/niemasd/GameDB-PS3

GameDB-PS3 also identifies **MiSTer Addons** and **Redump** as source datasets.
NeoStation does not claim authorship of those datasets.

## KartPad / translated game-logic boundary

KartPad's own rights document explicitly separates the GPL-covered software
from rights in Nintendo-owned game content and from questions concerning
ahead-of-time translated game logic.

NeoStation therefore does not state or imply that:

- the GPL grants rights in Mario Kart Wii;
- Nintendo-owned code, data, characters, names, audio, textures or other
  commercial assets have been relicensed;
- possession of a NeoStation binary replaces the user's obligation to supply
  legally obtained supported game data where required.

The public NeoStation source manifest also records KartPad's upstream source
limitation concerning generated translation/profile inputs. A release must not
be described as providing complete KartPad Corresponding Source unless the
complete source required for that exact binary is actually available.

## RPCS3 licensing boundary

The exact pinned XITRIX/rpcs3 source used by NeoStation carries RPCS3's
GPL-2.0-only license for most files. NeoStation's host licensing does not change
that license. The RPCS3 core, NeoStation integration changes, file-specific
SPDX notices and third-party components must each retain their applicable
terms.

Because GPL combined-work questions can depend on the technical and legal
relationship between components, this project does not use attribution text to
claim that an otherwise incompatible license has been converted or waived.
Redistributors should review the exact architecture and licenses for the binary
they convey.

## Source availability and rebuild information

For GPL- and MPL-covered components, attribution alone is not a substitute for
source-code obligations.

NeoStation release documentation therefore identifies:

1. the exact NeoStation source commit used for the binary;
2. the exact upstream revisions used by embedded runtimes;
3. NeoStation's integration patches and build scripts;
4. the license and notice documents associated with those components.

See [RELEASE_0.0.1_SOURCE_MANIFEST.md](RELEASE_0.0.1_SOURCE_MANIFEST.md) for the
first public GitHub release.

## Trademarks and commercial game content

Nintendo, PlayStation, Sony, Microsoft, Xbox, SEGA, Dolphin, RPCS3, PCSX2,
ARMSX2, RetroArch, MeloNX, KartPad, StikJIT and all other referenced product
names, logos and trademarks remain the property of their respective owners.

NeoStation iOS is an independent project and is not affiliated with, sponsored
by or endorsed by those rights holders unless explicitly stated.

NeoStation does not provide ROMs, ISOs, BIOS files, console firmware,
encryption keys, commercial game assets or paid content. Users must provide
legally obtained content required by the software they use.

## Future binary packaging policy

Future NeoStation iOS builds should include a `Legal/` directory inside the
application bundle containing:

- the NeoStation GPL text and project notice;
- this attribution record;
- the exact release source manifest;
- Dolphin's COPYING notice;
- the exact RPCS3 GPL-2.0 license text;
- KartPad's rights and third-party notices;
- StikJIT's MPL-2.0 text;
- Dusklight's CC0-1.0 text;
- additional dependency notices collected by embedded projects.

The already-published `NeoStation.ipa` asset for release 0.0.1 is intentionally
not modified by this documentation policy.
