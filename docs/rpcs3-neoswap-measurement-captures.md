# RPCS3 / NeoSwap: compare two builds

`tools/compare_rpcs3_neoswap_builds.py` compares **observed** diagnostic windows
between identified runs, including different source SHAs. The existing
`tools/compare_neoswap_sessions.py` remains the separate same-source,
baseline-versus-relay/integrated experiment tool.

Save one manifest beside each pair of exported JSONL logs:

```json
{
  "sourceCommit": "0123456789abcdef0123456789abcdef01234567",
  "pid": 123,
  "sessionSequence": 1,
  "bootTimestamp": 100.25,
  "title": "BCES00510",
  "workloadId": "gow3-save-A-fixed-route-180s",
  "deviceId": "my-iphone-16-pro-max",
  "settingsId": "same-config-and-cache-policy",
  "memoryLogs": ["NeoSwap-v1.jsonl"],
  "rpcs3Logs": ["RPCS3-diagnostic.log"]
}
```

The identifiers above are examples, **not a recorded iPhone measurement**.
Use the actual packaged source SHA, PID, `memoryProfile.sessionSequence`, and
exact timestamp of `game_boot_begin`. `title` is the actual regional title ID.
`workloadId` identifies the same save, route and measurement duration.
`settingsId` identifies the same emulator settings and controlled cache policy.
Use a stable device alias; no serial number is required. These protocol
identities are operator attestations, not automatically verified device facts.

```sh
python3 tools/compare_rpcs3_neoswap_builds.py \
  --before captures/before.json --after captures/after.json \
  --output captures/comparison.json --markdown captures/comparison.md
python3 test/rpcs3_neoswap_build_comparison_test.py
```

The parser rejects ambiguous/missing session boundaries, another title or
launch within the selected session, mismatched logged source SHAs, profiler
epoch changes, and decreasing cumulative counters. OS, physical memory,
device, settings and workload must agree between runs. Multiple rotated files
can be listed; identical records are deduplicated. Input files are SHA-256
identified. A source SHA absent from the log is reported as `manifest_only`.

Measurement semantics:

- `SPUPROF` loading/gameplay compile totals and maxima, warmed entry reuses and
  heavy compile attempts on previously warmed items cover emitted windows.
  Loading means startup compiler scope, not the first playable frame.
- `RANGELOCKPROF` reports contention episodes, episode total/max duration,
  maximum polling iterations and observed blockers. Legacy `COREPROF`
  `range_stalls` is polling iterations; `range_wait_ms` is **per frame** and is
  multiplied by the window frame count before summing observed wait time.
- Native window frametime means/p95 stay explicitly named as window metrics.
  There is no session p95 reconstructed from window percentiles or sampled FPS.
- `fastAllocation` delta counters and mean acquisition duration cover the
  first-to-last memory sample. They include refusals. The maximum is a process
  lifetime high-water mark and can predate this session. Acquisition duration
  does not measure OS page faults or end-to-end ordinary-memory fallback.
- Prepared donor capacity, relay readiness, resident bytes and actual live
  mappings remain separate. The live backing total sums simultaneous disjoint
  donor/guest-relay/host-relay backing only. It does not prove additional usable
  capacity under gameplay pressure or additional resident physical RAM.
- Missing metrics remain `null` with a reason. Old logs can provide legacy SPU
  totals without proving loading/gameplay attribution or single-compile peaks.

Capture matching cold and warm runs, relaunch, partial preparation, refusal
and timeout cases on iPhone. Preserve full logs including session end and note
thermal conditions. Initial/final partial windows or dropped core messages
can make totals incomplete even with session boundaries. No built-in baseline
uses the reported approximations of 50 s, 8.8 s, 118 ms or one million waits.
The generated table and passing parser tests do not validate gameplay or
authorize promotion; `deviceValidationPassed` remains false.
