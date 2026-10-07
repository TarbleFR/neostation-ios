#!/usr/bin/env python3
"""Exercise the host cache and prove that only one timer reads Core ABI 30."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
CLASSES = ROOT / "packages/rpcs3_internal_bridge/ios/Classes"
plugin = (CLASSES / "Rpcs3InternalBridgePlugin.mm").read_text()
overlay = plugin.split("- (void)setPerformanceSamplingEnabled:", 1)[1].split(
    "- (void)startDiagnosticPerformanceSampling", 1)[0]
producer = plugin.split("- (void)startDiagnosticPerformanceSampling", 1)[1].split(
    "- (void)stopDiagnosticPerformanceSampling", 1)[0]
assert "get_performance_metrics(&metrics)" not in overlay
assert plugin.count("get_performance_metrics(&metrics)") == 1
assert producer.count("get_performance_metrics(&metrics)") == 1
assert "_performanceSnapshot.read(" in overlay
assert "_performanceSnapshot.publish(epoch, metrics, metricStatus" in producer
assert "strongSelf->_performanceProducerGeneration != producerGeneration" in producer
assert "_performanceSnapshot.accepts(epoch)" in producer
assert "_performanceSnapshot.begin(_performanceEpoch)" in plugin
assert "_performanceSnapshot.end()" in plugin
assert 'fps=%@' in producer and '@"unavailable"' in producer
assert "strongSelf.gameController != sampledOwner" in overlay
assert "__weak RPCS3GameViewController* weakSampledOwner = self.gameController" in overlay
assert "RPCS3PerformanceSnapshot::afterDelay(" in overlay
assert "CACurrentMediaTime() * 1000.0 - timestamp" in overlay
main_apply = overlay.split("dispatch_async(dispatch_get_main_queue()", 1)[1]
# The first dispatch is a main-entry handoff for callers on other threads.
main_apply = overlay.split("RPCS3GameViewController* sampledOwner = weakSampledOwner", 1)[1]
assert "_performanceSnapshot.read(" not in main_apply
assert "_performanceDisplayEpoch.load(std::memory_order_acquire)" in main_apply
assert "appendNeoSwapWithClient:" in main_apply and "timestamp:timestamp" in main_apply
runtime_body = overlay.split("dispatch_async(_runtimeQueue", 1)[1].split(
    "dispatch_async(dispatch_get_main_queue()", 1)[0]
assert "gameController" not in runtime_body
assert "NSThread.isMainThread" in overlay.split("__weak RPCS3GameViewController*", 1)[0]

boot = plugin.split("- (rpcs3_ios_status)bootTitleForCore:", 1)[1].split(
    "static void RPCS3CollectSavestate", 1)[0]
assert "[self invalidatePerformanceSnapshotForBoot]" in boot
assert "if (status != 0) _performanceSnapshot.end()" in boot
assert plugin.count("_api.boot_game(") == 1
assert plugin.count("bootTitleForCore:titleId.UTF8String savestate:") == 8
assert plugin.count("bootTitleForCore:strongSelf.activeTitleId.UTF8String savestate:") == 1
for start, end in [("- (void)showLanguageMenu", "- (void)applyResolutionScale"),
                   ("- (void)applyResolutionScale", "- (void)showResolutionScaleMenu"),
                   ("- (void)applyStretchMode", "- (void)showStretchMenu"),
                   ("- (void)loadSavestateIdentifier", "- (void)showLoadSavestateMenu")]:
    assert "bootTitleForCore:" in plugin.split(start, 1)[1].split(end, 1)[0]
assert "NSEC_PER_SEC, (uint64_t)(0.1 * NSEC_PER_SEC)" in producer
assert "0.5 * NSEC_PER_SEC" in overlay
assert "NeoSwapFPSValid(metrics.frames_per_second, metrics.valid_fields)" in producer

# Guard the complete host surface against another ABI reader in a category or
# bridge helper. Declarations/loading the function pointer are not reads.
readers = []
for path in (ROOT / "packages/rpcs3_internal_bridge").rglob("*"):
    if path.suffix in (".mm", ".m", ".cpp", ".swift"):
        if "get_performance_metrics(&" in path.read_text():
            readers.append(path)
assert readers == [CLASSES / "Rpcs3InternalBridgePlugin.mm"], readers

# NEOSTATION_RPCS3_FPS_HOLD_V1: the summary measures the 30 fps target as a hold
# ratio and the longest run below it, from the same gated 1 Hz samples; the
# renderer's GPU/driver line is mirrored into the durable milestones.
summary = plugin.split("- (void)stopDiagnosticPerformanceSampling", 1)[1].split("_diagnosticPerformanceSamples = 0;", 1)[0]
assert "strongSelf->_diagnosticFrameRateHold.record(metrics.frames_per_second);" in producer
assert producer.index("NeoSwapFPSValid(metrics.frames_per_second, metrics.valid_fields)") < producer.index("_diagnosticFrameRateHold.record(")
assert "_diagnosticFrameRateHold = {};" in producer
for token in ("fps_target=%.0f", "fps_hold=%.1f%%", "below_target_samples=%llu",
              "longest_below_target_run_s=%llu", "below_target_mean_fps=%.2f", "constant=%d",
              "_diagnosticFrameRateHold.holdRatio() * 100.0", "_diagnosticFrameRateHold.longestBelowRun",
              "_diagnosticFrameRateHold.constant() ? 1 : 0"):
    assert token in summary, token
assert 'RPCS3Milestone(@"renderer_detected", [NSString stringWithUTF8String:message] ?: @"");' in plugin
log_handler = plugin.split("static void RPCS3Log(void* context, int32_t level, const char* message) {", 1)[1].split("RPCS3Diagnostic(@\"core_log\", text);", 1)[0]
assert 'strstr(message, "Found Vulkan-compatible GPU")' in log_handler
budget_filter = 'if (level > 2 && !profiler && !videoArchive) return;'
assert log_handler.index('renderer_detected') < log_handler.index(budget_filter)
# One-time boot facts survive the budget and the 2 MiB restart as milestones;
# the Core's SPUPROF/RANGELOCKPROF lines reach the diagnostic like COREPROF.
for marker, stage in (('"Resolved boot policy"', 'boot_policy'), ('"Applied iOS God of War III"', 'gow3_mlaa_bypass')):
    assert 'strstr(message, ' + marker + ')' in log_handler, marker
    assert log_handler.index(stage) < log_handler.index(budget_filter), stage
for marker in ('"SPUPROF "', '"RANGELOCKPROF "'):
    assert 'strstr(message, ' + marker + ') != nullptr' in log_handler.split('const BOOL profiler =', 1)[1].split(';', 1)[0], marker
boot_region = plugin.split('RPCS3Milestone(@"game_boot_begin", titleId);', 1)[1].split('RPCS3Milestone(@"game_boot_return"', 1)[0]
assert 'RPCS3Milestone(@"host_cpu_topology", RPCS3HostCPUTopology());' in boot_region
topology = plugin.split('static NSString* RPCS3HostCPUTopology(void) {', 1)[1].split('\n}\n', 1)[0]
for key in ('"hw.ncpu"', '"hw.nperflevels"', '"hw.perflevel0.logicalcpu"', '"hw.perflevel1.logicalcpu"', '"hw.memsize"'):
    assert key in topology, key
assert 'sysctlbyname' in topology and 'dispatch' not in topology
assert (CLASSES / "RPCS3FrameRateHold.h").read_text().count("double target = 30.0;") == 1

compiler = os.environ.get("CXX") or shutil.which("clang++") or shutil.which("g++")
assert compiler, "A C++ compiler is required for the behavioral regression"
with tempfile.TemporaryDirectory(prefix="rpcs3-snapshot-") as temporary:
    for source, name in (("test/rpcs3_performance_snapshot_test.cpp", "snapshot-test"),
                         ("test/rpcs3_frame_rate_hold_test.cpp", "frame-rate-hold-test")):
        binary = Path(temporary) / name
        subprocess.run([compiler, "-std=c++20", "-O1", "-g", "-Wall", "-Wextra", "-Werror",
                        "-fsanitize=address,undefined", "-I" + str(CLASSES),
                        str(ROOT / source), "-o", str(binary)], check=True)
        subprocess.run([str(binary)], check=True)
print("PASS: production bridge has one Core reader; 1Hz sampling and 0.5s overlay remain independent; 30 fps hold summary and renderer milestone verified")
