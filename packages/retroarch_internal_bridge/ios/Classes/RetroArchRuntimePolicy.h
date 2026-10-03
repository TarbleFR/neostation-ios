#pragma once
#include "NeoRetroArchCoreAPI.h"
#include <string.h>

enum NeoRetroArchAPIValidation {
  NEO_RA_API_VALID = 0,
  NEO_RA_API_MISSING = 1,
  NEO_RA_API_VERSION = 2,
  NEO_RA_API_INCOMPLETE = 3,
  NEO_RA_API_IDENTITY = 4,
};

static inline NeoRetroArchAPIValidation NeoRetroArchValidateAPI(const NeoRetroArchCoreAPI* api) {
  if (!api) return NEO_RA_API_MISSING;
  if (api->abi_version != NEO_RETROARCH_ABI_VERSION || api->struct_size < sizeof(NeoRetroArchCoreAPI))
    return NEO_RA_API_VERSION;
  if (!api->runtime_identity || !api->initialize || !api->set_event_callback || !api->start ||
      !api->request_stop || !api->set_paused || !api->session_state || !api->capabilities || !api->command)
    return NEO_RA_API_INCOMPLETE;
  const char* identity = api->runtime_identity();
  if (!identity || strcmp(identity, NEO_RETROARCH_RUNTIME_IDENTITY) != 0) return NEO_RA_API_IDENTITY;
  return NEO_RA_API_VALID;
}
