# Controller skins in NeoStation iOS

This guide describes the skin features included in **NeoStation iOS 0.0.4
(Build 435)**, source `90a4e513e3a97f642bc45963bfb689f7c4677d46`.

Skins customize the on-screen controls and screen placement for NeoStation's
**embedded Libretro consoles**. These are the emulation cores also used by
RetroArch. The catalog shown in NeoStation is the **Provenance Skin Catalog**.
Skin choices here do not configure the separate RetroArch application.

## Choose a skin

1. Open **Settings → Folders → Embedded consoles**.
2. Select the console, then **Skins**. You can do this before importing any game.
3. Choose **Browse the Provenance catalog** to browse skins for that console.
   Search by skin name or author, then select **Install**.
4. In the installed skin's card, choose **Use in portrait**, **Use in landscape**
   or **Use in both orientations**.

You can also open **Skins** from an embedded console's game-list actions.

Each of the 17 embedded console profiles has a **NeoStation default skin**,
inspired by the original console's controls. The defaults support iPhone and
iPad in portrait and landscape. Catalog availability varies by console; an
empty catalog does not remove the default skin.

## Import a file

Select **Import from Files** on the console's **Skins** page, then choose a
compatible `.deltaskin`, `.manicskin` or `.zip` archive.

An archive must contain one skin with an `info.json` description and its image
assets. A ZIP containing a single `.deltaskin` or `.manicskin` can also be
imported. If a ZIP contains several skins, extract it in Files and import the
skins individually.

The importer checks the archive and console compatibility. Read any remarks
shown after installation. If a skin with the same identifier already exists,
NeoStation asks before replacing it. A file extension alone does not guarantee
that every layout or feature in that skin is supported.

## Portrait, landscape and game-specific choices

Portrait and landscape selections are separate. If the selected skin has no
layout for an orientation, NeoStation uses its default skin for that orientation.
Choose **Use the default skin** to reset the console selection.

During a game, open **Display and controls → Skins**. The **Save for**
section lets you apply a choice to **Every {console} game** or **This game only**.
A game-specific choice takes priority over the console choice. Use
**Restore defaults** for the selected scope when you want to remove that override.

For Nintendo DS and Nintendo 3DS, supported skin layouts place both game screens
and the touch-screen area. Supported layouts depend on the skin and device.
Some skin functions may be ignored with an import remark, including unsupported
button actions and skin-specific picture filters. Buttons painted into the
background artwork cannot be moved independently.

## Catalog sources and creator credits

| Source | Role |
| --- | --- |
| [Provenance Skin Catalog](https://github.com/Provenance-Emu/skins) | Community-maintained skin index used by NeoStation's browser. |
| [Primary catalog JSON](https://provenance-emu.com/skins/catalog.json) | First catalog endpoint requested by the app. |
| [GitHub catalog JSON](https://raw.githubusercontent.com/Provenance-Emu/skins/main/catalog.json) | Fallback endpoint used if the primary request fails. |
| [Delta / DeltaCore](https://github.com/rileytestut/DeltaCore) | Reference skin format credited to Riley Testut and contributors. |
| Individual skin creators | Authors of the downloaded artwork and layouts, credited by each entry when available. |

The catalog is cached for 24 hours. A manual refresh requests it again; an
existing cached catalog can also be used when the network is unavailable.
A catalog entry must expose a supported direct archive download to be installed
inside NeoStation. Web pages and store pages are not treated as skin archives.

NeoStation supplies its own default skins. Community skin packs are downloaded
only when selected and are not included in the IPA. Installed skin details
retain the available author and download URL, or identify an import from Files.
Each creator's terms still apply. Catalog inclusion does not make artwork
NeoStation-owned or grant permission to redistribute it.

## Files and implementation references

Installed skins are stored in `Documents/Libretro/Skins/<id>/`.
Selections are stored in `Documents/Libretro/Config/Frontend/<console>.json`;
changing an emulation core for the same console does not change its skin choice.

- [Catalog service](../lib/services/libretro_skin_catalog_service.dart)
- [Import and selection service](../lib/services/libretro_skin_service.dart)
- [Skin manager](../lib/screens/libretro/libretro_skin_manager_screen.dart)
- [Catalog screen](../lib/screens/libretro/libretro_skin_catalog_screen.dart)
- [Native skin parser](../packages/libretro_internal_bridge/ios/Classes/LibretroSkin.m)
- [Default skins](../packages/libretro_internal_bridge/ios/Classes/LibretroDefaultSkins.m)
- [Design and implementation notes](libretro-skins-shaders.md)
- [Credits and notices](LEGAL_AND_CREDITS.md)
