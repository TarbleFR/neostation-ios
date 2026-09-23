#include "SessionState.h"
#include <cassert>

int main() {
  NeoDusklightSessionState state;
  assert(!state.active());
  assert(!state.firstFrame());
  // Cancel before the runtime enters: retry remains possible.
  assert(state.reserve());
  assert(!state.reserve());
  state.requestStop();
  assert(!state.enter());
  assert(!state.firstFrame());
  state.finish();
  assert(state.state() == NEO_DUSKLIGHT_IDLE);
  assert(state.reserve());
  assert(state.enter());
  assert(!state.enter());
  assert(!state.firstFrame());
  state.initialized();
  assert(state.firstFrame());
  assert(!state.firstFrame());
  state.requestStop();
  assert(!state.firstFrame());
  assert(state.active()); // Do not release host ownership before native cleanup.
  state.finish();
  assert(!state.active());
  assert(state.state() == NEO_DUSKLIGHT_IDLE);
  // Reuse the runtime, but require a fresh frame and new session ownership.
  for (int repeat = 0; repeat < 100; ++repeat) {
    assert(state.reserve());
    assert(!state.reserve());
    assert(!state.enter()); // game_main must never run twice.
    assert(state.state() == NEO_DUSKLIGHT_STARTING);
    assert(state.firstFrame());
    state.requestStop();
    assert(state.active());
    assert(!state.firstFrame()); // Late frame after stop cannot report success.
    state.finish();
    assert(state.state() == NEO_DUSKLIGHT_IDLE);
  }
  // Cancel a resumed session before its timer/frame: still reusable.
  assert(state.reserve());
  state.requestStop();
  state.finish();
  assert(state.reserve());
  state.fail();
  assert(!state.reserve());

  NeoDusklightSessionState failed;
  assert(failed.reserve());
  assert(failed.enter());
  failed.finish(); // An early startup failure also consumes the unsafe singleton entry.
  assert(!failed.reserve());
}
