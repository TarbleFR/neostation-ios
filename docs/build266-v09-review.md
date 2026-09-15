# Build 266 — selective RPCS3 v0.9-era backport and local JIT repair

## Reviewed sources

- Release notes: https://github.com/XITRIX/RPCS3-iOS-Releases/releases/tag/v0.9
- Reviewed core snapshot: XITRIX/rpcs3 `505a85e5a8f2cdff1cd63168bd2c56b0f92282bf`.
- Embedded base remains `22f1152783cef1f7e04af7b1c895173e28fd5b03`, ABI 30.

This is **not** a wholesale migration to the v0.9 application. The release
repository does not establish a byte-for-byte source mapping for its IPA.
The two source histories have diverged; selection used a direct source diff,
not the merge-base diff or a blind core replacement.

## Integrated

The allocator reserves RX code in the upstream bounded low virtual-address
window, avoids overwriting existing mappings, and can reserve a separate nearby
data arena when an adjacent code/data range is unavailable. Separate code/data
capacities are propagated to the ASMJIT/LLVM allocation and diagnostic paths.
NeoStation's shared writable/executable alias coherence proof and exact-address
Universal JIT handshake remain mandatory.

The upstream capacity parser supports an explicit 512–1024 MiB code request.
The existing automatic RAM-dependent default stays 256–512 MiB. Legacy value 1
still means 512 MiB. This build does **not** force a 1 GiB arena, and it does not
introduce a new capacity slider into the existing boolean frontend setting.

The upstream progress-completion fix checks the final counters before a compact
progress overlay can skip cleanup. It handles completion before the first UI
update and does not confuse linking at 100% with completion.

Cached-shader warm-up already existed. NeoStation now checkpoints the compatible
Vulkan/MoltenVK driver cache after the synchronous warm-up, before gameplay.
Existing size/UUID validation, atomic cache writes, shader-cache opt-out and
interpreter-only mode are preserved. This cannot precompile shaders that the
game has never generated and is not evidence of increased FPS or a fixed game
crash. No user saves or valid persistent caches are deleted by this change.

The local VPN patch serializes cold reset with Dart launch requests, prioritizes
stops over obsolete requests and provider callbacks, waits for actual disconnect
transitions, preserves bounded native disconnect diagnostics, and separates VPN
status from verified RemotePairing reachability. Heartbeats use a dedicated
queue; the provider uses a monotonic five-second lease. A transient `inactive`
permission dialog no longer cancels its own authorization; real background and
teardown states still stop the owned tunnel. External LocalDevVPN is not modified.

## Deliberately not imported

ActivityKit / Live Activity and the upstream application's background compilation
UI require separate host lifecycle integration. They are not synonymous with
full shader precompilation. Upstream experimental options are not globally
forced on merely because v0.9 changed their defaults. Existing NeoStation
patches, RetroAchievements, themes, NeoSync and game imports are retained.

## Validation boundaries

The build executes the existing suites plus Dart cancellation/route/lifecycle
tests, production-method Swift tests with simulated NetworkExtension/network
effects, upstream allocator/progress C++ tests, actual-source reservation tests,
and final-IPA negative/positive identity checks. macOS ARM64 also executes and
rewrites instructions through the actual V5 low-address RW/RX layout.

Source preimages, immutable upstream inputs and final postimages are SHA-256
verified by `build-utils/rpcs3/build266-v09-manifest.json`. Final IPA markers are
checked in addition to the existing Mach-O/dependency/entitlement validators.

Neither host tests nor CI can establish iPhone VPN operation or God of War III
stability. The provided RPCS3 log records Bladestorm, so it does not establish the
cause of the reported God of War III crash. These remain device validation cases.
