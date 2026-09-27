#include "aurora.h"

#include <cstddef>
#include <cstdint>

static_assert(offsetof(AuroraConfig, maxTextureAnisotropy) == 40);
static_assert(sizeof(AuroraConfig{}.maxTextureAnisotropy) == sizeof(uint16_t));

int main() {
  AuroraConfig config{};
  return config.maxTextureAnisotropy == 0 ? 0 : 1;
}
