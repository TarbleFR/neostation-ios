#include "RPCS3EmbeddedMenuInput.h"

#include <cassert>
#include <utility>

int main() {
  RPCS3EmbeddedMenuInput policy;
  auto sample = [&](uint64_t buttons, bool connected = true) {
    rpcs3_ios_pad_state state = {};
    state.size = sizeof(state);
    state.connected = connected;
    state.buttons = buttons;
    state.left_x = -0.75f;
    state.right_y = 0.5f;
    state.l2 = 0.25f;
    const bool open = policy.consume(state);
    assert(state.size == sizeof(state));
    assert(state.connected == connected);
    assert(state.left_x == -0.75f && state.right_y == 0.5f && state.l2 == 0.25f);
    assert((state.buttons & rpcs3_ios_pad_ps) == 0);
    return std::pair{open, state.buttons};
  };

  constexpr uint64_t chord = rpcs3_ios_pad_select | rpcs3_ios_pad_start;
  constexpr uint64_t gameplay = rpcs3_ios_pad_cross | rpcs3_ios_pad_l2;
  auto first = sample(gameplay | rpcs3_ios_pad_ps);
  assert(first.first && first.second == gameplay);
  for (int i = 0; i < 100; ++i) {
    auto held = sample(gameplay | rpcs3_ios_pad_ps);
    assert(!held.first && held.second == gameplay);
  }
  assert(!sample(gameplay).first);
  assert(sample(rpcs3_ios_pad_ps).first);
  assert(!sample(0).first);

  // Start and Select retain their normal game meaning separately.
  auto start = sample(rpcs3_ios_pad_start | gameplay);
  assert(!start.first && start.second == (rpcs3_ios_pad_start | gameplay));
  auto select = sample(rpcs3_ios_pad_select | gameplay);
  assert(!select.first && select.second == (rpcs3_ios_pad_select | gameplay));

  auto combined = sample(chord | gameplay);
  assert(combined.first && combined.second == gameplay);
  for (int i = 0; i < 100; ++i) {
    auto held = sample(chord | gameplay);
    assert(!held.first && held.second == gameplay);
  }
  auto partial = sample(rpcs3_ios_pad_start | gameplay);
  assert(!partial.first && partial.second == gameplay);
  assert(!sample(chord).first); // No retrigger without fully releasing chord.
  partial = sample(rpcs3_ios_pad_select | gameplay);
  assert(!partial.first && partial.second == gameplay);
  assert(!sample(0).first);
  assert(sample(chord).first);

  // Home plus the chord is still one request, and replacing a held shortcut
  // with the other cannot stack a second menu.
  assert(!sample(chord | rpcs3_ios_pad_ps).first);
  assert(!sample(rpcs3_ios_pad_ps).first);
  assert(!sample(0).first);
  assert(sample(chord | rpcs3_ios_pad_ps).first);
  assert(!sample(chord).first);
  assert(!sample(0).first);

  // Disconnect/stop reset the edge gate for the next controller/session.
  assert(sample(rpcs3_ios_pad_ps).first);
  assert(!sample(rpcs3_ios_pad_ps, false).first);
  assert(sample(rpcs3_ios_pad_ps).first);
  policy.reset();
  assert(sample(chord).first);
}
