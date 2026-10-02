# Build 396 — optional, end-to-end shader bytecode storage

## Scope and activation

This build connects the tested disk store to a real RPCS3 consumer:
`vk::glsl::shader::create/compile`, between GLSL compilation and
`vkCreateShaderModule`. Only immutable, reconstructible CPU SPIR-V bytecode is
cached. GPU modules, pipeline handles, live DMA, guest aliases, JIT and saves
are unchanged. This is not a debug getter, dummy allocation or kernel swap port.

The NeoSwap dialog has an experimental shader disk cache switch, off by default.
The preference applies at the next game launch. Only the six existing God of
War III title IDs enable it. It uses at most 8 MiB managed RAM including 1 MiB
optional compressed data, with a 128 MiB disk cap. Caps are not allocations.
No five-GiB game-memory or faster-loading result is inferred.

## Consumption and failure paths

Keys are SHA-256 of exact GLSL bytes, shader stage and the versioned compiler
environment. Records are session-local. A warm hit pins checked bytecode until
vkCreateShaderModule returns. The redundant original CPU vector may then be
released. On a cold miss the host queues restoration and returns immediately;
RPCS3 compiles its original GLSL, without waiting for a disk future. Restored
bytecode can satisfy a later request. Publishing copies at most one 1 MiB blob;
the original is released only after ownership acceptance. Entries below 16 KiB
stay on the original path. Compression is conditional and disabled for new
optional work under pressure.

Disk/CRC/admission errors use the original compiler. Invalid cached modules
are invalidated and rebuilt once. Driver OOM/device loss does not trigger a
second compiler allocation. Contended invalidation disables the cache session
rather than risking repeated invalid data. Original GLSL remains reconstructible.

## Lifetime and telemetry

Store setup, maintenance, retirement and worker joining occur on a utility
queue. ABI callbacks use try-locks and bounded data work, not filesystem I/O.
Session generations reject old callbacks; leases survive closure. The last
owning cache reference is retained by the utility queue until callbacks finish.
Backpressure limits retired sessions. Memory warnings, background state and
thermal pressure stop optional work. The private session file is protected,
unlinked while open, excluded from backup, and separate from saves. Freed file
extents are reused without truncating live records. The five extensions and
other emulators keep their previous pins.

FPS and the two RAM curves are unchanged. A separate shaderStorage diagnostic
reports active/requested state, raw/compressed/pinned/loading RAM, disk-only
logical data, allocated file bytes, reusable extents, read/write/queue latencies,
hits, misses, reconstruction, compression costs, pressure and process metrics.
Last-session counters survive normal game closure. Unknown jetsam cause stays
null pending an iOS system report.

## Required validation

Core source is pinned to 43dac44766c10714fe41baf45badcec926dffcd8, Core run
37058087412, including all 47 input hashes. Host tests execute the actual client
and POSIX file paths under ASan/UBSan, actual UIKit service on iOS18 Simulator,
and a real macOS Vulkan module/pipeline/compute dispatch consuming disk-restored
SPIR-V after CPU mappings are released. iPhoneOS ARM64 linkage is checked.

Synthetic shader padding exceeds the small-entry cutoff; it is not a game
allocation. Simulator pressure notifications are injected. File-cache latency
is not cold NAND latency. These checks do not validate physical iPhone gameplay.
The IPA gate rejects missing evidence, wrong hashes, old Core, duplicate brokers
or test hooks. Compare switch off/on with the same game sequence and settings:
launch time, frame-time tails, footprint, hit/eviction counts and I/O. A small
or zero-hit cache is evidence to disable or retarget, not increase quotas.

## Packaging correction: feature macro versus result enum

IPA run 37061989078 failed while compiling NeoSwapPlugin.mm: the new
NEOSWAP_STORAGE=1 feature define replaced the existing NEOSWAP_STORAGE=-4
result enum with an integer. Rename only the CocoaPods feature define and
its three plugin guards to NEOSWAP_SHADER_STORAGE. Keep the public error
code, donor/storage ABIs, Core input hashes and runtime cache algorithms
unchanged. The host preflight now compiles both ABI headers using the actual
podspec defines, preserves the -4 result, verifies enabled plugin guards and
executes a negative compiler case with the old conflicting flag. The failure
was reproduced before the rename; the corrected gate passes. This repairs
build integration, not an iPhone gameplay crash.
