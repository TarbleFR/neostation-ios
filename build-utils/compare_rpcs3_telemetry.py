#!/usr/bin/env python3
"""Compare two real iPhone RPCS3-diagnostic.log captures.

No synthetic numbers are accepted: each report is derived from native boot
milestones and the one-second performance samples already emitted by the app.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import statistics


SAMPLE = re.compile(
    r"title=(?P<title>\S+) .*?fps=(?P<fps>[0-9.]+) "
    r"cpu=(?P<cpu>[0-9.]+) rsx=(?P<rsx>[0-9.]+) "
    r"memory=(?P<memory>\d+)/(?P<total>\d+) available=(?P<available>\d+) "
    r"thermal=(?P<thermal>\d+)"
)


def read_entries(path: Path) -> list[dict]:
    entries = []
    for number, line in enumerate(path.read_text(errors="replace").splitlines(), 1):
        try:
            value = json.loads(line)
        except json.JSONDecodeError as error:
            raise ValueError(f"{path}:{number}: invalid diagnostic JSON") from error
        if isinstance(value, dict) and "stage" in value and "timestamp" in value:
            entries.append(value)
    return entries


def measure(path: Path, title: str) -> dict:
    title = title.upper()
    entries = read_entries(path)
    begins = [
        index for index, entry in enumerate(entries)
        if entry.get("stage") == "game_boot_begin" and str(entry.get("message", "")).upper() == title
    ]
    if not begins:
        raise ValueError(f"{path}: no boot session for {title}")
    start = begins[-1]
    end = len(entries)
    for index in range(start + 1, len(entries)):
        if entries[index].get("stage") == "game_boot_begin":
            end = index
            break
    session = entries[start:end]

    boot_return = next(
        (entry for entry in session if entry.get("stage") == "game_boot_return"), None
    )
    if boot_return is None or "status=0" not in str(boot_return.get("message", "")):
        raise ValueError(f"{path}: {title} has no successful boot completion")

    samples = []
    for entry in session:
        if entry.get("stage") != "performance_sample":
            continue
        match = SAMPLE.search(str(entry.get("message", "")))
        if match and match.group("title").upper() == title:
            samples.append({key: float(value) for key, value in match.groupdict().items() if key != "title"})
    if len(samples) < 5:
        raise ValueError(f"{path}: {title} needs at least five real performance samples")

    fps = [sample["fps"] for sample in samples]
    frame_ms = [1000.0 / value for value in fps if value > 0]
    median_fps = statistics.median(fps)
    stutter_threshold = median_fps * 0.8
    core_lines = [str(entry.get("message", "")) for entry in session if entry.get("stage") == "core_log"]
    return {
        "title": title,
        "samples": len(samples),
        "boot_seconds": float(boot_return["timestamp"]) - float(session[0]["timestamp"]),
        "average_fps": statistics.fmean(fps),
        "minimum_fps": min(fps),
        "p95_sample_frame_ms": sorted(frame_ms)[min(len(frame_ms) - 1, int(len(frame_ms) * 0.95))],
        "stutter_samples": sum(value < stutter_threshold for value in fps),
        "average_cpu_percent": statistics.fmean(sample["cpu"] for sample in samples),
        "average_rsx_percent": statistics.fmean(sample["rsx"] for sample in samples),
        "peak_memory_mib": max(sample["memory"] for sample in samples) / (1024 * 1024),
        "minimum_available_mib": min(sample["available"] for sample in samples) / (1024 * 1024),
        "worst_thermal_state": int(max(sample["thermal"] for sample in samples)),
        "shader_events": sum("shader" in line.lower() and "compil" in line.lower() for line in core_lines),
        "fatal_events": sum("fatal" in line.lower() for line in core_lines),
    }


def comparison(before: dict, after: dict) -> str:
    def change(key: str) -> float:
        return after[key] - before[key]

    rows = [
        ("Average FPS", "average_fps", "{:.2f}"),
        ("Minimum FPS", "minimum_fps", "{:.2f}"),
        ("P95 sampled frame time (ms)", "p95_sample_frame_ms", "{:.2f}"),
        ("Stutter samples (<80% median)", "stutter_samples", "{:.0f}"),
        ("Boot time (s)", "boot_seconds", "{:.2f}"),
        ("Average CPU (%)", "average_cpu_percent", "{:.1f}"),
        ("Average RSX (%)", "average_rsx_percent", "{:.1f}"),
        ("Peak memory (MiB)", "peak_memory_mib", "{:.1f}"),
        ("Minimum available memory (MiB)", "minimum_available_mib", "{:.1f}"),
        ("Shader compilation events", "shader_events", "{:.0f}"),
        ("Fatal events", "fatal_events", "{:.0f}"),
    ]
    output = [
        f"# RPCS3 device benchmark — {before['title']}", "",
        f"Samples: before {before['samples']}, after {after['samples']}", "",
        "| Metric | Before | After | Change |", "|---|---:|---:|---:|",
    ]
    for label, key, pattern in rows:
        output.append(
            f"| {label} | {pattern.format(before[key])} | {pattern.format(after[key])} | {pattern.format(change(key))} |"
        )
    output.extend([
        "",
        "Stutters use one-second native samples and therefore indicate sustained dips, not sub-second hitches.",
        "Thermal state: 0 nominal, 1 fair, 2 serious, 3 critical.",
    ])
    return "\n".join(output) + "\n"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--before", type=Path, required=True)
    parser.add_argument("--after", type=Path, required=True)
    parser.add_argument("--title", required=True)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    report = comparison(measure(args.before, args.title), measure(args.after, args.title))
    if args.output:
        args.output.write_text(report)
    else:
        print(report, end="")


if __name__ == "__main__":
    main()
