#!/usr/bin/env python3
"""Add low-overhead, device-side RPCS3 performance telemetry to the iOS host."""

from __future__ import annotations

from pathlib import Path


MARKER = "NEOSTATION_RPCS3_PERFORMANCE_TELEMETRY_V1"


def replace_once(text: str, old: str, new: str, description: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{description}: expected one source anchor, found {count}")
    return text.replace(old, new, 1)


def main() -> None:
    root = Path.cwd()
    plugin = root / "packages/rpcs3_internal_bridge/ios/Classes/Rpcs3InternalBridgePlugin.mm"
    diagnostics = root / "packages/rpcs3_internal_bridge/ios/Classes/Rpcs3Diagnostics.h"
    text = plugin.read_text()

    if MARKER not in text:
        text = replace_once(
            text,
            "#import <errno.h>\n#import <sys/mman.h>\n",
            "#import <errno.h>\n#import <os/proc.h>\n#import <sys/mman.h>\n",
            "os_proc include",
        )

        old_ivars = """  dispatch_queue_t _runtimeQueue;
  dispatch_source_t _performanceTimer;
  rpcs3_ios_api _api;
"""
        new_ivars = """  dispatch_queue_t _runtimeQueue;
  dispatch_source_t _performanceTimer;
  dispatch_source_t _diagnosticPerformanceTimer;
  uint64_t _diagnosticPerformanceSamples;
  double _diagnosticFpsTotal;
  double _diagnosticMinimumFps;
  uint64_t _diagnosticPeakMemory;
  uint64_t _diagnosticMinimumAvailableMemory;
  NSInteger _diagnosticWorstThermalState;
  rpcs3_ios_api _api;
"""
        text = replace_once(text, old_ivars, new_ivars, "telemetry state")

        method_anchor = """static void RPCS3CollectSavestate(void* context, const rpcs3_ios_savestate_info* info) {
"""
        methods = f"""// {MARKER}: one buffered sample per second, outside emulation hot paths.
- (void)startDiagnosticPerformanceSampling {{
  if (_diagnosticPerformanceTimer || !_api.get_performance_metrics || !self.activeTitleId.length) return;
  _diagnosticPerformanceSamples = 0;
  _diagnosticFpsTotal = 0.0;
  _diagnosticMinimumFps = 0.0;
  _diagnosticPeakMemory = 0;
  _diagnosticMinimumAvailableMemory = UINT64_MAX;
  _diagnosticWorstThermalState = NSProcessInfoThermalStateNominal;

  dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _runtimeQueue);
  _diagnosticPerformanceTimer = timer;
  dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),
                            NSEC_PER_SEC, (uint64_t)(0.1 * NSEC_PER_SEC));
  __weak Rpcs3InternalBridgePlugin* weakSelf = self;
  dispatch_source_set_event_handler(timer, ^{{
    Rpcs3InternalBridgePlugin* strongSelf = weakSelf;
    if (!strongSelf || !strongSelf.activeTitleId.length) return;
    rpcs3_ios_performance_metrics metrics = {{}};
    metrics.size = sizeof(metrics);
    if (strongSelf->_api.get_performance_metrics(&metrics) != 0) return;

    const NSInteger thermal = NSProcessInfo.processInfo.thermalState;
    const uint64_t availableMemory = os_proc_available_memory();
    strongSelf->_diagnosticWorstThermalState = MAX(strongSelf->_diagnosticWorstThermalState, thermal);
    strongSelf->_diagnosticMinimumAvailableMemory = MIN(strongSelf->_diagnosticMinimumAvailableMemory, availableMemory);
    if (metrics.valid_fields & rpcs3_ios_performance_memory) {{
      strongSelf->_diagnosticPeakMemory = MAX(strongSelf->_diagnosticPeakMemory, metrics.memory_used_bytes);
    }}
    if (metrics.valid_fields & rpcs3_ios_performance_fps) {{
      if (strongSelf->_diagnosticPerformanceSamples == 0 || metrics.frames_per_second < strongSelf->_diagnosticMinimumFps) {{
        strongSelf->_diagnosticMinimumFps = metrics.frames_per_second;
      }}
      strongSelf->_diagnosticFpsTotal += metrics.frames_per_second;
      strongSelf->_diagnosticPerformanceSamples++;
    }}

    RPCS3Diagnostic(@"performance_sample", [NSString stringWithFormat:
        @"title=%@ valid=0x%x fps=%.2f cpu=%.1f rsx=%.1f memory=%llu/%llu available=%llu thermal=%ld",
        strongSelf.activeTitleId, metrics.valid_fields, metrics.frames_per_second,
        metrics.cpu_usage_percent, metrics.gpu_usage_percent,
        (unsigned long long)metrics.memory_used_bytes,
        (unsigned long long)metrics.memory_total_bytes,
        (unsigned long long)availableMemory, (long)thermal]);
  }});
  dispatch_resume(timer);
}}

- (void)stopDiagnosticPerformanceSampling {{
  if (_diagnosticPerformanceTimer) {{
    dispatch_source_cancel(_diagnosticPerformanceTimer);
    _diagnosticPerformanceTimer = nil;
  }}
  if (_diagnosticPerformanceSamples > 0) {{
    const double average = _diagnosticFpsTotal / (double)_diagnosticPerformanceSamples;
    RPCS3Diagnostic(@"performance_summary", [NSString stringWithFormat:
        @"title=%@ samples=%llu average_fps=%.2f minimum_fps=%.2f peak_memory=%llu minimum_available=%llu worst_thermal=%ld",
        self.activeTitleId ?: @"", (unsigned long long)_diagnosticPerformanceSamples,
        average, _diagnosticMinimumFps, (unsigned long long)_diagnosticPeakMemory,
        (unsigned long long)(_diagnosticMinimumAvailableMemory == UINT64_MAX ? 0 : _diagnosticMinimumAvailableMemory),
        (long)_diagnosticWorstThermalState]);
  }}
  _diagnosticPerformanceSamples = 0;
}}

static void RPCS3CollectSavestate(void* context, const rpcs3_ios_savestate_info* info) {{
"""
        text = replace_once(text, method_anchor, methods, "telemetry methods")

        shutdown_anchor = """      if (self->_performanceTimer) { dispatch_source_cancel(self->_performanceTimer); self->_performanceTimer = nil; }
      if (self->_api.set_display_surface) self->_api.set_display_surface(NULL);
"""
        shutdown_patch = """      [self stopDiagnosticPerformanceSampling];
      if (self->_performanceTimer) { dispatch_source_cancel(self->_performanceTimer); self->_performanceTimer = nil; }
      if (self->_api.set_display_surface) self->_api.set_display_surface(NULL);
"""
        text = replace_once(text, shutdown_anchor, shutdown_patch, "shutdown telemetry stop")

        boot_anchor = """      NSDictionary* payload = [self statusPayload:bootStatus];
      if (bootStatus != 0) [self stopAndDismiss:nil];
      dispatch_async(dispatch_get_main_queue(), ^{ result(payload); });
"""
        boot_patch = """      NSDictionary* payload = [self statusPayload:bootStatus];
      if (bootStatus == 0) [self startDiagnosticPerformanceSampling];
      else [self stopAndDismiss:nil];
      dispatch_async(dispatch_get_main_queue(), ^{ result(payload); });
"""
        text = replace_once(text, boot_anchor, boot_patch, "boot telemetry start")

        stop_anchor = """    if (self->_performanceTimer) {
      dispatch_source_cancel(self->_performanceTimer);
      self->_performanceTimer = nil;
    }
    if (self.initialized && self->_api.set_display_surface) self->_api.set_display_surface(NULL);
"""
        stop_patch = """    [self stopDiagnosticPerformanceSampling];
    if (self->_performanceTimer) {
      dispatch_source_cancel(self->_performanceTimer);
      self->_performanceTimer = nil;
    }
    if (self.initialized && self->_api.set_display_surface) self->_api.set_display_surface(NULL);
"""
        text = replace_once(text, stop_anchor, stop_patch, "stop telemetry summary")
        plugin.write_text(text)

    diagnostic_text = diagnostics.read_text()
    if "dispatch_async(queue" in diagnostic_text and (
        "RPCS3-milestones.log" in diagnostic_text
        or "synchronizeFile" not in diagnostic_text
    ):
        # Build 280+ keeps ordinary diagnostics asynchronous. Build 283 adds a
        # separate, low-frequency durable milestone file; its synchronous flush
        # must not be mistaken for synchronous high-volume performance logging.
        pass
    else:
        buffered_old = """        if (![stage isEqualToString:@"core_log"]) {
"""
        buffered_new = """        if (![stage isEqualToString:@"core_log"] &&
            ![stage isEqualToString:@"performance_sample"]) {
"""
        if buffered_new not in diagnostic_text:
            diagnostics.write_text(
                replace_once(
                    diagnostic_text,
                    buffered_old,
                    buffered_new,
                    "buffered performance diagnostics",
                )
            )

    print("RPCS3 device performance telemetry patch: OK")


if __name__ == "__main__":
    main()
