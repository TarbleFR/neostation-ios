#pragma once

#include <stddef.h>
#include "Rpcs3CoreABI.h"

// NeoStation owns the embedded session menu. Keep the upstream PS bit in the
// immutable Core ABI, but consume it before sending this wrapper's input so
// it cannot also open the guest's native system menu.
class RPCS3EmbeddedMenuInput {
public:
  bool consume(rpcs3_ios_pad_state& state) noexcept {
    const uint64_t buttons = state.buttons;
    state.buttons &= ~uint64_t(rpcs3_ios_pad_ps);
    if (!state.connected) {
      reset();
      return false;
    }

    constexpr uint64_t chord = rpcs3_ios_pad_select | rpcs3_ios_pad_start;
    const bool homePressed = (buttons & rpcs3_ios_pad_ps) != 0;
    const bool chordPressed = (buttons & chord) == chord;
    const bool chordPartHeld = (buttons & chord) != 0;
    const bool requested = homePressed || chordPressed;
    const bool openMenu = requested && !menuHeld_;

    if (chordPressed) chordCaptured_ = true;
    // Keep both chord buttons consumed until both are released. Releasing one
    // first must neither deliver the remaining button to the game nor open the
    // menu again when the other is pressed a second time.
    if (chordCaptured_) state.buttons &= ~chord;
    if (requested) menuHeld_ = true;
    else if (!chordCaptured_ || !chordPartHeld) menuHeld_ = false;
    if (!chordPartHeld) chordCaptured_ = false;
    return openMenu;
  }

  void reset() noexcept {
    menuHeld_ = false;
    chordCaptured_ = false;
  }

private:
  bool menuHeld_ = false;
  bool chordCaptured_ = false;
};
