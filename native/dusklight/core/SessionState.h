#pragma once

#include "DusklightCoreABI.h"

// All mutations are on the UIKit main thread, including stop from the close
// button and the timeout. The upstream game owns process-lifetime singletons:
// until they are made restartable, never enter game_main a second time.
class NeoDusklightSessionState {
 public:
  bool reserve() {
    if (state_ != NEO_DUSKLIGHT_IDLE || entered_) return false;
    state_ = NEO_DUSKLIGHT_STARTING;
    return true;
  }
  bool enter() {
    if (state_ != NEO_DUSKLIGHT_STARTING || entered_) return false;
    entered_ = true;
    return true;
  }
  bool firstFrame() {
    if (!entered_ || state_ != NEO_DUSKLIGHT_STARTING) return false;
    state_ = NEO_DUSKLIGHT_RUNNING;
    return true;
  }
  void requestStop() {
    if (active()) state_ = NEO_DUSKLIGHT_STOPPING;
  }
  void finish() { state_ = entered_ ? NEO_DUSKLIGHT_ENDED : NEO_DUSKLIGHT_IDLE; }
  bool active() const {
    return state_ == NEO_DUSKLIGHT_STARTING || state_ == NEO_DUSKLIGHT_RUNNING ||
           state_ == NEO_DUSKLIGHT_STOPPING;
  }
  bool entered() const { return entered_; }
  int state() const { return state_; }

 private:
  int state_ = NEO_DUSKLIGHT_IDLE;
  bool entered_ = false;
};
