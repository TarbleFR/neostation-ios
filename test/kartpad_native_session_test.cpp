#include "SessionState.h"
#include <cassert>

int main() {
  NeoKartPadSessionState state;
  assert(state.state() == NEO_KARTPAD_IDLE);

  // A real launch requires runtimeReady before the first frame may promote
  // STARTING -> RUNNING.
  assert(state.reserve());
  assert(!state.firstFrame());
  state.runtimeReady();
  assert(state.firstFrame());
  assert(state.state() == NEO_KARTPAD_RUNNING);

  // Reproduce the required NeoStation -> KartPad -> NeoStation lifecycle many
  // times. An orderly shutdown must become a completely reusable IDLE state,
  // not the old terminal ENDED state.
  for (int cycle = 0; cycle < 1000; ++cycle) {
    state.requestStop();
    assert(state.state() == NEO_KARTPAD_STOPPING);
    state.finishReusable();
    assert(state.state() == NEO_KARTPAD_IDLE);
    assert(!state.runtimeReadyFlag());

    assert(state.reserve());
    assert(state.state() == NEO_KARTPAD_STARTING);
    assert(!state.firstFrame());
    state.runtimeReady();
    assert(state.firstFrame());
    assert(state.state() == NEO_KARTPAD_RUNNING);
  }

  // Failed/aborted shutdown may recover to the live session.
  state.requestStop();
  state.cancelStop();
  assert(state.state() == NEO_KARTPAD_RUNNING);

  // ENDED remains reserved for a genuine unexpected native failure.
  state.requestStop();
  state.terminate();
  assert(state.state() == NEO_KARTPAD_ENDED);
  assert(!state.reserve());
}
