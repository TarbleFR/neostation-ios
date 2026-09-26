#pragma once

#include "KartPadCoreABI.h"

class NeoKartPadSessionState {
 public:
  bool reserve() {
    if (state_ != NEO_KARTPAD_IDLE) return false;
    state_ = NEO_KARTPAD_STARTING;
    firstFrameSeen_ = false;
    return true;
  }

  void runtimeReady() { runtimeReady_ = true; }

  bool firstFrame() {
    if (!runtimeReady_ || state_ != NEO_KARTPAD_STARTING || firstFrameSeen_)
      return false;
    firstFrameSeen_ = true;
    state_ = NEO_KARTPAD_RUNNING;
    return true;
  }

  void requestStop() {
    if (active()) state_ = NEO_KARTPAD_STOPPING;
  }

  void cancelStop() {
    if (state_ == NEO_KARTPAD_STOPPING)
      state_ = firstFrameSeen_ ? NEO_KARTPAD_RUNNING : NEO_KARTPAD_STARTING;
  }

  void finishRetained() {
    state_ = runtimeReady_ ? NEO_KARTPAD_IDLE : NEO_KARTPAD_ENDED;
    firstFrameSeen_ = false;
  }

  // A normal embedded shutdown must return to a fully reusable idle state.
  // The next Start() is a brand-new KartPad session, not a resume of stale
  // guest/runtime state from the previous launch.
  void finishReusable() {
    state_ = NEO_KARTPAD_IDLE;
    runtimeReady_ = false;
    firstFrameSeen_ = false;
  }

  int exitReasonAfterReturn(bool orderly, int requested) const {
    if (!orderly) {
      // A requested close/restart is intent, never proof of successful cleanup.
      return firstFrameSeen_ ? NEO_KARTPAD_EXIT_RUNTIME_FAILURE
                             : NEO_KARTPAD_EXIT_LAUNCH_FAILURE;
    }
    return requested == NEO_KARTPAD_EXIT_NONE
        ? NEO_KARTPAD_EXIT_NORMAL_TERMINATION : requested;
  }

  void terminate() { state_ = NEO_KARTPAD_ENDED; }

  bool active() const {
    return state_ == NEO_KARTPAD_STARTING ||
           state_ == NEO_KARTPAD_RUNNING ||
           state_ == NEO_KARTPAD_STOPPING;
  }

  bool runtimeReadyFlag() const { return runtimeReady_; }
  int state() const { return state_; }

 private:
  int state_ = NEO_KARTPAD_IDLE;
  bool runtimeReady_ = false;
  bool firstFrameSeen_ = false;
};
