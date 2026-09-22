# Build 303 — minimal RPCS3 launch coordinator

## Audit conclusion

Build 289 is the last user-validated baseline in the current history. Builds 300–302
added a host VA reservation, passive-dlopen Core initialization and a new Dart
startup transaction. Build 302 is compilable but not device-validated for game
launch.

This Build 303 change deliberately does not add another recovery layer. It
removes host behavior that can interfere with an otherwise valid native boot:

- no Dart boot-progress watchdog;
- no Dart-triggered abort/stop on a long PPU/SPU preparation stage;
- no periodic JIT status polling while StikJIT owns the attach transaction;
- no Dart duplication of the native 448+576 MiB reservation proof;
- no automatic retry; only a later explicit user launch is allowed after a
  fully confirmed cleanup;
- LocalDevVPN remains external and read-only; route failure is surfaced as
  RPCS3_ROUTE_UNAVAILABLE.

## Retained native contract

The Build 302 RPCS3 Core is intentionally retained for this host-only correction.
The passive single-dlopen path, one host VA reservation, StikJIT nonce handoff,
explicit Core initialization, confirmed helper detach and LLVM execution test
remain unchanged. Reverting those native changes without device evidence would
replace one unverified theory with another.

The launch owner is now:

route -> reserve -> attach -> initialize -> complete -> verify -> boot

Each failed native step keeps its native code/message. Cleanup never starts a
second boot.

## Device boundary

A green CI run means only that Build 303 is safe to test. The launch is not
considered fixed until an iPhone run reaches game_boot_return / RUNNING.
