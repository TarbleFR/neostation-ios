#pragma once

#include "DusklightCoreABI.h"

// All mutations are on the UIKit main thread, including stop from the close
// button and the timeout. A successfully initialized engine is terminal after
// stop: its process-lifetime singletons cannot be initialized a second time.
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
  // Cancellation before game_main entered remains retryable.
  void finish() { state_ = entered_ && !ready_ ? NEO_DUSKLIGHT_ENDED : NEO_DUSKLIGHT_IDLE; }
  // Call only after the complete native shutdown barrier returned.
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
