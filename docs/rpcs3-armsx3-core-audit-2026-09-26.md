# RPCS3 iOS: ARMSX3 performance audit (isolated branch)

## Source identities and scope

- NeoStation starting point: `experimental` at `d8a5a124f3c65b2b4e456a995a9eb4daaed05d2c` (Build 341). Changes are isolated on `work/rpcs3-armsx3-perf`; no KartPad source or IPA workflow is changed.
- NeoStation's Core still uses `XITRIX/rpcs3` at `22f1152783cef1f7e04af7b1c895173e28fd5b03` with the single hash-verified `build-utils/rpcs3/embedded-core.patch`. The Core ABI, JIT reservation policy, savestates, firmware, and game profiles stay pinned.
- Reference: `ARMSX2/ARMSX3` at `8290349e5c2184089802e2284c8a11f17416ae6b` (26 September 2026). Its Android app, JNI bridge, and Qualcomm/Turnip paths cannot be transplanted into the MoltenVK iOS Core.

## Findings

| Area | Audit result | Action |
| --- | --- | --- |
| SPU reservation copy, range lock, ARM64 byte folds | Already in the canonical NeoStation Core patch (`NEOSTATION_ARMSX3_*` markers). | Preserve; the existing contract check passes on the materialized Core. |
| PPU/SPU cache, Vulkan pipeline cache, RSX compile queue, Core profiling | Already adapted in earlier NeoStation Core iterations. The iOS JIT code still embeds absolute addresses in SPU objects, so cross-process reuse remains unsafe. | Preserve; do not add a second cache or another scheduler. |
| PPU blocks after the last recognized function | The pinned XITRIX analyzer still emits one JIT function **per instruction**, without a bound, unless its unrelated `used_fallback` path fires. ARMSX3 [70dbdc8](https://github.com/ARMSX2/ARMSX3/commit/70dbdc86d5f6836a6f9e4f15828859e323c10902) documents a title with over 1.4 million such instructions. | Port the 65,536-instruction bound. Large regions remain whole blocks, using the analyzer's existing fallback for mid-block entry. |
| LLVM AArch64 InterleavedLoadCombine | Present in the LLVM submodule pinned by XITRIX (`ca7933e47d3a3451d81e72ac174dcb5aa28b59d1`). ARMSX3 [85d074b](https://github.com/ARMSX2/ARMSX3/commit/85d074b785b101ce1801e0530b15ea71c179ccb1) attributes a multi-minute EBOOT compile to this pass on an ARM64 device. | Disable this pass once before iOS ARM64 JIT compilation. Log success or absence of the option; keep the change out of non-iOS builds. |
| Concurrent PPU module compilation | The pinned XITRIX queue divides **installed RAM** by 2,000 to admit simultaneous module builds. ARMSX3 [d0df12f](https://github.com/ARMSX2/ARMSX3/commit/d0df12f8ffa14c91a4b11b1ae4201316538ab939) records an out-of-memory rebuild on a mobile device when installed RAM overstated the available allowance. | On iOS, base the same queue on `os_proc_available_memory()` through the existing Core API, reserve one quarter for guest/RSX memory, and retain the saturating one-module floor. Preserve the old calculation outside iOS. |
| Recent SPU fences and game-specific guards | [7abf45d](https://github.com/ARMSX2/ARMSX3/commit/7abf45dc6ea7d1d667daa130392294589de542eb) concerns memory-order correctness; several later commits target Killzone 3 or Android debugging. | Separate correctness/game investigations, not a generic performance port. |
| Vulkan compute synchronization and Android graphics controls | ARMSX3's Vulkan/Adreno presentation assumptions differ from iOS MoltenVK and the NeoStation Vulkan patch. | Require a matched GPU trace and image-correctness test before any adaptation. |

## Verification and interpretation

The new split policy has a host C++ boundary test at 65,536 and 65,537 instructions, including the preexisting fallback path and counts above 4 GiB. The iOS PPU budget has a separate test for low headroom, increasing headroom, the physical-memory cap, and integer saturation. The build script runs both after applying the canonical patch. `materialize_rpcs3_core.py` verifies the exact source commit, patch hash, postimage hashes, and exported ABI; the iOS syntax gate covers the changed `JITLLVM.cpp`, `PPUAnalyser.cpp`, and `PPUThread.cpp` with actual iOS compiler flags before building the Core. A successful Core build verifies compilation and packaging, **not** an increase in game FPS.

For device evaluation, compare the same game, scene, save, iPhone, temperature, and cold/warm cache condition against the current Core. Record boot-to-first-frame, PPU compile duration/function count, peak memory footprint, the logged module budget, JIT arena use, `COREPROF` frame times (including 1% low), crashes and savestate round trips. The PPU bound affects titles with very large unbounded regions; the LLVM change primarily targets pathological compile time; the memory budget may reduce parallel compilation to avoid an iOS termination. None of these changes alone establishes better steady-state FPS for God of War III or other typical games.

No IPA is claimed by this audit. Keep the Core artifact identified by the exact branch SHA, patch SHA-256, Core SHA-256, and CI run. Only integrate it into a NeoStation IPA after the Core CI passes and a device comparison supports the change.
