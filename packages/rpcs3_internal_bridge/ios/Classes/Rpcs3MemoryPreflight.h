#pragma once

#ifdef __cplusplus
#include <array>
#include <cstddef>
#include <cstdint>
#include <sys/mman.h>

namespace neostation::rpcs3 {

// RPCS3 v0.8.1 reserves these regions in vm.cpp's static constructors, during
// dlopen, before its C API can return an error. A one-page JIT probe does not
// prove that the host can address this layout. Match VMLayoutPolicy.h's iOS
// 8 + 12 + 4 GiB reservations without touching pages or replacing any mapping.
template <class Map, class Unmap>
bool probe_virtual_layout(Map map, Unmap unmap) {
  static_assert(sizeof(void*) == 8);
  constexpr std::uintptr_t gib = UINT64_C(1) << 30;
  constexpr std::array<std::size_t, 3> sizes = {8 * gib, 12 * gib, 4 * gib};
  std::array<void*, 3> regions{};
  std::uintptr_t previous = 8 * gib;
  bool success = true;
  for (std::size_t i = 0; i < sizes.size(); ++i) {
    // Bound failure on a host without extended virtual addressing. RPCS3's
    // constructor otherwise scans up to 128 TiB and then throws from dlopen.
    for (auto address = previous + 4 * gib;
         address + sizes[i] <= 128 * gib; address += 4 * gib) {
      void* requested = reinterpret_cast<void*>(address);
      void* mapped = map(requested, sizes[i]);
      if (mapped == MAP_FAILED) continue;
      if (mapped != requested) {
        unmap(mapped, sizes[i]);
        continue;
      }
      regions[i] = mapped;
      previous = address + (i == 0 ? 4 * gib : 0);
      break;
    }
    if (!regions[i]) {
      success = false;
      break;
    }
  }
  for (std::size_t i = 0; i < sizes.size(); ++i) {
    if (regions[i]) unmap(regions[i], sizes[i]);
  }
  return success;
}

inline bool probe_virtual_layout() {
  return probe_virtual_layout(
      [](void* address, std::size_t size) {
        return mmap(address, size, PROT_READ | PROT_WRITE,
                    MAP_PRIVATE | MAP_ANON, -1, 0);
      },
      [](void* address, std::size_t size) { munmap(address, size); });
}

}  // namespace neostation::rpcs3
#endif
