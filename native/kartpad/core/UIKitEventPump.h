#pragma once
#include <cstdint>
#include <cstring>
#include <dlfcn.h>
#include <pthread.h>

namespace neokartpad {

// A guest fiber is on the UIKit THREAD but not on its pthread STACK. Flutter
// callbacks must not run there. Bounds are consumed by the checked donor gate;
// no instructions are written and no Flutter-private lifecycle API is used.
struct UIKitEventPump {
  uintptr_t lower = 0;
  uintptr_t upper = 0;
  uint64_t* counts = nullptr;
  void (*pump)() = nullptr;

  bool onHostStack() const {
    const uintptr_t here = reinterpret_cast<uintptr_t>(&here);
    return lower <= here && here < upper && pthread_main_np();
  }

  bool bind(void* runtime) {
    if (!pthread_main_np()) return false;
    void* entry = dlsym(runtime, "UIKit_PumpEvents");
    Dl_info image{};
    if (!entry || !dladdr(entry, &image) || !image.dli_fbase) return false;
    auto* base = static_cast<uint8_t*>(image.dli_fbase);
    constexpr char marker[] = "NEOKARTPAD-UIKIT-STACK-v1";
    constexpr uint8_t branch[] = {0xb8,0x98,0xf4,0x16};
    constexpr uint8_t gate[] = {
      0x30,0x9a,0x02,0xd0,0x11,0xd2,0x47,0xf9,0x51,0x01,0x00,0xb4,
      0xe8,0x03,0x00,0x91,0x1f,0x01,0x11,0xeb,0x23,0x01,0x00,0x54,
      0x11,0xd6,0x47,0xf9,0x1f,0x01,0x11,0xeb,0xc2,0x00,0x00,0x54,
      0x11,0xde,0x47,0xf9,0x31,0x06,0x00,0x91,0x11,0xde,0x07,0xf9,
      0xc8,0x8c,0x02,0xb0,0x3c,0x67,0x0b,0x15,0x11,0xda,0x47,0xf9,
      0x31,0x06,0x00,0x91,0x11,0xda,0x07,0xf9,0xc0,0x03,0x5f,0xd6,
    };
    if (entry != base + 0x42e2f20 ||
        std::memcmp(entry, branch, sizeof(branch)) ||
        std::memcmp(base + 0x9200, gate, sizeof(gate)) ||
        std::memcmp(base + 0x9300, marker, sizeof(marker))) return false;
    pump = reinterpret_cast<void (*)()>(dlsym(runtime, "SDL_PumpEvents"));
    upper = reinterpret_cast<uintptr_t>(pthread_get_stackaddr_np(pthread_self()));
    const auto size = pthread_get_stacksize_np(pthread_self());
    if (!pump || !size || size > upper) return false;
    lower = upper - size;
    if (!onHostStack()) return false;
    auto* control = reinterpret_cast<uint64_t*>(base + 0x534ff80);
    control[4] = lower;
    control[5] = upper;
    control[6] = control[7] = 0;
    counts = control + 6;
    return true;
  }

  void pumpFromHostStack() const {
    if (pump && onHostStack()) pump();
  }
};

} // namespace neokartpad
