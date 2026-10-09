# NeoStation iOS — Third-Party Notices

This directory is intended to be bundled into **future** NeoStation iOS builds.
It does not modify the already-published release 0.0.1 IPA.

The full maintained attribution record is:
https://github.com/TarbleFR/neostation-ios/blob/main/docs/LEGAL_AND_CREDITS.md

The exact 0.0.1 source/binary identity manifest is:
https://github.com/TarbleFR/neostation-ios/blob/main/docs/RELEASE_0.0.1_SOURCE_MANIFEST.md

Primary credited projects include NeoStation, Dolphin/DolphiniOS, RPCS3,
XITRIX, ARMSX2/PCSX2, Dusklight, Aurora, Borealis, KartPad/WiiCompiled,
StikJIT, RetroArch/libretro, MeloNX, GameDB/GameDB-PS3, ScreenScraper and
RetroAchievements.

Each component remains under its own applicable license and copyright notices.
Nothing in this file relicenses third-party software, game content, trademarks
or datasets.


## Remote System Art

### NeoStation Assets

Optional System Art is fetched at runtime from:
https://github.com/misobadev/neostation-assets

That repository licenses its original creative backgrounds and custom icons
under **CC BY-NC-SA 4.0**. Attribution to the NeoStation project is required;
the license includes NonCommercial and ShareAlike conditions. Console logos and
other trademarks remain owned by their respective holders.

### RiiSU / iiSU

RiiSU is a curated external System Art pack fetched on demand:
https://github.com/mult1v4c/RiiSU

RiiSU credits **iiSU Interpreted for ES-DE** for the system art icons and
**iiSU Network** for the original inspiration:
https://github.com/VictorUnlocked/iisu-interpreted-es-de
https://iisu.network/

No standalone RiiSU license file was visible when this integration was added.
NeoStation therefore keeps the artwork hosted by the original project and does
not treat it as NeoStation-owned or generally redistributable material.

## Optional cheat catalogue source

The RE4 PAL G4BP08 catalogue adapter fetches the author's public WIIRD topic
on demand from gc-forever. Credits: **Ralf / Ralf@gc-forever** and any authors
named beside each code. Source: https://www.gc-forever.com/forums/viewtopic.php?t=2145

The catalogue is not bundled in NeoStation. Imported entries retain the author
and source URL; attribution is not an endorsement or a claim to relicense the
creator's work. The source does not specify a disc revision.


## ARMSX2 2.6 shader runtime and presets

ARMSX2 iOS `iOSv2.6.0` uses **librashader 0.12.0** for its native Metal shader
chains. librashader is by **Ronny Chan / SnowflakePowered and contributors**.
The embedded C API is pinned to commit
`87e8a97b50516d997defeaa168173dcd185d4022`; its upstream package declares
`MPL-2.0 OR GPL-3.0-only`. Source and the upstream license notices are available at:
https://github.com/SnowflakePowered/librashader/tree/87e8a97b50516d997defeaa168173dcd185d4022

The bundled preset sources, their original copyright/license headers and
`ARMSX2Core.framework/shaders/ATTRIBUTION.md` are preserved from the official
ARMSX2 tag. The attribution file identifies each bundled shader's author and
license. Optional downloaded RetroArch presets keep their upstream source files
and notices as supplied by the pack; each file remains under its own license.

## Embedded Libretro cores — release 0.0.3

NeoStation now embeds 14 libretro cores: Nestopia, Snes9x, Gambatte, mGBA,
Genesis Plus GX, Genesis Plus GX Wide, PicoDrive, FinalBurn Neo, DeSmuME,
Mupen64Plus-Next, Beetle PSX, Beetle PSX HW, PPSSPP and Azahar.

Full core credits, original license texts, support-library notices, reference
revisions and distribution restrictions are in `assets/legal/libretro/`.
The IPA includes this collection in `Legal/Libretro/` and `Libretro-Licenses/`.
See the [core license record](https://github.com/TarbleFR/neostation-ios/blob/main/assets/legal/libretro/LIBRETRO_CORES.md)
and [0.0.3 provenance](https://github.com/TarbleFR/neostation-ios/blob/main/docs/RELEASE_0.0.3_SOURCE_MANIFEST.md).

Snes9x, Genesis Plus GX/Wide, PicoDrive and FinalBurn Neo have non-commercial
conditions; FBNeo additionally restricts monetary profit and donation solicitation.
The exact source revisions for the prebuilt core binaries were not attested
by their buildbot delivery. License-document snapshots are not a substitute
for complete Corresponding Source and do not establish full license compliance.

RetroArch itself remains an optional external application for routes using it;
the newly embedded core implementations are credited separately above.
