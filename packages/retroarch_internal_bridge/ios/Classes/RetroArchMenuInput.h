#pragma once
#include <stdint.h>

// libretro joypad SELECT/START assignments. Shared by Objective-C frontend
// drivers and C++ bridge tests; no UIKit or C++ dependency is required.
typedef struct NeoRetroArchMenuInputState {
  uint8_t captured;
} NeoRetroArchMenuInputState;

static inline void NeoRetroArchMenuInputReset(NeoRetroArchMenuInputState* state) {
  state->captured = 0;
}

static inline int NeoRetroArchMenuInputConsume(NeoRetroArchMenuInputState* state,
                                              uint16_t* buttons, int connected) {
  const uint16_t chord = (uint16_t)((1u << 2) | (1u << 3));
  if (!connected) { NeoRetroArchMenuInputReset(state); return 0; }
  const int chord_down = (*buttons & chord) == chord;
  const int any_held = (*buttons & chord) != 0;
  const int requested = chord_down && !state->captured;
  if (chord_down) state->captured = 1;
  if (state->captured) *buttons &= (uint16_t)~chord;
  // Releasing only one button must not deliver the other to the game or
  // reopen the menu when the released button is pressed again.
  if (!any_held) state->captured = 0;
  return requested;
}

#ifdef __cplusplus
class NeoRetroArchMenuInput {
 public:
  bool consume(uint16_t& buttons, bool connected = true) noexcept {
    return NeoRetroArchMenuInputConsume(&state_, &buttons, connected) != 0;
  }
  void reset() noexcept { NeoRetroArchMenuInputReset(&state_); }
 private:
  NeoRetroArchMenuInputState state_{};
};
#endif
