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
Those Apple results and a new private IPA were still pending at that initial
checkpoint; the exact final Core evidence is recorded below.

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

At `c56b52743daf5c59783a82a0e6687a84773a72e3`, the pinned FFmpeg 8.1.1
Apple video proof passed, including four decoder workers: 52 old 720p pictures
archived, 74,973,184 mapped bytes actually unmapped, and identical decoded pixel
contents versus the pooled path. The independent simulator service archived
and returned 1,382,400 pixel bytes from its private file, with zero staging RAM
at the sampled checkpoint; all ten exact-revision regression workflows passed.

The full iOS syntax gate then correctly **blocked** the Core: the new calls to
`get_system_time()` in `cellVdec.cpp` lacked their declaring header. The old
fixture's fake clock definition had hidden this integration error. The canonical
VDEC postimage now explicitly includes the existing `Emu/Cell/timers.hpp`,
without changing its clock implementation or any decoder policy. A new native
compile probe uses the real header's declaration and no fake clock definition;
omitting that production include now fails locally, and a permanent negative
probe confirms the failure is caught. The full 17-unit iOS gate remains mandatory.
The failed Core has no usable artifact and will not be pinned into an IPA.

The final consumption guard reserves a retry slot **only** for an archived
picture with an output buffer. Warm pictures, default-off decoders and skipped
pictures keep the original immediate producer notification. All four guard
combinations are compile-time checked against the actual client helper, the
producer capacity/restore failure tests remain required, and the source test
rejects unconditionally delaying warm/default-off consumption. The earlier
clock-only candidate `f6dbdce904e13e72971d3baf9f4a930a45813891` is superseded
and must not provide the final IPA's Core or validation evidence.

The macOS storage baseline test at `7bcc52854d6f5bd9c4bb67acdff676f74eee8318`
also exposed an older test assumption: it required successful speculative
prefetch after a real demand read even though the engine intentionally refuses
prefetch above its measured 8ms read-p95 threshold. Delaying only real POSIX
`pread` calls by 20ms reproduces the original assertion failure locally:
`Code::pressure`, measured read p95 20,544us, threshold 8,000us, test Store
pressure still normal. This is not evidence of corrupted pixels or memory OOM.
The production Store is byte-identical and its 8ms default remains unchanged.
The success/lease/pressure test now explicitly supplies an eligible test-only
latency budget; a separate strict-budget case asserts measured-latency refusal,
the cancellation counter and exact demand-read fallback. Both retain the
original content, pin, quota and priority assertions. This is host acceptance
evidence, not a changed Core input or an emulator timing adjustment.

## Verified final Core, before private IPA packaging

The final Core is `7bcc52854d6f5bd9c4bb67acdff676f74eee8318`, built by
workflow run `37120654954`, successful job `111195937578`. Its real Apple
FFmpeg 8.1.1 proof archived 52 of 60 old 720p pictures, actually unmapped
74,973,184 bytes, preserved exact decoded pixel contents, and passed with
four decoder workers. The actual 17-unit iOS SDK/compiler gate passed at
12:04:39 UTC on 3 October 2026; the full arm64 Core subsequently linked.
Command-contract simulations are not counted as this SDK result.

Downloaded artifact `11274522445` has ZIP SHA-256
`3493899fc809906d8a23b399d9c3f5c37e649576e01dc1cd391d114e90b42f84`.
All five ZIP entries passed CRC verification. The 75,388,976-byte dylib has
SHA-256 `b65eef55912bada9adf7a13ddbf15a4e3a96c6ddf72427c907e2a77fe917bb58`.
Local Mach-O, passive-dlopen and exact-input pin validations passed. All
57 Core inputs match this revision, with main ABI 30 and source ABI 1 intact.
Static passive-dlopen validation reports no forbidden direct-call reachability,
but explicitly does not claim device runtime validation.

The packaging commit changes only the reviewed host pin, acceptance-test
repair and evidence/manifest files. It must obtain its own complete exact-SHA
host regression results; the earlier macOS prefetch-test failure and simulator
boot timeout at the Core revision are not treated as successful host gates.
No final private IPA or device gameplay result is claimed at this checkpoint.

## Observability and honest presentation

Core diagnostics separately report owned live mappings, actual unmaps,
unmap failures, archived frames and restore latencies. Host JSONL records
currently archived pixel payload, cumulative archives/returns and transient
checkpoint retries. UI labels distinguish these from real process RAM and
are translated in all twelve supported languages. No artificial downward
RAM curve or physical-memory claim is introduced. Device gameplay, NAND
latency, freeze resolution and performance gain remain unvalidated.
