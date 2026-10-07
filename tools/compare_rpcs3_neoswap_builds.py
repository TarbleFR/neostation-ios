#!/usr/bin/env python3
"""Compare two identified RPCS3/NeoSwap captures from different builds.

Each --before/--after JSON manifest names sourceCommit (full git SHA), pid,
sessionSequence, bootTimestamp (exact game_boot_begin timestamp), title,
workloadId (save/route/duration), deviceId, settingsId, memoryLogs and rpcs3Logs.
Log paths are relative to the manifest. Workload/device/settings must match.
The source SHA may differ, unlike compare_neoswap_sessions.py's mode experiment.

Only complete, unambiguous memory sessions are accepted. Missing instrumentation
is null with a reason, never a zero. All totals cover observed log windows, not
an assertion of gap-free capture or device validation. COREPROF window p95 is
not a session p95; sampled FPS is never inverted to invent frame times.
"""

import argparse
import hashlib
import json
import math
from pathlib import Path
import re
import statistics


PAIR = re.compile(r"\b([A-Za-z][A-Za-z0-9_]*)=([^\s]+)")
IDENTITY = ("sourceCommit", "pid", "sessionSequence", "bootTimestamp", "title",
            "workloadId", "deviceId", "settingsId")


def number(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


def numeric(value):
    try:
        result = float(value)
    except (ValueError, TypeError):
        return None
    return result if number(result) else None


def field(record, path):
    for key in path.split("."):
        record = record.get(key) if isinstance(record, dict) else None
    return record


def read_logs(paths):
    """Deduplicate overlap in rotated exports, retaining file hashes as evidence."""
    unique, evidence = {}, []
    for path in paths:
        data = Path(path).read_bytes()
        evidence.append({"path": str(path), "sha256": hashlib.sha256(data).hexdigest()})
        for index, line in enumerate(data.decode("utf-8").splitlines(), 1):
            if not line.strip():
                continue
            try:
                row = json.loads(line)
            except json.JSONDecodeError as error:
                raise ValueError(f"{path}:{index}: incomplete/invalid JSONL") from error
            if not isinstance(row, dict) or not number(row.get("timestamp")):
                raise ValueError(f"{path}:{index}: record requires a finite timestamp")
            unique[json.dumps(row, sort_keys=True)] = row
    return sorted(unique.values(), key=lambda row: row["timestamp"]), evidence


def manifest(path):
    result = json.loads(path.read_text())
    for key in IDENTITY:
        if key not in result or result[key] is None or result[key] == "":
            raise ValueError(f"{path}: missing identity {key}")
    if not re.fullmatch(r"[0-9a-f]{40}", result["sourceCommit"]):
        raise ValueError("sourceCommit must be a full lowercase Git SHA")
    for key in ("pid", "sessionSequence"):
        if not isinstance(result[key], int) or isinstance(result[key], bool) or result[key] <= 0:
            raise ValueError(f"Invalid {key}")
    if not number(result["bootTimestamp"]):
        raise ValueError("bootTimestamp must be numeric")
    for key in ("memoryLogs", "rpcs3Logs"):
        if not isinstance(result.get(key), list) or not result[key]:
            raise ValueError(f"{path}: {key} must name at least one log")
        result[key] = [path.parent / value for value in result[key]]
    return result


def select_session(info, memory, diagnostics):
    rows = [row for row in memory if row.get("pid") == info["pid"] and
            field(row, "memoryProfile.sessionSequence") == info["sessionSequence"]]
    starts = [row for row in rows if row.get("event") == "rpcs3_memory_session_start"]
    ends = [row for row in rows if row.get("event") == "rpcs3_memory_session_end"]
    if len(starts) != 1 or len(ends) != 1:
        raise ValueError("Need one complete memory session; missing/reused PID or session sequence")
    begin, end = starts[0]["timestamp"], ends[0]["timestamp"]
    if begin >= end or any(not begin <= row["timestamp"] <= end for row in rows):
        raise ValueError("Memory rows extend outside the selected session")
    boot = info["bootTimestamp"]
    # Memory polling records session activation independently of the boot queue.
    # A large offset is ambiguous and must not silently bind an unrelated boot.
    if abs(begin - boot) > 10 or boot >= end:
        raise ValueError("Memory session cannot be bound to the selected boot timestamp")
    selected = [row for row in diagnostics if row.get("pid") == info["pid"] and
                min(begin, boot) <= row["timestamp"] <= end]
    boots = [row for row in selected if row.get("stage") == "game_boot_begin"]
    if len(boots) != 1 or boots[0]["timestamp"] != boot or boots[0].get("message") != info["title"]:
        raise ValueError("Need exactly the selected title/boot; mixed launches are not comparable")
    epochs, commits, profiles = set(), set(), set()
    for row in rows:
        source = field(row, "experiment.sourceCommit")
        if source:
            commits.add(source)
        profile = row.get("experiment", {})
        profiles.add(json.dumps(profile, sort_keys=True))
    if len(profiles) > 1 or (commits and commits != {info["sourceCommit"]}):
        raise ValueError("Mixed source commits or experiment profiles in one memory session")
    for row in selected:
        values = dict(PAIR.findall(str(row.get("message", ""))))
        if "title" in values and values["title"] != info["title"]:
            raise ValueError("Diagnostic title differs from selected workload")
        if row.get("stage") == "performance_sample" and values.get("title") != info["title"]:
            raise ValueError("Performance sample requires an explicit matching title")
        if row.get("stage") == "performance_sample" and "sample_epoch" in values:
            epochs.add(values["sample_epoch"])
    if len(epochs) > 1:
        raise ValueError("Performance epoch reset/relaunch inside selected session")
    for key in ("physicalMemoryBytes", "osVersion"):
        observed = {row[key] for row in rows if row.get(key) is not None}
        if len(observed) > 1:
            raise ValueError(f"Mixed memory capture identity: {key}")
    return rows, selected, bool(commits)


def profile_rows(diagnostics, marker):
    result = []
    for row in diagnostics:
        message = str(row.get("message", ""))
        if row.get("stage") == "core_log" and re.search(r"\b" + marker + r" ", message):
            values = {key: numeric(value) for key, value in PAIR.findall(message)}
            result.append(values)
    return result


def measure(info, memory, diagnostics):
    rows, diagnostics, commit_verified = select_session(info, memory, diagnostics)
    metrics = {}

    def put(key, value, unit, source, reason="measurement_not_recorded"):
        metrics[key] = {"value": value, "unit": unit, "source": source,
                        "reason": reason if value is None else None}

    def aggregate(key, records, path, operation, unit, source):
        values = [field(row, path) for row in records]
        valid = bool(values) and all(number(value) and value >= 0 for value in values)
        put(key, operation(values) if valid else None, unit, source,
            "missing_or_invalid_field_in_observed_records")

    def delta(key, path, unit):
        values = [field(row, path) for row in rows]
        if not values or any(not number(value) or value < 0 for value in values):
            put(key, None, unit, path, "counter_not_recorded_in_all_session_samples")
        elif any(current < prior for prior, current in zip(values, values[1:])):
            raise ValueError(f"Cumulative counter reset within session: {path}")
        else:
            put(key, values[-1] - values[0], unit, path)

    spu = profile_rows(diagnostics, "SPUPROF")
    epochs = {row.get("session") for row in spu}
    if spu and (None in epochs or len(epochs) != 1):
        raise ValueError("SPUPROF needs one reset epoch; cannot combine reboots")
    for phase in ("loading", "gameplay"):
        for suffix, operation, unit in (("attempts", sum, "count"), ("failures", sum, "count"),
                                         ("total_ms", sum, "ms"), ("max_ms", max, "ms")):
            aggregate(f"spu_{phase}_{suffix}", spu, f"{phase}_{suffix}", operation, unit,
                      "SPUPROF interval counters; observed windows")
    aggregate("spu_warm_reuses", spu, "warm_reuses", sum, "count", "SPUPROF")
    aggregate("spu_warmed_heavy_recompiles", spu, "warm_recompile_attempts", sum, "count", "SPUPROF")
    warmup = profile_rows(diagnostics, "SPUWARMUP end")
    aggregate("spu_warmup_elapsed_ms", warmup, "elapsed_ms", sum, "ms", "completed SPUWARMUP end records")
    aggregate("spu_warmup_failed_runs", warmup, "failed", sum, "count", "SPUWARMUP end")
    aggregate("spu_warmup_stopped_runs", warmup, "stopped", sum, "count", "SPUWARMUP end")
    aggregate("spu_warmup_analyzer_mismatches", warmup, "analyzer_mismatches", sum, "count", "SPUWARMUP end")
    resilience = profile_rows(diagnostics, "COREPROF_RESILIENCE")
    aggregate("legacy_spu_compile_observed_ms", resilience, "spu_compile_ms", sum, "ms",
              "COREPROF_RESILIENCE unclassified loading/gameplay windows")

    core = profile_rows(diagnostics, "COREPROF")
    aggregate("range_lock_wait_iterations", core, "range_stalls", sum, "count",
              "COREPROF polling iterations, not independent contention episodes")
    if core and all(number(row.get("frames")) and row["frames"] > 0 and
                    number(row.get("range_wait_ms")) and row["range_wait_ms"] >= 0 for row in core):
        waits = [row["range_wait_ms"] * row["frames"] for row in core]
        put("range_lock_legacy_total_ms", sum(waits), "ms", "COREPROF range_wait_ms * frames")
        put("range_lock_legacy_max_window_ms", max(waits), "ms", "COREPROF range_wait_ms * frames")
    else:
        put("range_lock_legacy_total_ms", None, "ms", "COREPROF", "native_range_lock_windows_missing")
        put("range_lock_legacy_max_window_ms", None, "ms", "COREPROF", "native_range_lock_windows_missing")
    ranges = profile_rows(diagnostics, "RANGELOCKPROF")
    range_epochs = {row.get("session") for row in ranges}
    if ranges and (None in range_epochs or len(range_epochs) != 1 or (epochs and range_epochs != epochs)):
        raise ValueError("RANGELOCKPROF/SPUPROF reset epochs disagree")
    for key, path, operation, unit in (
        ("range_lock_episodes", "episodes", sum, "count"),
        ("range_lock_episode_total_ms", "total_ms", sum, "ms"),
        ("range_lock_episode_max_ms", "max_ms", max, "ms"),
        ("range_lock_episode_max_iterations", "iterations_max", max, "count"),
        ("range_lock_blocker_samples", "blocker_samples", sum, "count"),
        ("range_lock_max_blockers", "blocker_max", max, "count"),
    ):
        aggregate(key, ranges, path, operation, unit, "RANGELOCKPROF observed windows")
    # Native window summaries are valid observations but do not retain the
    # underlying distribution needed to reconstruct session percentiles.
    aggregate("native_frame_window_mean_ms", core, "frametime_ms", statistics.mean, "ms",
              "unweighted mean of native COREPROF window means")
    aggregate("native_frame_worst_window_p95_ms", core, "p95_ms", max, "ms", "COREPROF window p95")
    put("session_frame_p95_ms", None, "ms", "none", "raw_frame_intervals_not_exported")
    samples = []
    for row in diagnostics:
        if row.get("stage") != "performance_sample":
            continue
        values = dict(PAIR.findall(str(row.get("message", ""))))
        try:
            valid = int(values.get("valid", "0"), 0) & 1
        except ValueError:
            valid = False
        fps = numeric(values.get("fps"))
        if valid and fps is not None and fps >= 0:
            samples.append({"fps": fps})
    aggregate("sampled_fps_mean", samples, "fps", statistics.mean, "fps", "valid performance_sample FPS")
    aggregate("sampled_fps_min", samples, "fps", min, "fps", "valid performance_sample FPS")

    for key, path, operation in (
        ("process_resident_peak_bytes", "processResidentBytes", max),
        ("process_footprint_peak_bytes", "processFootprintBytes", max),
        ("process_available_min_bytes", "processAvailableBytes", min),
        ("donor_prepared_peak_bytes", "donationPreparedBytes", max),
        ("donor_live_loan_peak_bytes", "neoswapContribution.donorLoanLiveBytes", max),
        ("relay_guest_live_peak_bytes", "neoswapContribution.relayGuestLiveBytes", max),
        ("relay_host_live_peak_bytes", "neoswapContribution.relayHostLoanLiveBytes", max),
    ):
        aggregate(key, rows, path, operation, "bytes", path)
    backing = []
    for row in rows:
        values = [field(row, "neoswapContribution." + name) for name in
                  ("donorLoanLiveBytes", "relayGuestLiveBytes", "relayHostLoanLiveBytes")]
        backing.append({"live": sum(values) if all(number(v) and v >= 0 for v in values) else None})
    aggregate("neoswap_live_backing_peak_bytes", backing, "live", max, "bytes",
              "simultaneous disjoint donor loans + guest relay + host relay; not resident RAM/capacity")
    put("neoswap_usable_capacity_bytes", None, "bytes", "none",
        "live_mappings_and_preparation_do_not_establish_additional_usable_capacity_under_gameplay_pressure")
    put("neoswap_fault_latency_ms", None, "ms", "none", "per_fault_duration_not_exported")
    put("neoswap_fallback_latency_ms", None, "ms", "none", "fallback_duration_not_exported")
    delta("cpu_buffer_fallbacks", "cpuBufferExperiment.fallbackCount", "count")
    for key in ("requests", "successes", "broker_busy", "donor_busy", "ready_misses", "fallback_count",
                "total_time_us", "prepare_requests", "prepared_loans", "prepare_failures"):
        delta("fast_acquisition_" + key, "fastAllocation." + key, "us" if key.endswith("_us") else "count")
    aggregate("fast_acquisition_process_lifetime_max_us", rows, "fastAllocation.max_time_us", max,
              "us", "process-lifetime high-water mark; may predate this session")
    requests = metrics["fast_acquisition_requests"]["value"]
    total_time = metrics["fast_acquisition_total_time_us"]["value"]
    put("fast_acquisition_mean_us", total_time / requests if requests and total_time is not None else None,
        "us", "delta acquisition total_time_us / delta requests; includes refusals",
        "no_measured_requests_or_acquisition_counters_missing")
    preparation = [row["donationPreparation"] for row in rows if isinstance(row.get("donationPreparation"), dict)]
    warmup = {"modesObserved": sorted({row["mode"] for row in preparation if isinstance(row.get("mode"), str)}),
              "readinessTimedOut": any(row.get("readinessTimedOut") is True for row in preparation) if preparation else None,
              "campaignsObserved": sorted({row["campaign"] for row in preparation if number(row.get("campaign"))}),
              "meaning": "Prepared capacity and relay backend readiness do not prove gameplay memory benefit."}
    identity = {key: info[key] for key in IDENTITY}
    for key in ("physicalMemoryBytes", "osVersion"):
        identity[key] = next((row[key] for row in rows if row.get(key) is not None), None)
    return {"identity": identity, "sourceCommitEvidence": "log_and_manifest" if commit_verified else "manifest_only",
            "durationSeconds": rows[-1]["timestamp"] - info["bootTimestamp"],
            "observations": {"memory": len(rows), "spuWindows": len(spu), "coreWindows": len(core),
                             "rangeWindows": len(ranges), "fpsSamples": len(samples)},
            "donorPreparation": warmup, "metrics": metrics}


def compare(before, after):
    for key in ("title", "workloadId", "deviceId", "settingsId", "physicalMemoryBytes", "osVersion"):
        old, new = before["identity"][key], after["identity"][key]
        if old is None or old != new:
            raise ValueError(f"Incompatible comparison identity: {key}")
    changes = {}
    for key, old in before["metrics"].items():
        new = after["metrics"][key]
        changes[key] = new["value"] - old["value"] if number(old["value"]) and number(new["value"]) else None
    return {"schema": 1, "before": before, "after": after, "afterMinusBefore": changes,
            "deviceValidationPassed": False, "automaticPromotionAllowed": False,
            "limitations": [
                "Workload/device/settings identities are operator attestations; source SHA is log-verified only where recorded.",
                "Observed log-window totals may omit initial/final partial windows or dropped messages.",
                "Cumulative counter deltas cover the first-to-last memory sample; process lifetime maxima can predate the boot.",
                "Loading SPU classification denotes startup compile scope, not the first playable frame.",
                "Range-lock waits are guest VM contention; NeoSwap acquisition latency is a separate measurement.",
                "Resident bytes, process footprint, prepared capacity and shared live backing must not be added as physical RAM.",
                "No 50 s / 8.8 s / 118 ms / million-block baseline is assumed without identified source logs.",
            ]}


def markdown(report):
    lines = ["RPCS3 + NeoSwap — observed before/after measurements", "",
             f"Before: `{report['before']['identity']['sourceCommit']}`",
             f"After: `{report['after']['identity']['sourceCommit']}`", "",
             "| Metric | Unit | Before | After | Change |", "|---|---|---:|---:|---:|"]
    for key, old in report["before"]["metrics"].items():
        new = report["after"]["metrics"][key]
        display = lambda value: "unavailable" if value is None else f"{value:.3f}" if isinstance(value, float) else str(value)
        lines.append(f"| {key} | {old['unit']} | {display(old['value'])} | {display(new['value'])} | {display(report['afterMinusBefore'][key])} |")
    lines.extend(["", "Missing-data reasons and input hashes are in the JSON report. Device validation remains pending.", ""])
    lines.extend(f"- {note}" for note in report["limitations"])
    return "\n".join(lines) + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--before", type=Path, required=True, help="before-run manifest JSON")
    parser.add_argument("--after", type=Path, required=True, help="after-run manifest JSON")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--markdown", type=Path)
    args = parser.parse_args()
    reports = []
    try:
        for path in (args.before, args.after):
            info = manifest(path)
            memory, memory_files = read_logs(info["memoryLogs"])
            diagnostics, diagnostic_files = read_logs(info["rpcs3Logs"])
            report = measure(info, memory, diagnostics)
            report["inputs"] = memory_files + diagnostic_files
            reports.append(report)
        result = compare(*reports)
    except (ValueError, OSError, KeyError, TypeError) as error:
        parser.error(str(error))
    args.output.write_text(json.dumps(result, indent=2, allow_nan=False) + "\n")
    if args.markdown:
        args.markdown.write_text(markdown(result))
    print("Observed comparison recorded; iPhone validation remains pending.")


if __name__ == "__main__":
    main()
