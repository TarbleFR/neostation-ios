// SPDX-License-Identifier: GPL-2.0-or-later
#pragma once

#include <algorithm>
#include <cstdint>
#include <limits>

namespace DolphinRecording {
// The writer uses CMTime(index, 50), not a floating-point accumulated clock.
// A blocked encoder never consumes an index, so backpressure cannot create
// holes or shorten a recording by squeezing later frames into earlier times.
class Timeline final {
 public:
  static constexpr int32_t Rate = 50;
  static constexpr int64_t TickNanoseconds = 1000000000LL / Rate;
  static constexpr unsigned BurstLimit = 4;

  int64_t nextIndex() const { return m_next; }
  int64_t nextNanoseconds() const { return m_next * TickNanoseconds; }
  bool due(int64_t horizonNanoseconds, bool inclusive = true) const {
    return horizonNanoseconds >= 0 &&
        (inclusive ? nextNanoseconds() <= horizonNanoseconds
                   : nextNanoseconds() < horizonNanoseconds);
  }
  void accepted() { ++m_next; }
  void reset() { m_next = 0; }

  // Zero-order hold: use the previous image until the new image's timestamp.
  // This drops 1 in 6 source frames at 60 Hz; it does not synthesize motion.
  bool useIncoming(int64_t incomingNanoseconds, bool hasPrevious) const {
    return !hasPrevious || nextNanoseconds() >= incomingNanoseconds;
  }

  static int64_t frameCountForDuration(int64_t durationNanoseconds) {
    if (durationNanoseconds <= 0) return 0;
    return durationNanoseconds / TickNanoseconds +
        (durationNanoseconds % TickNanoseconds != 0);
  }

  template <typename Append>
  unsigned drain(int64_t horizonNanoseconds, bool inclusive, Append append) {
    unsigned count = 0;
    while (count < BurstLimit && due(horizonNanoseconds, inclusive)) {
      if (!append(m_next)) break;
      accepted();
      ++count;
    }
    return count;
  }

 private:
  int64_t m_next = 0;
};
}  // namespace DolphinRecording
