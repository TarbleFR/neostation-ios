#include "../ios/Classes/RetroArchRuntimePolicy.h"
#include "../ios/Classes/RetroArchMenuInput.h"
#include <cassert>
#include <iostream>

static const char* Identity() { return NEO_RETROARCH_RUNTIME_IDENTITY; }
static const char* WrongIdentity() { return "upstream-standalone-app"; }
static int Initialize(const NeoRetroArchPaths*, char*, size_t) { return 0; }
static void Callback(NeoRetroArchEventFn, void*) {}
static int Start(const NeoRetroArchLaunch*, char*, size_t) { return 0; }
static int Stop(uint64_t, char*, size_t) { return 0; }
static int Pause(uint64_t, int, char*, size_t) { return 0; }
static uint32_t State(uint64_t) { return NEO_RA_IDLE; }
static uint64_t Capabilities(uint64_t) { return 0; }
static int Command(uint64_t, const char*, char*, size_t, char*, size_t) { return 0; }

int main() {
  NeoRetroArchCoreAPI api = {NEO_RETROARCH_ABI_VERSION, sizeof(NeoRetroArchCoreAPI),
      Identity, Initialize, Callback, Start, Stop, Pause, State, Capabilities, Command};
  assert(NeoRetroArchValidateAPI(&api) == NEO_RA_API_VALID);
  assert(NeoRetroArchValidateAPI(nullptr) == NEO_RA_API_MISSING);
  api.abi_version++;
  assert(NeoRetroArchValidateAPI(&api) == NEO_RA_API_VERSION);
  api.abi_version = NEO_RETROARCH_ABI_VERSION;
  api.struct_size--;
  assert(NeoRetroArchValidateAPI(&api) == NEO_RA_API_VERSION);
  api.struct_size = sizeof(NeoRetroArchCoreAPI);
  api.command = nullptr;
  assert(NeoRetroArchValidateAPI(&api) == NEO_RA_API_INCOMPLETE);
  api.command = Command;
  api.runtime_identity = WrongIdentity;
  assert(NeoRetroArchValidateAPI(&api) == NEO_RA_API_IDENTITY);

  NeoRetroArchMenuInput input;
  constexpr uint16_t select = 1u << 2, start = 1u << 3, a = 1u << 8;
  uint16_t sample = a | select;
  assert(!input.consume(sample) && sample == (a | select));
  sample = a | select | start;
  assert(input.consume(sample) && sample == a);
  sample = select | start;
  assert(!input.consume(sample) && sample == 0);
  sample = select;
  assert(!input.consume(sample) && sample == 0);
  sample = select | start;
  assert(!input.consume(sample) && sample == 0); // Re-press one while held.
  sample = 0;
  assert(!input.consume(sample));
  sample = select | start;
  assert(input.consume(sample) && sample == 0);
  sample = select | start;
  assert(!input.consume(sample, false)); // Controller disconnect resets latch.
  sample = select | start;
  assert(input.consume(sample) && sample == 0);
  std::cout << "RetroArch runtime ABI and controller menu policy tests passed\n";
}
