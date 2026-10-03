#pragma once
#include <cstddef>
#include "Rpcs3CoreABI.h"
#include <cmath>
#include <cstdint>
#include <limits>

// Core ABI 30's metrics getter advances one GLOBAL frame/time baseline.
// Only the session's diagnostic timer may call it. UI readers use this cache
// without advancing that baseline or estimating/clamping a frame rate.
class RPCS3PerformanceSnapshot final {
public:
  enum class State { inactive, priming, ready, failed, expired };
  struct View {
    rpcs3_ios_performance_metrics metrics{};
    State state = State::inactive;
    rpcs3_ios_status status = 0;
    uint64_t epoch = 0;
    double ageMs = 0;
  };
  // All operations belong to the host's serial runtime queue.
  void begin(uint64_t epoch) noexcept {
    epoch_ = epoch;
    active_ = epoch != 0;
    hasSnapshot_ = false;
    status_ = 0;
    timestampMs_ = 0;
    metrics_ = unavailable();
  }
  void end() noexcept {
    active_ = false;
    hasSnapshot_ = false;
    metrics_ = unavailable();
  }
  bool accepts(uint64_t epoch) const noexcept {
    return active_ && epoch && epoch == epoch_;
  }
  bool publish(uint64_t epoch, const rpcs3_ios_performance_metrics& metrics,
               rpcs3_ios_status status, double timestampMs) noexcept {
    if (!accepts(epoch) || !std::isfinite(timestampMs)) return false;
    status_ = status;
    timestampMs_ = timestampMs;
    metrics_ = status == 0 ? metrics : unavailable();
    hasSnapshot_ = true;
    return true;
  }
  View read(uint64_t epoch, double nowMs) const noexcept {
    View view{unavailable(), State::inactive, status_, epoch_, 0};
    if (!active_ || !epoch || epoch != epoch_) return view;
    view.state = State::priming;
    if (!hasSnapshot_) return view;
    view.ageMs = nowMs - timestampMs_;
    if (!std::isfinite(nowMs) || view.ageMs < 0 || view.ageMs > maximumAgeMs) {
      view.state = State::expired;
      return view;
    }
    if (status_ != 0) {
      view.state = State::failed;
      return view;
    }
    view.metrics = metrics_; // Keep Core validity bits, including priming FPS.
    view.state = State::ready;
    return view;
  }
  // A main-queue callback may wait after read(). Revalidate its copied FPS
  // descriptor with elapsed monotonic time; never read the runtime cache from
  // the UI thread. Other fields remain the historical sample, and the memory
  // graph has its own captured timestamp/ownership checks.
  static View afterDelay(View view, double elapsedMs) noexcept {
    if (view.state != State::ready) return view;
    if (!std::isfinite(elapsedMs) || elapsedMs < 0 ||
        !std::isfinite(view.ageMs + elapsedMs) ||
        view.ageMs + elapsedMs > maximumAgeMs) {
      view.metrics.valid_fields &= ~rpcs3_ios_performance_fps;
      view.state = State::expired;
    }
    view.ageMs += elapsedMs;
    return view;
  }
  static constexpr double maximumAgeMs = 2000.0;
private:
  static rpcs3_ios_performance_metrics unavailable() noexcept {
    rpcs3_ios_performance_metrics metrics{};
    metrics.size = sizeof(metrics);
    metrics.frames_per_second = std::numeric_limits<double>::quiet_NaN();
    metrics.cpu_usage_percent = std::numeric_limits<double>::quiet_NaN();
    metrics.gpu_usage_percent = std::numeric_limits<double>::quiet_NaN();
    return metrics;
  }
  uint64_t epoch_ = 0;
  bool active_ = false, hasSnapshot_ = false;
  rpcs3_ios_status status_ = 0;
  double timestampMs_ = 0;
  rpcs3_ios_performance_metrics metrics_ = unavailable();
};
