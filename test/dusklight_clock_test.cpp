#include "time_internal.hpp"
#include <cassert>
#include <chrono>

using namespace aurora::time;
using namespace aurora::time::internal;
static native_clock::time_point now;
static native_clock::time_point testNow() noexcept { return now; }

int main() {
  using namespace std::chrono_literals;
  set_now_function(testNow);
  set_scale(2.0f);
  for (int session = 0; session < 100; ++session) {
    now += 1s;
    const auto before = game_clock::now();
    set_pause_reason(PauseReason::Host, true);
    now += 1h;
    assert(game_clock::now() == before);
    set_pause_reason(PauseReason::Background, true);
    set_pause_reason(PauseReason::Host, false);
    now += 1h;
    assert(game_clock::now() == before); // One owner cannot unpause another.
    set_pause_reason(PauseReason::Background, false);
    assert(scale() == 2.0f);
    now += 1s;
    assert(game_clock::now() - before == 2s);
  }
  set_now_function(nullptr);
}
