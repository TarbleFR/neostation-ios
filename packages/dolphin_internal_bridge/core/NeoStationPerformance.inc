// Thread-safe, passive telemetry for the optional in-game performance graph.
// SPDX-License-Identifier: GPL-2.0-or-later
#include <cmath>
#include "VideoCommon/PerformanceMetrics.h"

namespace
{
// Only the GPU thread publishes a successful EFB allocation. Readers never
// dereference a renderer, texture, or mutable VideoConfig from the host queue.
// Packing both dimensions into one atomic prevents a mixed old/new size.
std::atomic<uint64_t> g_performance_render_size{0};

id DOLPerformanceNumber(double value)
{
  return std::isfinite(value) && value >= 0 ? @(value) : [NSNull null];
}
}

extern "C" void neostation_dolphin_record_render_size(uint32_t width, uint32_t height)
{
  g_performance_render_size.store((uint64_t{width} << 32) | height,
                                  std::memory_order_relaxed);
}

extern "C" __attribute__((visibility("default")))
char* neostation_dolphin_performance_snapshot(void)
{
  // The bridge calls this on its serial runtime queue only while visible.
  // GetFPS/GetVPS/GetSpeed and the frame-time getters read upstream atomics.
  // Do not use CPUThreadGuard, GPU readback, or the host queue for telemetry.
  if (!g_initialized || !g_running || g_cleanup_started) return nullptr;
  @autoreleasepool {
    const auto size = g_performance_render_size.load(std::memory_order_relaxed);
    const auto timestamp = std::chrono::duration<double, std::milli>(
        std::chrono::steady_clock::now().time_since_epoch()).count();
    NSDictionary* snapshot = @{
      @"timestampMs": @(timestamp),
      @"fps": DOLPerformanceNumber(g_perf_metrics.GetFPS()),
      @"vps": DOLPerformanceNumber(g_perf_metrics.GetVPS()),
      @"speedPercent": DOLPerformanceNumber(g_perf_metrics.GetSpeed() * 100.0),
      @"frameTimeMs": DOLPerformanceNumber(g_perf_metrics.GetFrameTimeMs()),
      @"lastFrameTimeMs": DOLPerformanceNumber(g_perf_metrics.GetLastFrameTimeMs()),
      @"frameTimeStdMs": DOLPerformanceNumber(g_perf_metrics.GetFrameTimeStdMs()),
      @"renderWidth": @(static_cast<uint32_t>(size >> 32)),
      @"renderHeight": @(static_cast<uint32_t>(size)),
    };
    NSData* encoded = [NSJSONSerialization dataWithJSONObject:snapshot options:0 error:nil];
    NSString* json = encoded ? [[NSString alloc] initWithData:encoded encoding:NSUTF8StringEncoding] : nil;
    // Copy inside the pool: no borrowed Foundation object crosses the C ABI.
    return json.UTF8String ? strdup(json.UTF8String) : nullptr;
  }
}
