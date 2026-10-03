# Build400: repair from Build399 runtime evidence

This private host candidate preserves the RPCS3 Core artifact from host
`7bcc52854d6f5bd9c4bb67acdff676f74eee8318`, run `37120654954`.
Its source ABI, JIT, guest paging, RSX, codecs and emulator settings are unchanged.

## Device evidence

The supplied October 3 logs isolate God of War III BCES00510, process 4264,
between 15:03:20.755 and 15:05:48.338 UTC. The later BLES00113 session is a
different game and is excluded from this comparison. Across 132 memory samples,
pressure and thermal flags remained zero, headroom stayed above 3,918,981,632
bytes, yet cumulative video archival reached 633,830,400 bytes and restoration
406,425,600 bytes. Those cumulative counters do not represent current RAM saved.

Synchronous VDEC restores share a serial worker with every-fragment admission,
discard, full-record maintenance and diagnostic snapshots. Two consumer waits
have 59 occupied slots, consistent with a reserved restore slot; worker snapshots
stay unchanged for 8.5 and 11.5 seconds. A Linux probe using the real Store and
four file-backed records reproduced 168,898 microseconds of FIFO demand wait,
versus 89 microseconds for an available RAM snapshot. These are synthetic local
queue measurements, not an iPhone NAND latency guarantee. Early low FPS occurs
before the first video admission, so this defect does not explain all stalls.

The host also had two timers reading a Core getter that advances a shared FPS
baseline. Back-to-back reads produce zeros or spikes. Independent Core profiling
confirms substantial real slowdown even when the UI measurement is disregarded.

## Host changes

Video domain 3 admits snapshots only with fresh measured normal-pressure
headroom at or below 1 GiB. Recovery above 1.5 GiB stops new admissions; stale or
unknown measurements refuse them. Existing warning and critical refusals remain.
Already accepted snapshots remain restorable after admission is disabled.

Maintenance requests coalesce, process at most one 64 KiB archive checkpoint
and four retirements, then continue at the worker tail. Discard batches are
bounded. Pending demand takes priority. Complete immutable RAM snapshots have
a nonblocking read path before queueing file restoration. Logs distinguish
queue wait from actual copying/reading. This cannot preempt an in-flight file
checkpoint and is not a universal latency bound.

The host retains the existing Core's NEOSWAP_VDEC archive, actual unmap and
restore notices under its ordinary log budget. Build399 filtered these notices,
so its files could not establish original FFmpeg page release on the device.

One 1 Hz diagnostic producer reads Core metrics. The 0.5 s overlay consumes
a host cache, with unavailable, priming, stale, failed and real-zero states
separate. Session epochs, internal reboot invalidation and main-thread owner
checks reject old samples. No FPS clamp or Core API change is introduced.

NeoPlay discovery remains explicitly requested in Settings > Tools > NeoPlay.
Users can retry after permission changes or resume a requested search on
foreground return. Cast discovery restart preserves the session, and network
errors and actual discovery counts are recorded in NeoPlay diagnostics.
The retry guidance covers all 12 application locales.

## Validation scope

Sanitized native tests exercise exact RAM/file/RAM bytes, incremental archival,
discard/restore ordering, failures, epoch changes, pressure hysteresis and
coalesced scheduling. FPS tests cover one producer, expiry after UI delay,
error/zero semantics and internal boot fences. Flutter covers retry and locale
behavior. Required exact-SHA Apple gates additionally compile/link the real
service and execute iOS simulator and NeoPlay native tests before IPA packaging.

No physical-iPhone gameplay improvement, physical Chromecast connection,
kernel swap implementation or additional resident RAM is claimed by this patch.
