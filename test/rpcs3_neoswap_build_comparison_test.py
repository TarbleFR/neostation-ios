#!/usr/bin/env python3
"""Behavioral evidence checks; all numbers below are synthetic test fixtures."""

import copy
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
TOOL = ROOT / "tools/compare_rpcs3_neoswap_builds.py"
SPEC = importlib.util.spec_from_file_location("rpcs3_neoswap_comparison", TOOL)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def fixture(source="a" * 40, pid=123):
    info = {"sourceCommit": source, "pid": pid, "sessionSequence": 1, "bootTimestamp": 100,
            "title": "BCES00510", "workloadId": "save-fixture-route-10s", "deviceId": "fixture-device",
            "settingsId": "fixture-settings"}
    memory = []
    for index, timestamp in enumerate((100, 105, 110)):
        memory.append({
            "pid": pid, "timestamp": timestamp,
            "event": ("rpcs3_memory_session_start", "sample", "rpcs3_memory_session_end")[index],
            "memoryProfile": {"sessionSequence": 1, "sampledSessionActive": index != 2},
            "experiment": {"sourceCommit": source, "mode": "integrated", "valid": True},
            "physicalMemoryBytes": 8 << 30, "osVersion": "fixture-ios", "processResidentBytes": 200 + index,
            "processFootprintBytes": 100 + index, "processAvailableBytes": 500 - index,
            "donationPreparedBytes": 1024, "neoswapContribution": {
                "donorLoanLiveBytes": 10 * index, "relayGuestLiveBytes": 30,
                "relayHostLoanLiveBytes": 20 - 5 * index},
            "cpuBufferExperiment": {"fallbackCount": 100 + index},
            "fastAllocation": {"requests": 10 + 2 * index, "successes": 5 + index,
                "broker_busy": index, "donor_busy": 0, "ready_misses": 0, "fallback_count": 5 + index,
                "total_time_us": 100 + 8 * index, "max_time_us": 50, "prepare_requests": index,
                "prepared_loans": index, "prepare_failures": 0},
            "donationPreparation": {"mode": ("warming", "relay-only", "donors-partial")[index],
                "campaign": 1, "readinessTimedOut": index == 1},
        })
    def diag(timestamp, stage, message):
        return {"pid": pid, "timestamp": timestamp, "stage": stage, "message": message}
    diagnostics = [diag(100, "game_boot_begin", "BCES00510")]
    for index, timestamp in enumerate((104, 109)):
        diagnostics.extend([
            diag(timestamp, "core_log", "SPUPROF session=7 loading_attempts=2 loading_failures=0 "
                 "loading_total_ms=20 loading_max_ms=15 gameplay_attempts=1 gameplay_failures=0 "
                 "gameplay_total_ms=3 gameplay_max_ms=3 warm_reuses=10 warm_recompile_attempts=0"),
            diag(timestamp, "core_log", "RANGELOCKPROF session=7 episodes=2 total_ms=4 max_ms=3 "
                 "iterations_max=10 blocker_samples=3 blocker_max=2"),
            diag(timestamp, "core_log", "COREPROF frames=10 range_wait_ms=0.25 range_stalls=50 "
                 "frametime_ms=33 p95_ms=40"),
            diag(timestamp, "core_log", "COREPROF_RESILIENCE spu_compile_ms=23"),
            diag(timestamp, "performance_sample", f"title=BCES00510 valid=0x1 fps={index * 20} sample_epoch=1"),
        ])
    return info, memory, diagnostics


