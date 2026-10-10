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

## Controller skins and the Provenance catalog

- **Catalog:** [Provenance-Emu/skins](https://github.com/Provenance-Emu/skins),
  maintained by the Provenance project and its community.
- **Format reference:** [Delta / DeltaCore](https://github.com/rileytestut/DeltaCore),
  by Riley Testut and contributors.
- **Artwork:** the individual creators credited by each skin or catalog entry.

NeoStation reads the external catalog at
https://provenance-emu.com/skins/catalog.json, with
https://raw.githubusercontent.com/Provenance-Emu/skins/main/catalog.json as fallback.
The catalog identifies skins; it does not transfer ownership of their artwork.

The embedded Libretro frontend supplies NeoStation default skins and installs
community skins only at the user's request. Third-party skin packs are not
bundled. Imported metadata retains the author when supplied and the original
download URL, or identifies a local file import. A missing author or license
must not be interpreted as a grant of redistribution rights; the application's
license does not relicense downloaded artwork.

Usage, compatibility and source references:
https://github.com/TarbleFR/neostation-ios/blob/Claude/docs/SKINS.md
