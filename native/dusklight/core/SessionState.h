#pragma once

#include "DusklightCoreABI.h"

// All mutations are on the UIKit main thread, including stop from the close
// button and the timeout. Keep the initialized engine, not a nested game_main
// stack, between logical sessions. Fatal startup/runtime failures are terminal.
class NeoDusklightSessionState {
 public:
  bool reserve() {
    if (state_ != NEO_DUSKLIGHT_IDLE) return false;
    state_ = NEO_DUSKLIGHT_STARTING;
    return true;
  }
  bool enter() {
    if (state_ != NEO_DUSKLIGHT_STARTING || entered_) return false;
    entered_ = true;
    return true;
  }
  bool firstFrame() {
    if (!ready_ || state_ != NEO_DUSKLIGHT_STARTING) return false;
    state_ = NEO_DUSKLIGHT_RUNNING;
    return true;
  }
  void requestStop() {
    if (active()) state_ = NEO_DUSKLIGHT_STOPPING;
  }
  void initialized() { ready_ = true; }
  // Call only after leaving the frame callback and suspending input/audio.
  void finish() { state_ = entered_ && !ready_ ? NEO_DUSKLIGHT_ENDED : NEO_DUSKLIGHT_IDLE; }
  // Fatal teardown remains one-shot: process-lifetime game singletons are not
  // cold-reinitialized after a native failure.
  void terminate() { state_ = NEO_DUSKLIGHT_ENDED; }
  void fail() { state_ = NEO_DUSKLIGHT_ENDED; }
  bool active() const {
    return state_ == NEO_DUSKLIGHT_STARTING || state_ == NEO_DUSKLIGHT_RUNNING ||
           state_ == NEO_DUSKLIGHT_STOPPING;
  }
  bool entered() const { return entered_; }
  bool ready() const { return ready_; }
  int state() const { return state_; }

 private:
  int state_ = NEO_DUSKLIGHT_IDLE;
  bool entered_ = false;
  bool ready_ = false;
};
