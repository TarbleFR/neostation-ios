# NeoSwap storage-backed cache: isolated integration prerequisite

Base: Build395, 32d58742063235315672ed44b48e3b079c7a6244. This native module is not linked into the production Core or NeoStation. It is not a new IPA and does not enable an iPadOS kernel swap service. The exact 42 Core inputs, donor lifecycle, JIT helpers, user data and production graph remain unchanged.

## Contract

Only owned immutable and regenerable CPU bytes can be published. Never pass guest memory, live GPU/DMA storage, JIT executable memory, stacks, locks or save data. A successful publish transfers ownership and seals the buffer; no caller may retain its former raw pointer. A rejection preserves the original. A Lease pins the immutable bytes. A cache owner must serialize its own mutations. Store and ApplePressure destruction belong on a setup/utility thread; a session retains Store until its cache entries have retired. Destroying the final shared owner can wait for worker completion.

Hot data stays raw in the bounded RAM cache; optional warm data is LZ4-compressed inside the same budget; cold data has a checked disk record and no raw/warm mapping. The worker writes and synchronizes before releasing the only RAM copy. Restoration validates identity, lengths and CRC32. CRC32 detects accidents, not malicious replacement. Failed writes retain raw originals. Failed reads are explicit errors and require reconstruction by the owner, never silent substitute bytes.

The private 0600 temporary file is unlinked while open and does not survive the session. Records grow the real file incrementally, not by allocating dummy capacity. Freed extents are now recycled, split and coalesced without truncating live records later in the file. Failed writes return reserved extents. Disk quota and free-space checks still apply. This is not a persistent save format or power-loss durability guarantee.

## Scheduling and limits

Default raw-plus-compressed RAM budget 32 MiB, including at most 4 MiB compressed; optional raw demand margin one maximum 1 MiB block; disk budget 256 MiB; free-space floor 512 MiB; 1024 entries; queue16; writes limited to16 MiB/s. Codec workspace and kernel file cache are separate from the managed RAM figure.

Demand reads precede deferred writes and speculative prefetch; an already executing I/O is not preempted. Requests to data not in RAM remain asynchronous and may still delay a consumer who needs those data now. Compression is accepted only with at least12.5% savings and within a configurable observed execution budget, not a preemptive deadline. Pressure disables optional admissions and prefetch. Already accepted reads and leases survive owner retirement; new requests to a retired handle fail.

## Reproducible evidence

Run `python3 native/neoswap-storage/run_validation.py --output /tmp/storage-proof` on Linux or macOS. On macOS add `--ios-sdk` to compile and link the ARM64 library for iOS18. This does not execute on iPhone. Tests execute actual POSIX file roundtrips under ASan/UBSan, injected corruption/truncation/ENOSPC/partial I/O, concurrency, and pressure. New tests exercise300 recycling iterations exceeding eight times a2 MiB quota cumulatively without increasing highwater or damaging live-tail records; stale handles are rejected. CacheEntry ownership tests preserve concurrent readers and accepted jobs after the owner retires.

Benchmarks compare separate processes and identical synthetic64 MiB datasets with8 MiB cache. They report sampled RSS, Apple footprint/compressed accounting where available, allocation/warm/disk data, reads/writes, queue and restoration latencies. File cache can service reads; no NAND-cold latency or gameplay result is inferred. Flags `physicalIPhoneValidated=false`, `realRPCS3GameplayValidated=false` and `kernelSwapPorted=false` remain explicit.

## RPCS3 integration status

No real RPCS3 cache uses this module yet. CacheEntry is an ownership primitive, not a claim of runtime integration. The checked Vulkan shader bytecode getter has no observed callsites in the inspected upstream revision; writing those unused copies just to exercise storage is not justified. Existing raw shader-cache data already exist on disk and must not be duplicated without benefit. Video output frames can share FFmpeg buffers with decoder state: queue ownership alone cannot authorize eviction. A future consumer must prove exclusive cold-byte ownership or provide a verified immutable snapshot and a reconstruction path, and must expose nonblocking restore/prefetch boundaries. Until those conditions are tested, production activation remains absent.

Priorities: stability, then latency, then capacity. No five-GB game-memory or crash-fix claims follow from module tests.
