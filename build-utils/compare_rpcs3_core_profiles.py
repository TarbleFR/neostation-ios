#!/usr/bin/env python3
"""Compare Build 258 COREPROF windows from two real-device diagnostic logs."""

from __future__ import annotations

import argparse
import json
import math
from pathlib import Path
import re


PAIR = re.compile(r"([a-z0-9_]+)=(-?[0-9]+(?:\.[0-9]+)?)")
REQUIRED = {
    "frames", "avg_fps", "low1_fps", "frametime_ms", "p95_ms", "p99_ms",
    "ppu_ms", "spu_ms", "rsx_ms", "jit_ms", "gpu_time_ms",
    "gpu_fence_wait_ms", "gpu_fence_stalls", "gpu_fence_timeouts",
    "range_wait_ms", "range_stalls", "pipeline_jobs", "pipeline_queue_ms",
    "pipeline_compile_ms", "pipeline_peak", "ppu_threads", "spu_threads",
    "rsx_threads", "jit_threads", "memory_mib", "headroom_mib",
}


def read_entries(path: Path) -> list[dict]:
    entries: list[dict] = []
    for number, line in enumerate(path.read_text(errors="replace").splitlines(), 1):
        try:
            value = json.loads(line)
        except json.JSONDecodeError as error:
            raise ValueError(f"{path}:{number}: invalid diagnostic JSON") from error
        if isinstance(value, dict) and "stage" in value and "timestamp" in value:
            entries.append(value)
    return entries


def session_for_title(entries: list[dict], title: str, path: Path) -> list[dict]:
    title = title.upper()
    starts = [
        index for index, entry in enumerate(entries)
        if entry.get("stage") == "game_boot_begin"
        and str(entry.get("message", "")).upper() == title
    ]
    if not starts:
        raise ValueError(f"{path}: no boot session for {title}")
    start = starts[-1]
    end = len(entries)
    for index in range(start + 1, len(entries)):
        if entries[index].get("stage") == "game_boot_begin":
            end = index
            break
    return entries[start:end]


def parse_windows(path: Path, title: str) -> list[dict[str, float]]:
    windows: list[dict[str, float]] = []
    for entry in session_for_title(read_entries(path), title, path):
        message = str(entry.get("message", ""))
        if "COREPROF " not in message:
            continue
        values = {key: float(value) for key, value in PAIR.findall(message)}
        missing = REQUIRED - values.keys()
        if missing:
            raise ValueError(f"{path}: incomplete COREPROF window: {sorted(missing)}")
        if values["frames"] <= 0 or values["avg_fps"] <= 0:
            raise ValueError(f"{path}: invalid COREPROF frame window")
        windows.append(values)
    if len(windows) < 3:
        raise ValueError(f"{path}: {title.upper()} needs at least three real COREPROF windows")
    return windows


def measure(path: Path, title: str) -> dict[str, float | str]:
    windows = parse_windows(path, title)
    total_frames = sum(window["frames"] for window in windows)

    def weighted(key: str) -> float:
        return sum(window[key] * window["frames"] for window in windows) / total_frames

    gpu_values = [window for window in windows if window["gpu_time_ms"] >= 0]
    return {
        "title": title.upper(),
        "windows": float(len(windows)),
        "frames": total_frames,
        "average_fps": weighted("avg_fps"),
        "low_1_fps": weighted("low1_fps"),
        "frametime_ms": weighted("frametime_ms"),
        "p95_ms": weighted("p95_ms"),
        "p99_ms": weighted("p99_ms"),
        "ppu_ms": weighted("ppu_ms"),
        "spu_ms": weighted("spu_ms"),
        "rsx_ms": weighted("rsx_ms"),
        "jit_ms": weighted("jit_ms"),
        "gpu_time_ms": (
            sum(window["gpu_time_ms"] * window["frames"] for window in gpu_values)
            / sum(window["frames"] for window in gpu_values)
            if gpu_values else math.nan
        ),
        "gpu_fence_wait_ms": weighted("gpu_fence_wait_ms"),
        "gpu_fence_stalls": sum(window["gpu_fence_stalls"] for window in windows),
        "gpu_fence_timeouts": sum(window["gpu_fence_timeouts"] for window in windows),
        "range_wait_ms": weighted("range_wait_ms"),
        "range_stalls": sum(window["range_stalls"] for window in windows),
        "pipeline_jobs": sum(window["pipeline_jobs"] for window in windows),
        "pipeline_queue_ms": weighted("pipeline_queue_ms"),
        "pipeline_compile_ms": weighted("pipeline_compile_ms"),
        "pipeline_peak": max(window["pipeline_peak"] for window in windows),
        "ppu_threads": weighted("ppu_threads"),
        "spu_threads": weighted("spu_threads"),
        "rsx_threads": weighted("rsx_threads"),
        "jit_threads": weighted("jit_threads"),
        "peak_memory_mib": max(window["memory_mib"] for window in windows),
        "minimum_headroom_mib": min(window["headroom_mib"] for window in windows),
    }


