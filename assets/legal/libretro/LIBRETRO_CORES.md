# Embedded Libretro cores — NeoStation iOS 0.0.3

This release packages 14 official iOS ARM64 libretro core binaries. RetroArch
is a separate frontend; NeoStation embeds these cores using its own host.
All original authors retain their rights. No endorsement or relicensing is implied.

## Credits and license texts

| Core | Systems | Authors / projects | License reference |
| --- | --- | --- | --- |
| Nestopia | NES / Famicom | Nestopia contributors; libretro port contributors | [GPLv2; per-file terms apply](nestopia-COPYING) |
| Snes9x | Super Nintendo | Snes9x authors and libretro port contributors | [Snes9x non-commercial license](snes9x-LICENSE) |
| Gambatte | Game Boy / Game Boy Color | Gambatte and libretro contributors | [GPLv2; per-file terms apply](gambatte-COPYING) |
| mGBA | Game Boy Advance | endrift and mGBA contributors | [MPL-2.0](mgba-LICENSE) |
| Genesis Plus GX | Sega 8/16-bit / Mega-CD | Charles MacDonald, Eke-Eke and contributors | [Non-commercial; additional component notices](genesis_plus_gx-LICENSE.txt) |
| Genesis Plus GX Wide | Sega 8/16-bit widescreen | Genesis Plus GX authors and Wide contributors | [Non-commercial; additional component notices](genesis_plus_gx_wide-LICENSE.txt) |
| PicoDrive | Sega / Mega-CD / 32X | notaz and authors listed in AUTHORS | [Custom non-commercial (legacy MAME-style), not a blanket GPL grant](picodrive-COPYING) |
| FinalBurn Neo | Arcade / Neo Geo | Team FBNeo, Final Burn and MAME contributors | [FBNeo non-commercial; no monetary profit or donation solicitation for projects using its source](fbneo-src-license.txt) |
| DeSmuME | Nintendo DS | DeSmuME and libretro contributors | [GPLv2; per-file terms apply](desmume-license.txt) |
| Mupen64Plus-Next | Nintendo 64 | Mupen64Plus, GLideN64 and libretro contributors | [GPLv2; component notices apply](mupen64plus_next-LICENSE) |
| Beetle PSX / Beetle PSX HW | PlayStation | Mednafen and libretro contributors | [GPLv2; component notices apply](beetle_psx-COPYING) |
| PPSSPP | PSP | Henrik Rydgård and PPSSPP contributors | [GPLv2 or later; bundled assets and dependencies retain their terms](ppsspp-LICENSE.TXT) |
| Azahar | Nintendo 3DS | Azahar, Citra, Lime3DS, PabloMK7 and libretro contributors | [GPLv2 or later; component notices apply](azahar-LICENSE.txt) |

## Support libraries and resources

- libretro API headers: libretro contributors, MIT; see `libretro-api-MIT.txt`.
- rcheevos 12.5.0: RetroAchievements contributors, MIT; see `rcheevos-LICENSE.txt`.
- Vulkan headers: Khronos contributors; see `Vulkan-Headers-LICENSE.md`.
- MoltenVK: Khronos/MoltenVK contributors, Apache-2.0; see `MoltenVK-LICENSE`.
  The binary was taken from RetroArch revision `df16ef193cbe385b87e8a1cf27b66da35bf3c0e0`;
  this revision is not asserted to be a MoltenVK source revision.
- PPSSPP resources preserve `LibretroSystem/PPSSPP/LICENSE.TXT` and the original
  shader, font and other resource notices in the IPA.

## Distribution conditions

Snes9x, Genesis Plus GX (including Wide), PicoDrive and FinalBurn Neo carry
non-commercial conditions. FinalBurn Neo also explicitly restricts monetary
profit and donation solicitation for projects using its source. This archive
does not grant permission for commercial use, sale, paid access, promotional
use or fundraising contrary to those terms. The complete upstream texts govern.

GPL and MPL obligations remain applicable to their respective components.
The host project's GPL does not replace core licenses or resolve combined-work
license compatibility. Adding attribution alone is not a compliance clearance.

## Source provenance and known limitation

`license-sources.json` records immutable upstream revisions and SHA-256 hashes
for the retrieved license documents. Those are **license reference snapshots**,
not attestations that those revisions produced the Build 427 binaries.

`Libretro-native-identity.json` in the IPA records the downloaded archives,
pre-signing binary hashes, retrieval dates and upstream repositories. The
original buildbot delivery did not supply an exact source commit or complete
Corresponding Source package for each binary. This release preserves that
limitation explicitly; the reference snapshots must not be represented as a
complete Corresponding Source delivery. Obtain the matching buildbot sources
and build inputs before making such a claim.
