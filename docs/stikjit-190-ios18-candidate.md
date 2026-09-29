# Build 363: StikJIT 1.9.0 / pre-iOS-26 PS2 and PS3 candidate

## Scope and evidence

User reports RPCS3 JIT preparation hanging on iOS 18, and a similar ARMSX2
BIOS report. No tester device log or exact device model is available yet.
A stale pairing file is not established as the cause. Importing a PS2 BIOS
only copies files; booting that BIOS is the operation that requests JIT.

The host requests a Core handshake only on iOS >=26. Upstream StikJIT can
instead select Universal whenever TXM is detected. On a pre-26 path that
combination can leave the host waiting for helper completion while the script
waits for Core BRKs. The candidate removes that mismatch for the two opted-in
legacy helpers. This is a concrete source defect, not a reproduced device fix.

## Changes

- Source-build StikJIT 1.9.0 at 32287268fa5824f9edce4cb359f5833ce0cf7b00.
- Keep the NeoStation full-width address and batch-error transport patch.
- Add an opt-in classic attach/detach policy for PS2/PS3 on iOS <26 only.
  Validate attach stop replies and require an acknowledged detach. The host
  still verifies CS_DEBUGGED before loading its Core.
- Set idevice's process-local asynchronous-operation timeout to 20 seconds
  only for the opted-in legacy helper. This is not a 20-second deadline for
  downloading an entire DDI, nor proof that every internal FFI wait is bounded.
- Parse actual XML/binary pairing plists in the helper and validate key types
  and lengths. Structural validity is not device-authentication success.
- Preserve dynamic idevice exports needed by the existing MeloNX bridge;
  upstream's new hidden/dead-stripped link recipe would remove these symbols.
- Include the last native stage in timeout errors. Export bounded legacy
  ARMSX2 JIT diagnostics to Documents/armsx2_jit_debug.log, and preserve returned
  helper details in Documents/armsx2_internal_debug.txt.

## Non-regression boundaries

The modern script dispatch, custom nonce scripts, debugger/Core handoff,
Core allocators, CPU/GPU emulation and native Core binaries are unchanged.
Dolphin does not opt into the new classic policy. Shared DDI handling does
change with StikJIT 1.9: upstream selects personalized before iOS 26.4 and
Cryptex thereafter. Real-device testing is still required for that update.
No new VPN management, automatic Core retry, forced cache deletion or broad
coordinator refactor is introduced. Main remains unchanged; no release.

## Executed validation

Native workflow 36580127867, host 489b6a1a4f8a6761fe0f548a891971f727e7dd73:

- 48 executed production-Swift policy and RSP-response cases covering
  OS major 18/26/27, TXM present/absent/unknown, opt-in/default/force and errors.
- Four full-width transport checks, existing nonce handshake and reporter
  ordering tests, five external-LocalDevVPN contract tests.
- Xcode 16.4 arm64 framework archive succeeded; all 18 dynamic FFI exports
  and required patch markers were verified in the produced framework.
- Framework SHA-256:
  9694393afdad28b63104330764b748ff37a64a03da2f13314a7aee7e97d0e590

The historical rpcs3_stop_reply_behavior_test.js stress test already fails on
reordered/sparse stop replies and some error cases on baseline beed82b.
The candidate keeps its script and test identical and verifies identical
baseline/candidate outcomes. modern-baseline.json records the failure;
this is NOT a passing stress-suite or an on-device JIT validation.

Packaging refuses an untested framework, rewritten version metadata, lost
FFI exports, missing helper markers, changed custom scripts or a deployment
minimum above iOS 18. Full IPA validation is a separate build step.

## Device acceptance required

First test the same device/pairing/LocalDevVPN setup, changing only the IPA.
On iOS 18: cold-start NeoStation, import PS3UPDAT.PUP, then separately import
and boot a PS2 BIOS; export diagnostics after any failure. Record the exact
iOS version, device model, sideloader, build number and last visible stage.
On the user's iOS 27 beta: cold-start, launch PS3 and PS2, then Dolphin and
repeat after returning to the library. Do not mark either device as fixed
until its actual launch/installation completes. No game files or pairing keys
should be attached to public diagnostics.
