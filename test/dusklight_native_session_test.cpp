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
  assert(state.firstFrame());
  assert(!state.firstFrame());
  state.requestStop();
  assert(!state.firstFrame());
  assert(state.active()); // Do not release host ownership before native cleanup.
  state.finish();
  assert(!state.active());
  assert(state.state() == NEO_DUSKLIGHT_ENDED);
  assert(!state.reserve()); // Process-lifetime game singletons cannot be reset yet.

  NeoDusklightSessionState failed;
  assert(failed.reserve());
  assert(failed.enter());
  failed.finish(); // An early startup failure also consumes the unsafe singleton entry.
  assert(!failed.reserve());
}
