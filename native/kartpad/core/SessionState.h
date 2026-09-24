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

  void finishRetained() {
    state_ = runtimeReady_ ? NEO_KARTPAD_IDLE : NEO_KARTPAD_ENDED;
    firstFrameSeen_ = false;
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
