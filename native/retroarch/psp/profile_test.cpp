#include "NeoPPSSPPProfile.h"
#include <cassert>

int main() {
  assert(strcmp(NeoPPSSPPRequiredOption("ppsspp", "ppsspp_cpu_core"), "Interpreter") == 0);
  assert(strcmp(NeoPPSSPPRequiredOption("ppsspp", "ppsspp_backend"), "opengl") == 0);
  assert(NeoPPSSPPOptionIsAllowed("ppsspp", "ppsspp_cpu_core", "Interpreter"));
  assert(!NeoPPSSPPOptionIsAllowed("ppsspp", "ppsspp_cpu_core", "JIT"));
  assert(!NeoPPSSPPOptionIsAllowed("ppsspp", "ppsspp_cpu_core", "IR JIT"));
  assert(!NeoPPSSPPOptionIsAllowed("ppsspp", "ppsspp_cpu_core", nullptr));
  assert(NeoPPSSPPOptionIsAllowed("ppsspp", "ppsspp_backend", "opengl"));
  assert(!NeoPPSSPPOptionIsAllowed("ppsspp", "ppsspp_backend", "vulkan"));
  assert(!NeoPPSSPPOptionIsAllowed("ppsspp", "ppsspp_backend", "auto"));
  assert(NeoPPSSPPRequiredOption("snes9x", "ppsspp_cpu_core") == nullptr);
  assert(NeoPPSSPPOptionIsAllowed("snes9x", "ppsspp_cpu_core", "JIT"));
  assert(NeoPPSSPPOptionIsAllowed("ppsspp", "ppsspp_internal_resolution", "1"));
  assert(NeoPPSSPPRequiredOption(nullptr, "ppsspp_cpu_core") == nullptr);
  assert(NeoPPSSPPRequiredOption("ppsspp", nullptr) == nullptr);
  return 0;
}