class ComparisonTest(unittest.TestCase):
    def test_observed_metrics_respect_units_and_semantics(self):
        info, memory, diagnostics = fixture()
        report = MODULE.measure(info, memory, diagnostics)
        value = lambda key: report["metrics"][key]["value"]
        self.assertEqual(value("spu_loading_total_ms"), 40)
        self.assertEqual(value("spu_loading_max_ms"), 15)
        self.assertEqual(value("spu_gameplay_total_ms"), 6)
        self.assertEqual(value("spu_warmed_heavy_recompiles"), 0)
        self.assertEqual(value("range_lock_wait_iterations"), 100)
        self.assertEqual(value("range_lock_legacy_total_ms"), 5)
        self.assertEqual(value("range_lock_legacy_max_window_ms"), 2.5)
        self.assertEqual(value("range_lock_episodes"), 4)
        self.assertEqual(value("range_lock_episode_total_ms"), 8)
        self.assertEqual(value("range_lock_episode_max_ms"), 3)
        self.assertEqual(value("sampled_fps_mean"), 10)
        self.assertEqual(value("sampled_fps_min"), 0)
        self.assertEqual(value("native_frame_worst_window_p95_ms"), 40)
        self.assertIsNone(value("session_frame_p95_ms"))
        # Max of simultaneous disjoint values, NOT sum of unrelated high-water marks.
        self.assertEqual(value("neoswap_live_backing_peak_bytes"), 60)
        self.assertEqual(value("cpu_buffer_fallbacks"), 2)
        self.assertEqual(value("fast_acquisition_requests"), 4)
        self.assertEqual(value("fast_acquisition_total_time_us"), 16)
        self.assertEqual(value("fast_acquisition_mean_us"), 4)
        self.assertIsNone(value("neoswap_usable_capacity_bytes"))
        self.assertIsNone(value("neoswap_fault_latency_ms"))
        self.assertIsNone(value("neoswap_fallback_latency_ms"))
        self.assertTrue(report["donorPreparation"]["readinessTimedOut"])
        self.assertIn("relay-only", report["donorPreparation"]["modesObserved"])

    def test_before_after_different_revisions_allowed_and_not_device_validation(self):
        before = MODULE.measure(*fixture())
        after = MODULE.measure(*fixture("b" * 40, 456))
        report = MODULE.compare(before, after)
        self.assertFalse(report["deviceValidationPassed"])
        self.assertFalse(report["automaticPromotionAllowed"])
        self.assertEqual(report["afterMinusBefore"]["spu_gameplay_total_ms"], 0)
        self.assertIsNone(report["afterMinusBefore"]["neoswap_fault_latency_ms"])
        for key in ("title", "workloadId", "deviceId", "settingsId", "physicalMemoryBytes", "osVersion"):
            with self.subTest(key=key):
                bad = copy.deepcopy(after)
                bad["identity"][key] = "unrelated"
                with self.assertRaisesRegex(ValueError, key):
                    MODULE.compare(before, bad)

    def test_missing_and_partial_telemetry_is_not_zero(self):
        info, memory, diagnostics = fixture()
        legacy = [row for row in diagnostics if "SPUPROF" not in row["message"] and
                  "RANGELOCKPROF" not in row["message"] and "COREPROF " not in row["message"]]
        for row in memory:
            del row["fastAllocation"]
            del row["neoswapContribution"]
            row["donationPreparedBytes"] = 8 << 30
        result = MODULE.measure(info, memory, legacy)
        for key in ("spu_gameplay_total_ms", "range_lock_episode_total_ms", "native_frame_window_mean_ms",
                    "fast_acquisition_requests", "neoswap_live_backing_peak_bytes"):
            self.assertIsNone(result["metrics"][key]["value"], key)
            self.assertTrue(result["metrics"][key]["reason"], key)
        self.assertEqual(result["metrics"]["legacy_spu_compile_observed_ms"]["value"], 46)
        self.assertEqual(result["metrics"]["sampled_fps_mean"]["value"], 10)
        # One incomplete new window invalidates its affected total.
        diagnostics[-5]["message"] = diagnostics[-5]["message"].replace("gameplay_total_ms=3", "")
        result = MODULE.measure(info, memory, diagnostics)
        self.assertIsNone(result["metrics"]["spu_gameplay_total_ms"]["value"])

    def test_reused_sessions_mixed_titles_commits_and_epochs_rejected(self):
        def rejected(change):
            args = fixture()
            change(*args)
            with self.assertRaises(ValueError):
                MODULE.measure(*args)
        rejected(lambda i, m, d: m.append(dict(m[0], timestamp=1000)))
        rejected(lambda i, m, d: m.pop())
        rejected(lambda i, m, d: m[1]["experiment"].update(sourceCommit="b" * 40))
        rejected(lambda i, m, d: d.append(dict(d[0], timestamp=106)))
        rejected(lambda i, m, d: d[-1].update(message="title=OTHER0001 valid=1 fps=30"))
        rejected(lambda i, m, d: d[-1].update(message=d[-1]["message"].replace("sample_epoch=1", "sample_epoch=2")))
        rejected(lambda i, m, d: d[-5].update(message=d[-5]["message"].replace("session=7", "session=8")))
        rejected(lambda i, m, d: d[-4].update(message=d[-4]["message"].replace("session=7", "session=8")))
        rejected(lambda i, m, d: m[1]["fastAllocation"].update(requests=1))
        rejected(lambda i, m, d: m[1]["cpuBufferExperiment"].update(fallbackCount=1))

    def test_manifest_sha_not_in_log_is_explicitly_unverified(self):
        info, memory, diagnostics = fixture()
        for row in memory:
            del row["experiment"]["sourceCommit"]
        self.assertEqual(MODULE.measure(info, memory, diagnostics)["sourceCommitEvidence"], "manifest_only")

    def test_cli_hashes_inputs_deduplicates_rotation_and_writes_valid_json_table(self):
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            for name, args in (("before", fixture()), ("after", fixture("b" * 40, 456))):
                info, memory, diagnostics = args
                for kind, records in (("memory", memory), ("rpcs3", diagnostics)):
                    (directory / f"{name}-{kind}.jsonl").write_text("".join(json.dumps(row) + "\n" for row in records))
                info.update(memoryLogs=[f"{name}-memory.jsonl", f"{name}-memory.jsonl"],
                            rpcs3Logs=[f"{name}-rpcs3.jsonl"])
                (directory / f"{name}.json").write_text(json.dumps(info))
            subprocess.run([sys.executable, str(TOOL), "--before", str(directory / "before.json"),
                "--after", str(directory / "after.json"), "--output", str(directory / "report.json"),
                "--markdown", str(directory / "report.md")], check=True, capture_output=True, text=True)
            result = json.loads((directory / "report.json").read_text())
            self.assertEqual(result["before"]["observations"]["memory"], 3)
            self.assertEqual(len(result["before"]["inputs"][0]["sha256"]), 64)
            self.assertIn("| Metric | Unit | Before | After | Change |", (directory / "report.md").read_text())
            (directory / "bad.jsonl").write_text('{"timestamp":1}\n{')
            with self.assertRaisesRegex(ValueError, "incomplete/invalid JSONL"):
                MODULE.read_logs([directory / "bad.jsonl"])


if __name__ == "__main__":
    unittest.main()
