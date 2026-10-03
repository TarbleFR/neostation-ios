#include "RPCS3PerformanceSnapshot.h"
#include <cassert>
#include <cmath>
#include <iostream>

// Same shared-baseline frame/time calculation as ABI 30's actual
// RPCS3IOSPerformance.cpp snapshot(), not a fake independent-reader counter.
struct CoreBaseline {
  uint64_t calls = 0, frames = 0;
  double time = 0;
  bool primed = false;
  rpcs3_ios_performance_metrics snapshot(uint64_t currentFrames, double now) {
    ++calls;
    rpcs3_ios_performance_metrics metrics{};
    metrics.size = sizeof(metrics);
    metrics.valid_fields = rpcs3_ios_performance_cpu | rpcs3_ios_performance_memory;
    if (primed && now > time && now - time <= 2.0 && currentFrames >= frames) {
      metrics.frames_per_second = static_cast<double>(currentFrames - frames) / (now - time);
      metrics.valid_fields |= rpcs3_ios_performance_fps;
    }
    primed = true;
    frames = currentFrames;
    time = now;
    return metrics;
  }
};

int main() {
  CoreBaseline old;
  old.snapshot(60, 1.0);
  const auto spike = old.snapshot(61, 1.0 + 1.0 / 7396.01);
  assert(std::abs(spike.frames_per_second - 7396.01) < 0.001);
  assert(old.snapshot(61, 1.001).frames_per_second == 0);

  RPCS3PerformanceSnapshot cache;
  CoreBaseline core;
  cache.begin(1);
  auto read = cache.read(1, 0);
  assert(read.state == RPCS3PerformanceSnapshot::State::priming);
  assert(read.metrics.valid_fields == 0 && std::isnan(read.metrics.frames_per_second));
  assert(cache.publish(1, core.snapshot(60, 1), 0, 1000));
  read = cache.read(1, 1000.1); // Overlay starts between diagnostic ticks.
  assert(!(read.metrics.valid_fields & rpcs3_ios_performance_fps));
  assert(read.metrics.valid_fields & rpcs3_ios_performance_cpu);
  for (double now : {1000.135, 1000.270, 1500.0, 1999.0}) {
    (void)cache.read(1, now); // Overlay/diagnostic readers never touch Core.
    assert(core.calls == 1);
  }
  assert(cache.publish(1, core.snapshot(120, 2), 0, 2000));
  for (double now : {2000.0, 2000.135, 2000.270, 2500.0}) {
    read = cache.read(1, now);
    assert(read.metrics.valid_fields & rpcs3_ios_performance_fps);
    assert(read.metrics.frames_per_second == 60);
    assert(core.calls == 2);
  }
  // Stopping/restarting UI readers has no effect on the sole producer.
  assert(cache.publish(1, core.snapshot(180, 3), 0, 3000));
  assert(cache.read(1, 3500).metrics.frames_per_second == 60);
  // The sample was fresh on the runtime queue, but the main queue can be
  // delayed. Apply only pure copied-data age arithmetic on the UI thread.
  auto queued = cache.read(1, 3500); // Already 500ms old when queued.
  queued.metrics.memory_used_bytes = 123456;
  queued.metrics.memory_total_bytes = 987654;
  auto delayed = RPCS3PerformanceSnapshot::afterDelay(queued, 1500);
  assert(delayed.metrics.valid_fields & rpcs3_ios_performance_fps); // Exactly2s.
  delayed = RPCS3PerformanceSnapshot::afterDelay(queued, 1500.001);
  assert(delayed.state == RPCS3PerformanceSnapshot::State::expired);
  assert(!(delayed.metrics.valid_fields & rpcs3_ios_performance_fps));
  assert(delayed.metrics.frames_per_second == 60); // No clamp/zero substitution.
  assert(delayed.metrics.valid_fields & rpcs3_ios_performance_memory);
  assert(delayed.metrics.memory_used_bytes == 123456 && delayed.metrics.memory_total_bytes == 987654);
  assert(delayed.epoch == queued.epoch && delayed.status == queued.status);
  assert(cache.read(1, 3501).metrics.valid_fields & rpcs3_ios_performance_fps); // Cache unchanged.
  for (double delay : {-1.0, static_cast<double>(NAN), static_cast<double>(INFINITY)}) {
    assert(!(RPCS3PerformanceSnapshot::afterDelay(queued, delay).metrics.valid_fields &
             rpcs3_ios_performance_fps));
  }
  // A genuine full sampling interval without a frame is a valid zero.
  assert(cache.publish(1, core.snapshot(180, 4), 0, 4000));
  read = cache.read(1, 4500);
  assert(read.metrics.valid_fields & rpcs3_ios_performance_fps);
  assert(read.metrics.frames_per_second == 0);
  assert(RPCS3PerformanceSnapshot::afterDelay(read, 1000).metrics.valid_fields & rpcs3_ios_performance_fps);
  assert(RPCS3PerformanceSnapshot::afterDelay(read, 1000).metrics.frames_per_second == 0);
  assert(!(RPCS3PerformanceSnapshot::afterDelay(read, 1500.001).metrics.valid_fields &
           rpcs3_ios_performance_fps));
  assert(cache.read(1, 6000).metrics.valid_fields & rpcs3_ios_performance_fps);
  read = cache.read(1, 6000.001);
  assert(read.state == RPCS3PerformanceSnapshot::State::expired);
  assert(read.metrics.valid_fields == 0 && std::isnan(read.metrics.frames_per_second));
  assert(cache.read(1, 3999).state == RPCS3PerformanceSnapshot::State::expired);
  assert(cache.read(1, NAN).state == RPCS3PerformanceSnapshot::State::expired);

  // Preserve actual API failures; never label them as a zero-FPS sample.
  assert(cache.publish(1, {}, -5, 7000));
  read = cache.read(1, 7001);
  assert(read.status == -5 && read.state == RPCS3PerformanceSnapshot::State::failed);
  assert(read.metrics.valid_fields == 0 && std::isnan(read.metrics.frames_per_second));
  cache.end();
  assert(cache.read(1, 7002).state == RPCS3PerformanceSnapshot::State::inactive);
  assert(!cache.publish(1, spike, 0, 7002));

  // Relaunch in the SAME host PID still gets a new epoch and fresh priming.
  cache.begin(2);
  core = {};
  assert(!cache.publish(1, spike, 0, 8000)); // Late old-session callback.
  assert(cache.read(1, 8000).metrics.valid_fields == 0);
  assert(cache.publish(2, core.snapshot(10, 8), 0, 8000));
  assert(!(cache.read(2, 8001).metrics.valid_fields & rpcs3_ios_performance_fps));
  assert(cache.publish(2, core.snapshot(40, 9), 0, 9000));
  assert(cache.read(2, 9001).metrics.frames_per_second == 30);
  // A Core counter reset is unavailable until its next valid interval.
  assert(cache.publish(2, core.snapshot(1, 10), 0, 10000));
  assert(!(cache.read(2, 10001).metrics.valid_fields & rpcs3_ios_performance_fps));
  assert(cache.publish(2, core.snapshot(31, 11), 0, 11000));
  assert(cache.read(2, 11001).metrics.frames_per_second == 30);
  // No invented ceiling: a valid synthetic rate is passed through exactly.
  auto fast = core.snapshot(271, 12);
  assert(cache.publish(2, fast, 0, 12000));
  assert(cache.read(2, 12001).metrics.frames_per_second == 240);
  CoreBaseline rollover;
  rollover.snapshot(UINT64_MAX - 1, 13);
  assert(cache.publish(2, rollover.snapshot(1, 14), 0, 14000));
  assert(!(cache.read(2, 14001).metrics.valid_fields & rpcs3_ios_performance_fps));
  assert(cache.publish(2, rollover.snapshot(61, 15), 0, 15000));
  assert(cache.read(2, 15001).metrics.frames_per_second == 60);
  // Core's own too-long interval invalidity is also retained, not zero-filled.
  assert(cache.publish(2, rollover.snapshot(121, 18), 0, 18000));
  assert(!(cache.read(2, 18001).metrics.valid_fields & rpcs3_ios_performance_fps));
  assert(cache.publish(2, rollover.snapshot(181, 19), 0, 19000));
  assert(cache.read(2, 19001).metrics.frames_per_second == 60);
  cache.begin(0); // No session/PID identity is an unavailable descriptor.
  assert(!cache.publish(0, fast, 0, 19002));
  assert(cache.read(0, 19002).metrics.valid_fields == 0);
  std::cout << "PASS: shared-baseline spike reproduced; one producer, close readers, priming, stop/start, real zero, stale/error, relaunch and rollover validity\n";
}
