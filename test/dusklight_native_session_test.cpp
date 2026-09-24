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

  // Initialize exactly once.
  assert(state.reserve());
  assert(state.enter());
  assert(!state.enter());
  assert(!state.firstFrame());
  state.initialized();
  assert(state.firstFrame());
  assert(!state.firstFrame());
  state.requestStop();
  assert(!state.firstFrame());
  assert(state.active());
  state.finish();
  assert(!state.active());
  assert(state.state() == NEO_DUSKLIGHT_IDLE);

  // Reuse the retained runtime repeatedly without entering game_main again.
  for (int repeat = 0; repeat < 100; ++repeat) {
    assert(state.reserve());
    assert(!state.reserve());
    assert(!state.enter());
    assert(state.state() == NEO_DUSKLIGHT_STARTING);
    assert(state.firstFrame());
    state.requestStop();
    assert(state.active());
    assert(!state.firstFrame());
    state.finish();
    assert(state.state() == NEO_DUSKLIGHT_IDLE);
  }

  // Cancel a resumed presentation before its first frame: still reusable.
  assert(state.reserve());
  state.requestStop();
  state.finish();
  assert(state.reserve());
  state.finish();
  assert(state.state() == NEO_DUSKLIGHT_IDLE);

  // A fatal runtime failure remains terminal.
  assert(state.reserve());
  assert(state.firstFrame());
  state.requestStop();
  state.terminate();
  assert(state.state() == NEO_DUSKLIGHT_ENDED);
  assert(!state.reserve());

  // An early startup failure after game_main entered is also terminal.
  NeoDusklightSessionState failed;
  assert(failed.reserve());
  assert(failed.enter());
  failed.finish();
  assert(!failed.reserve());
}
