# RPCS3 firmware import — build 229

Base: `fix/rpcs3-regular-arena-dolphin-multidelete-build227`, commit
`33e9c4e`. The latest successful IPA on that branch was build 228.

## Findings

The existing workflow builds with `CODE_SIGNING_ALLOWED=NO` and zips the
application without signing its executable. `Runner.entitlements` is only
copied beside the IPA. Consequently, a sideload signer reading capabilities
from Runner cannot discover the RPCS3 memory entitlements there.

The original RPCS3 v0.8.1 executable embeds `get-task-allow`,
`extended-virtual-addressing`, `increased-memory-limit` and
`increased-debugging-memory-limit`. This was checked directly in the verified
release IPA (SHA-256 `cd6910cb27e41a24cad224e04254f885aa90be176013569d05fb169c322f4522`).

The iOS Core reserves its emulated memory in static constructors, during
`dlopen`, before `rpcs3_ios_initialize` can report a recoverable error. The
one-page executable-memory check did not validate this virtual address space.
Upstream references: `XITRIX/rpcs3` `ios-port` commit
`22f1152783cef1f7e04af7b1c895173e28fd5b03`, `rpcs3/Emu/Memory/vm.cpp`,
`VMLayoutPolicy.h`, `rpcs3/util/vm_native.cpp`, and `rpcs3/ios/RPCS3IOS.h`.

This is a verified packaging defect and a plausible cause of the reported
firmware-time crash. No device crash report was supplied, so the exact failing
instruction on the user's phone is not established.

## Changes

- Embed the existing host entitlements in an ad-hoc Runner signature before
  packaging. The user's sideload signer must still provision and re-sign the
  IPA. No Apple signing identity is used in CI.
- Inspect the actual Runner signature inside the final IPA, in addition to
  checking the sidecar. Missing embedded capabilities fail the build.
- Before starting JIT, probe and release the Core's 8 + 12 + 4 GiB virtual
  reservations. Never use `MAP_FIXED` or touch their pages. A bounded failure
  returns an actionable error instead of entering the fatal constructor path.
- Persist native initialization/import milestones in
  `Documents/RPCS3-diagnostic.log`, including the stages before/after `dlopen`.
- Keep standard JIT mode consistent between Dart and the native bridge. The
  previous bridge ignored its argument, while the native boot guard refused
  the standard mode. Remove that guard, avoid a main-queue self-deadlock when
  presenting the game, and use the ABI's refresh-rate field for the surface.

No Dolphin engine, library or UI files are changed.

## Validation and remaining device check

Portable tests run the production memory preflight with real virtual mappings,
denied allocations, partial failures and relocated mappings. All reservations
must be released. Entitlement tests reject an unsigned executable even when
its sidecar is valid; macOS tests also compile and sign a real executable and
compare the embedded capabilities with Apple's `codesign` output. Dart tests
exercise standard/expanded mode transmission over the real MethodChannel API.

CI additionally runs the Flutter suite, the production helper handshake test,
the Xcode build and final IPA structural/entitlement validation.

On a signed iOS device: import an official PS3 PUP, confirm the installed
firmware version, then test a game. If a native crash remains, the last native
milestone and the iOS `.ips` crash report are needed to identify it. Neither
the simulator nor CI establishes real-device JIT or firmware success.
