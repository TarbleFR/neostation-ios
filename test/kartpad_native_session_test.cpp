#include "SessionState.h"
#include <cassert>

int main() {
  NeoKartPadSessionState state;
  assert(state.state() == NEO_KARTPAD_IDLE);
  assert(state.reserve());
  state.runtimeReady();
  assert(state.firstFrame());
  assert(state.state() == NEO_KARTPAD_RUNNING);

  for (int cycle = 0; cycle < 100; ++cycle) {
    state.requestStop();
    assert(state.state() == NEO_KARTPAD_STOPPING);
    state.finishRetained();
    assert(state.state() == NEO_KARTPAD_IDLE);
    assert(state.reserve());
    assert(state.firstFrame());
    assert(state.state() == NEO_KARTPAD_RUNNING);
  }

  state.requestStop();
  state.terminate();
  assert(state.state() == NEO_KARTPAD_ENDED);
  assert(!state.reserve());
}
