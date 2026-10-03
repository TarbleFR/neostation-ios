# Build399 — owned video pixels, not a cosmetic RAM graph

## Evidence from the uploaded Build398 session

Only PID2963 / 2026-10-03 09:18:49–09:21:39 UTC is the Build398
God of War III session. The diagnostic file also contains older Build396
sessions; they must not be merged into this workload.

The owned GLSL path admitted 142 snapshots and archived 3,605,888 logical
bytes. No application source restore occurred. Its verified checkpoint
readbacks are not gameplay restores. The peak process footprint was
3,296,253,392 bytes. A few MiB of archived text cannot materially change
a graph at that scale.

The kernel pressure mask remained zero, with no recorded pressure events
or allocator-pressure reclamation. Available process memory remained above
3.68 billion bytes. This does not establish jetsam or an out-of-memory freeze.
At the persistent stall the RSX acquire label was one increment behind
(`0x60300510`, expected `0x10F4`, observed `0x10F3`), followed by repeated
VDEC consumer waits with a full queue of 60 pictures. This is a separate
stall symptom, not proof that swapping guest memory would resolve it.

## Implemented, restricted evolution

The existing opt-in / next-launch God of War III policy now permits source
domain 3, in addition to the unchanged compiled-GLSL domains 0–2. The source
ABI remains 1, the main Core ABI remains 30, and older GLSL-only hosts refuse
the new domain without losing the original pixels.

For eligible software YUV420 frames, an FFmpeg `get_buffer2` callback supplies
owned anonymous mappings with codec-required strides, padded dimensions and
page-aligned planes. The default FFmpeg pool would retain returned pixels;
just unreferencing pooled frames would not prove RAM reclamation. This callback
is selected only at decoder construction in an enabled session. Hardware,
other pixel formats and oversized frames retain the normal allocator.

The producer considers queues of at least 24 pictures, retains the newest
eight, requires 250 ms of age and exclusive ownership of every FFmpeg pixel
buffer, and transfers at most 4 MiB of visible pixels per picture. Admissions
are paced to at most 8 MiB/s. Successful admission copies bounded fragments
without disk I/O. Only after every fragment is accepted in the same epoch
are the original AVBuffer references released. Last-reference destruction
actually calls `munmap`; decoder reference pictures remain resident.

The host retains a complete accepted RAM snapshot until every 64 KiB chunk
has been written, synchronized, read back and verified. A temporary busy or
pressure result preserves completed chunk progress. Refused admission retains
the original AVFrame; persistence failure retains the complete host snapshot.
The existing 4 MiB staging / 8 MiB managed-mapping limits remain unchanged.

`GetPicture` restores an owning pixel buffer on its CPU consumer, outside both
the queue and conversion locks. Original dimensions, timestamps, picture type,
colour metadata, output formats and decoder settings are retained. Failed reads
clear partial output and keep the frame retryable; an in-flight slot prevents
the producer from exceeding its original queue capacity during that retry.

No guest pointer, JIT allocation, driver resource, semaphore value, RSX timeout
or emulator setting changes. This is application-owned swapping, not a port
of kernel virtual-memory swapping or proof that the cutscene freeze is fixed.

## Executed local validation

- ASan/UBSan: the retained 64 MiB GLSL cycle still passes.
- ASan/UBSan: 48 synthetic 720p YUV payloads (66,355,200 bytes) pass the real
  file-backed archive cycle, exact restore, quota/epoch failures, partial-read
  clearing, old-host fallback, shared retirement and bounded staging.
- A real write-rate limit plus injected transient deferral after a verified
  chunk proves progress resumes without re-checkpointing completed chunks.
- Exact extracted VDEC producer with real FFmpeg 6.1.1, H.264, padded and
  negative strides, original-versus-restored RGBA output, reference exclusion,
  unchanged metadata, and refused multi-fragment transfer passes.
- A 60-frame 720p H.264 workload produces identical decoded pixels with the
  default allocator and the owned allocator. Archiving 52 old pictures
  unmaps 73,908,224 bytes in the owned path; the eight newest remain resident.
  This is mapping release, not a measured iPhone process-footprint delta.
  The owned callback also runs with four FFmpeg workers and must retain exact
  decoded contents and release every mapping on final context/queue retirement.
- The decoder producer and headers compile with `-fno-exceptions`. Allocation
  catches live only in the existing dedicated exception-enabled client unit.
- Flutter: 19 locale/channel/dialog/storage tests pass; all twelve languages
  include identical substitution keys and Traditional Chinese selection.

The mandatory Apple pipeline also executes the frame test against pinned
FFmpeg 8.1.1, links the actual host on arm64, runs source-domain-3 private-file
roundtrips/lifecycle failures in iOS18 Simulator, and syntax-checks the complete
`cellVdec.cpp` with the actual iOS Core compiler flags before the full build.
Those Apple results and a new private IPA are still pending at this checkpoint.

The first Apple Core preflight at `899dafb81a62f30d4150a604125730ac629be965`
stopped while configuring its **host test dependency**, before compiling the
iOS Core: FFmpeg reported missing host C11 support. Target SDK flags had been
supplied, but its separate host compiler did not receive the selected macOS
SDK. The repaired helper passes the SDK to both compiler roles, removes an
inherited iOS SDK, and preserves `ffbuild/config.log` plus the native proof log
on failure. Two command-contract simulations fail before that repair and pass
after it; they do not replace the real Apple FFmpeg execution. The independent
Linux/macOS storage jobs at that first SHA passed, including the actual iOS
simulator source-domain-3 service roundtrip. Future candidates must rerun their
own exact-source gates, not reuse these results as new-revision proof.

## Observability and honest presentation

Core diagnostics separately report owned live mappings, actual unmaps,
unmap failures, archived frames and restore latencies. Host JSONL records
currently archived pixel payload, cumulative archives/returns and transient
checkpoint retries. UI labels distinguish these from real process RAM and
are translated in all twelve supported languages. No artificial downward
RAM curve or physical-memory claim is introduced. Device gameplay, NAND
latency, freeze resolution and performance gain remain unvalidated.
