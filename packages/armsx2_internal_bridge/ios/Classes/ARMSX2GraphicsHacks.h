// SPDX-License-Identifier: GPL-3.0-or-later
// The keys are verified against pinned ARMSX2's GSOptions and graphicsHackState.
#pragma once
#ifdef __cplusplus
#include <array>
#include <string_view>
struct NeoARMSX2GraphicsHack {
  const char* key;
  const char* english;
  const char* french;
};
inline constexpr std::array<NeoARMSX2GraphicsHack, 13> kNeoARMSX2GraphicsHacks = {{
  {"UserHacks", "Manual graphics hacks", "Hacks graphiques manuels"},
  {"paltex", "GPU palette conversion", "Conversion des palettes par le GPU"},
  {"UserHacks_CPU_FB_Conversion", "CPU framebuffer conversion", "Conversion du framebuffer par le CPU"},
  {"UserHacks_ReadTCOnClose", "Read targets when closing", "Lire les cibles à la fermeture"},
  {"UserHacks_DisableDepthSupport", "Disable depth emulation", "Désactiver l’émulation de profondeur"},
  {"UserHacks_DisablePartialInvalidation", "Disable partial invalidation", "Désactiver l’invalidation partielle"},
  {"preload_frame_with_gs_data", "Preload frame data", "Précharger les données d’image"},
  {"UserHacks_EstimateTextureRegion", "Estimate texture region", "Estimer la région des textures"},
  {"UserHacks_DrawBuffering", "Draw buffering", "Mise en tampon du rendu"},
  {"UserHacks_NativePaletteDraw", "Unscaled palette draw", "Palettes à la résolution native"},
  {"UserHacks_align_sprite_X", "Align sprites", "Aligner les sprites"},
  {"UserHacks_merge_pp_sprite", "Merge sprites", "Fusionner les sprites"},
  {"UserHacks_ForceEvenSpritePosition", "Force even sprite position", "Forcer la position paire des sprites"},
}};
inline bool NeoARMSX2ValidGraphicsHack(std::string_view key, int value) {
  if (value < -1 || value > 1) return false;
  for (const auto& hack : kNeoARMSX2GraphicsHacks)
    if (key == hack.key) return true;
  return false;
}
#endif
