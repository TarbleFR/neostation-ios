#include "DonorAudioSession.h"
#include <array>
#include <cassert>
#include <cstdio>

static unsigned destroyed = 0, quit = 0;
static void Destroy(void* stream) {
  assert(stream == reinterpret_cast<void*>(0x12345678));
  ++destroyed;
}
static void Quit(uint32_t subsystem) {
  assert(subsystem == 0x10);
  ++quit;
}
int main(int argc, char**) {
  std::array<uint8_t, 0xb0> backend;
  for (unsigned cycle = 0; cycle < 1000; ++cycle) {
    backend.fill(0xa5);
    void* stream = reinterpret_cast<void*>(0x12345678);
    std::memcpy(backend.data() + 0x40, &stream, sizeof(stream));
    const uint32_t rate = 32000, channels = 2;
    std::memcpy(backend.data() + 0x54, &rate, 4);
    std::memcpy(backend.data() + 0x58, &channels, 4);
    backend[0x5c] = 1;
    const auto before = backend;
    neokartpad::ReleaseDonorAudioSession(backend.data(), Destroy, Quit);
    for (size_t i = 0; i < backend.size(); ++i) {
      const bool reset = (i >= 0x40 && i < 0x48) || (i >= 0x54 && i <= 0x5c);
      assert(backend[i] == (reset ? 0 : before[i]));
    }
    neokartpad::ReleaseDonorAudioSession(backend.data(), Destroy, Quit);
    assert(destroyed == cycle + 1 && quit == cycle + 1);
  }
  // Feed actual production-helper output to the ARM64 donor regression.
  if (argc > 1) std::fwrite(backend.data(), 1, backend.size(), stdout);
  else std::puts("PASS: 1000 audio sessions, idempotent release, preferences and mutex preserved");
}
