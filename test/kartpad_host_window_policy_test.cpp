#include "KartPadHostWindowPolicy.h"

#include <cassert>
#include <vector>

using neokartpad::HostWindowCandidate;
using neokartpad::SelectHostWindow;

int main() {
  // Immediate relaunch after closing: SDL can still be the key window. The
  // actual Flutter owner wins without waiting for UIKit to reassign the key.
  const HostWindowCandidate donor{false, true, true, true, true};
  const HostWindowCandidate flutter{true, true, true, true, false};
  assert(SelectHostWindow({donor, flutter}) == 1);
  assert(SelectHostWindow({flutter, donor}) == 0);
  assert(SelectHostWindow({donor}) == -1);

  // The registrar can point at a detached/hidden prior scene. In that case a
  // visible Flutter root from the foreground scene is selected instead.
  const HostWindowCandidate detached{true, false, true, true, true};
  const HostWindowCandidate hidden{true, true, false, true, true};
  const HostWindowCandidate background{true, true, true, false, true};
  assert(SelectHostWindow({detached, donor, flutter}) == 2);
  assert(SelectHostWindow({hidden, background, flutter}) == 2);
  assert(SelectHostWindow({detached, hidden, background, donor}) == -1);

  // Once Flutter is visible again, repeated launch decisions have no sticky
  // state and select the same host even if the key designation changes.
  for (int cycle = 0; cycle < 100; ++cycle) {
    assert(SelectHostWindow({donor, flutter}) == 1);
    assert(SelectHostWindow({HostWindowCandidate{true, true, true, true, true}}) == 0);
  }
}
