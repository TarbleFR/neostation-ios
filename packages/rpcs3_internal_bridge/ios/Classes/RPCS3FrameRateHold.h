// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <cmath>
#include <cstdint>

// NEOSTATION_RPCS3_FPS_HOLD_V1: how constantly a session holds a frame-rate
// target, computed from the existing 1 Hz host samples (NeoSwapFPSValid gates
// them). Pure host arithmetic: no Core read, no timer, no emulation hot path.
// A sample holds the target when it lies within `tolerance` of it, so a
// limiter that settles at 29.6 fps still counts as 30. The summary reports the
// ratio, the number of samples below the target, the longest run below it (in
// samples, one per second) and their mean, which together say whether the
// session was "constant" rather than only "on average fast enough".
struct RPCS3FrameRateHold {
    double target = 30.0;
    double tolerance = 0.5;
    uint64_t samples = 0;
    uint64_t held = 0;
    uint64_t currentBelowRun = 0;
    uint64_t longestBelowRun = 0;
    double belowTotal = 0.0;

    void record(double fps) noexcept {
        if (!std::isfinite(fps) || fps < 0.0) return;
        ++samples;
        if (fps + tolerance >= target) {
            ++held;
            currentBelowRun = 0;
            return;
        }
        belowTotal += fps;
        if (++currentBelowRun > longestBelowRun) longestBelowRun = currentBelowRun;
    }
    uint64_t belowSamples() const noexcept { return samples - held; }
    double holdRatio() const noexcept {
        return samples ? static_cast<double>(held) / static_cast<double>(samples) : 0.0;
    }
    double belowMeanFps() const noexcept {
        const uint64_t below = belowSamples();
        return below ? belowTotal / static_cast<double>(below) : 0.0;
    }
    // True only when every valid sample held the target: the maintainer's
    // "constant" criterion, never an average.
    bool constant() const noexcept { return samples > 0 && held == samples; }
};