def comparison(before: dict, after: dict) -> str:
    rows = [
        ("Average FPS", "average_fps", ".3f", True),
        ("1% low FPS", "low_1_fps", ".3f", True),
        ("Mean frametime (ms)", "frametime_ms", ".3f", False),
        ("P95 frametime (ms)", "p95_ms", ".3f", False),
        ("P99 frametime (ms)", "p99_ms", ".3f", False),
        ("PPU CPU / frame (ms)", "ppu_ms", ".3f", False),
        ("SPU CPU / frame (ms)", "spu_ms", ".3f", False),
        ("RSX CPU / frame (ms)", "rsx_ms", ".3f", False),
        ("JIT CPU / frame (ms)", "jit_ms", ".3f", False),
        ("Physical GPU / frame (ms)", "gpu_time_ms", ".3f", False),
        ("GPU fence wait / frame (ms)", "gpu_fence_wait_ms", ".3f", False),
        ("GPU fence waits", "gpu_fence_stalls", ".0f", False),
        ("GPU fence timeouts", "gpu_fence_timeouts", ".0f", False),
        ("VM range-lock wait / frame (ms)", "range_wait_ms", ".3f", False),
        ("VM range-lock waits", "range_stalls", ".0f", False),
        ("Pipeline jobs", "pipeline_jobs", ".0f", False),
        ("Pipeline queue / job (ms)", "pipeline_queue_ms", ".3f", False),
        ("Pipeline compile / job (ms)", "pipeline_compile_ms", ".3f", False),
        ("Peak pipeline backlog", "pipeline_peak", ".0f", False),
        ("Average PPU threads", "ppu_threads", ".2f", None),
        ("Average SPU threads", "spu_threads", ".2f", None),
        ("Average RSX threads", "rsx_threads", ".2f", None),
        ("Average JIT threads", "jit_threads", ".2f", None),
        ("Peak memory (MiB)", "peak_memory_mib", ".1f", False),
        ("Minimum headroom (MiB)", "minimum_headroom_mib", ".1f", True),
    ]

    def display(value: float, pattern: str) -> str:
        return "unavailable" if math.isnan(value) else format(value, pattern)

    output = [
        f"# RPCS3 core benchmark — {before['title']}", "",
        f"Windows: before {int(before['windows'])}, after {int(after['windows'])}; "
        f"frames: before {int(before['frames'])}, after {int(after['frames'])}", "",
        "| Metric | Build 257 | Build 258 | Delta | Direction |",
        "|---|---:|---:|---:|:---:|",
    ]
    for label, key, pattern, higher_is_better in rows:
        old = float(before[key])
        new = float(after[key])
        delta = new - old
        if math.isnan(old) or math.isnan(new):
            direction = "n/a"
        elif higher_is_better is None or delta == 0:
            direction = "—"
        elif (delta > 0) == higher_is_better:
            direction = "better"
        else:
            direction = "worse"
        output.append(
            f"| {label} | {display(old, pattern)} | {display(new, pattern)} | "
            f"{display(delta, pattern)} | {direction} |"
        )
    output.extend([
        "",
        "The 1% low is frame-weighted across native five-second windows. Physical GPU time remains "
        "unavailable until Vulkan timestamp queries are validated on MoltenVK; fence wait is reported "
        "separately and is never presented as GPU execution time.",
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
