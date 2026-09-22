# Build 303 — minimal RPCS3 launch coordinator

## Audit conclusion

Build 289 remains the last user-validated baseline in the compared history. Builds
300–302 added a fixed host VA reservation, passive-dlopen Core initialization
and a new Dart startup transaction. Build 302 compiled, but did not launch a
game on the user's iPhone.

The audit found two distinct changes that must not be conflated:

- Build 301's passive single-dlopen path removes JIT work from dyld load and is
  retained.
- Build 295/302's fixed 448+576 MiB host reservation is not required by the
  earlier Build 266 adaptive allocator and is removed from Build 303.

## Removed host layers

Build 303 deliberately removes behavior that can interfere with a valid native
boot:

- no Dart boot-progress watchdog;
- no Dart-triggered abort/stop on a long PPU/SPU preparation stage;
- no periodic JIT status polling while StikJIT owns the attach transaction;
- no host reserveAddressSpace MethodChannel call;
- no Rpcs3ArenaReservation/Rpcs3ArenaLayout host layer;
- no adopt_jit_layout/reset_failed_startup private Core ABI;
- no automatic retry; a later retry is always user initiated;
- LocalDevVPN remains external and read-only; route failure is surfaced as
  RPCS3_ROUTE_UNAVAILABLE.

## Recovery Core contract

The Build 303 recovery Core is intentionally:

Build 266 adaptive/Core-owned JIT allocator
+ Build 301 passive dlopen
+ one minimal Build 303 lifecycle change allowing initialize after a clean
  shutdown reaches STOPPED.

Build 295/302 fixed-reservation markers and the private adoption/reset symbols
are forbidden. A failed Core initialize is cleaned with the public ABI
rpcs3_ios_shutdown(); only a confirmed clean shutdown permits a later explicit
user retry.

## Deterministic launch

route -> attach StikJIT -> load Core -> initialize Core -> complete/detach
-> execute LLVM JIT self-test -> boot game

Each failed native step keeps its native code/message. Cleanup never starts a
second boot. Route failure touches neither StikJIT nor the Core.

## Device boundary

A green CI run means only that Build 303 is safe to test. The launch is not
considered fixed until an iPhone run reaches game_boot_return / RUNNING.
