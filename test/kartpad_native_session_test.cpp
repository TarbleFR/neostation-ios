#include "SessionState.h"
#include "DonorDataLifecycle.h"
#include "WindowHandoff.h"
#include <cassert>
#include <initializer_list>
#include <vector>

int main() {
  struct Window { int id; bool hidden = false; bool visible = false; };
  Window host{1}, donor{2}, unrelated{3};
  std::vector<int> handoff;
  const auto hide = [&](Window* window) {
    handoff.push_back(-window->id);
    window->hidden = true;
  };
  const auto show = [&](Window* window) {
    handoff.push_back(window->id);
    window->visible = true;
  };
  neokartpad::RestoreOwnedWindow(&host, &donor, hide, show);
  assert((handoff == std::vector<int>{-2, 1}));
  assert(donor.hidden && host.visible && !host.hidden && !unrelated.hidden);
  handoff.clear();
  neokartpad::RestoreOwnedWindow(&host, &host, hide, show);
  assert((handoff == std::vector<int>{1}) && !host.hidden);
  handoff.clear();
  neokartpad::RestoreOwnedWindow(&host, static_cast<Window*>(nullptr), hide, show);
  assert((handoff == std::vector<int>{1}));

  // A clean guest reset must make the donor reload its initial DOL data on
  // every subsequent entry. Otherwise OS::__ThreadInit calls the cleared
  // switch-thread callback at guest 0x80385AE0.
  uint8_t donorDataInitialized = 0;
  uint32_t switchThreadCallback = 0;
  for (int cycle = 0; cycle < 1000; ++cycle) {
    if (!donorDataInitialized) {
      donorDataInitialized = 1;
      switchThreadCallback = 0x801A9514;
    }
    assert(switchThreadCallback != 0);
    switchThreadCallback = 0;  // Memory::Init will clear the guest region.
    assert(neokartpad::RearmDonorDataSections(&donorDataInitialized));
    assert(donorDataInitialized == 0);
  }
  assert(!neokartpad::RearmDonorDataSections(&donorDataInitialized));
  assert(!neokartpad::RearmDonorDataSections(nullptr));
  donorDataInitialized = 2;
  assert(!neokartpad::RearmDonorDataSections(&donorDataInitialized));

  NeoKartPadSessionState state;
  assert(state.state() == NEO_KARTPAD_IDLE);

  // A real launch requires runtimeReady before the first frame may promote
  // STARTING -> RUNNING.
  assert(state.reserve());
  assert(!state.firstFrame());
  assert(state.exitReasonAfterReturn(false, NEO_KARTPAD_EXIT_USER_RETURN) ==
         NEO_KARTPAD_EXIT_LAUNCH_FAILURE);
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

  for (int intent : {NEO_KARTPAD_EXIT_NONE, NEO_KARTPAD_EXIT_USER_RETURN,
                     NEO_KARTPAD_EXIT_LANGUAGE_RESTART}) {
    assert(state.exitReasonAfterReturn(false, intent) == NEO_KARTPAD_EXIT_RUNTIME_FAILURE);
    assert(state.exitReasonAfterReturn(true, intent) ==
           (intent == NEO_KARTPAD_EXIT_NONE ? NEO_KARTPAD_EXIT_NORMAL_TERMINATION : intent));
  }

  // ENDED remains reserved for a genuine unexpected native failure.
  state.requestStop();
  state.terminate();
  assert(state.state() == NEO_KARTPAD_ENDED);
  assert(!state.reserve());
}
