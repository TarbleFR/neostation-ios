// Behavioral regression for NEOSTATION_RPCS3_FPS_HOLD_V1 (host-side 30 fps hold).
#include "RPCS3FrameRateHold.h"
#include <cassert>
#include <cmath>
#include <cstdio>
#include <initializer_list>

int main() {
  RPCS3FrameRateHold hold;
  assert(hold.samples == 0 && !hold.constant() && hold.holdRatio() == 0.0 && hold.belowMeanFps() == 0.0);
  // A session that stays at the target is constant; the tolerance accepts a
  // limiter that settles just under 30.
  for (double fps : {30.0, 29.5, 31.2, 60.0, 29.51}) hold.record(fps);
  assert(hold.samples == 5 && hold.held == 5 && hold.constant() && hold.belowSamples() == 0);
  assert(hold.holdRatio() == 1.0 && hold.longestBelowRun == 0);
  // 29.49 is below the tolerance: the session is no longer constant.
  hold.record(29.49);
  assert(!hold.constant() && hold.belowSamples() == 1 && hold.longestBelowRun == 1);
  // Runs below the target are measured in consecutive samples; recovery resets
  // the current run but keeps the longest one.
  for (double fps : {10.0, 5.0, 12.0}) hold.record(fps);
  assert(hold.longestBelowRun == 4 && hold.belowSamples() == 4);
  hold.record(30.0);
  assert(hold.currentBelowRun == 0 && hold.longestBelowRun == 4);
  hold.record(20.0);
  assert(hold.currentBelowRun == 1 && hold.longestBelowRun == 4 && hold.belowSamples() == 5);
  assert(std::fabs(hold.belowMeanFps() - (29.49 + 10.0 + 5.0 + 12.0 + 20.0) / 5.0) < 1e-9);
  assert(std::fabs(hold.holdRatio() - 6.0 / 11.0) < 1e-12);
  // Invalid samples are ignored, as the sampler already gates them.
  hold.record(NAN); hold.record(INFINITY); hold.record(-1.0);
  assert(hold.samples == 11);
  // A zero fps sample is a valid stalled frame and counts below the target.
  hold.record(0.0);
  assert(hold.samples == 12 && hold.belowSamples() == 6 && hold.currentBelowRun == 2);
  // The target is a parameter: a 60 fps target judges the same samples differently.
  RPCS3FrameRateHold sixty; sixty.target = 60.0;
  sixty.record(59.6); sixty.record(55.0);
  assert(sixty.held == 1 && sixty.belowSamples() == 1 && !sixty.constant());
  std::puts("PASS: fps hold ratio, tolerance boundary, longest below-target run, below-target mean, invalid sample rejection and target parameter verified");
  return 0;
}
