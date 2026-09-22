# RPCS3 Build 304 — single proven launch path

Build 304 removes the post-Build289 startup layers and reuses the exact
device-proven Build266 RPCS3 Core.

## Runtime path

LocalDevVPN route check
-> pairing file
-> one StikJIT attach
-> one Core dlopen
-> one rpcs3_ios_initialize
-> one helper completion/detach
-> ready
-> LLVM self-test on first game boot
-> rpcs3_ios_boot_game

## Removed from the active launch path

- Rpcs3StartupTransaction
- automatic retry/fallback
- abortStartup recovery state machine
- separate verifyJitExecution transaction
- host fixed virtual-address reservation
- Build301 passive-dlopen Core overlay
- Build302 fixed reservation
- Build303 restartable lifecycle
- runtime Core shutdown/reinitialize
- boot watchdog
- incomplete-boot polling/marker
- automatic PPU-cache cleanup
- launch-time GameDB profile mutation

A normal game exit stops emulation only. The Core remains initialized for the
lifetime of NeoStation and is reused by the next game.

## Proven Core

SHA-256:
dba1bb3bf8847faf3e378c1815ffe895521d8d6404e468bb6a2eee5fa8cb4ddd

This is the exact Build266 Core already carried by the validated Build270 donor
and the Build289-era launch stack.

## Validation boundary

The Build304 preflight must be fully green before any full IPA build. A green
IPA remains a device-test candidate until the user confirms real iPhone launch.
