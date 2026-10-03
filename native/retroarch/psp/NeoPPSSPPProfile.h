#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <string.h>

/* Official PPSSPP libretro 91a34056: these values are applied before load_game
 * and protected in the shared options menu. No desktop/other-core setting is
 * changed. GET_JIT_CAPABLE must remain false in the embedded frontend. */
static inline const char *NeoPPSSPPRequiredOption(const char *coreId,
                                                const char *key) {
  if (!coreId || !key || strcmp(coreId, "ppsspp") != 0) return NULL;
  if (strcmp(key, "ppsspp_cpu_core") == 0) return "Interpreter";
  if (strcmp(key, "ppsspp_backend") == 0) return "opengl";
  return NULL;
}

static inline bool NeoPPSSPPOptionIsAllowed(const char *coreId,
                                            const char *key,
                                            const char *value) {
  const char *required = NeoPPSSPPRequiredOption(coreId, key);
  return !required || (value && strcmp(required, value) == 0);
}
