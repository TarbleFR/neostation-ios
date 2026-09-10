# Embedded RPCS3 Core provenance

NeoStation builds only the `RPCS3Core` shared library from pinned source using
`build-utils/build_rpcs3_embedded_core.sh`. No RPCS3 application IPA, SwiftUI
frontend, external bundle identifier or external app launcher is used.

Source: https://github.com/XITRIX/rpcs3
Commit: `22f1152783cef1f7e04af7b1c895173e28fd5b03` (iOS ABI 30).
The iOS platform adapters are required to run the library inside NeoStation.
The build keeps LLVM/AArch64 and applies `patch_rpcs3_embedded_boot.py`.

The upstream temporary LLVM allocation ownership is retained. The Build 233
no-release patch was removed because `reset_runtime()` releases only the low
runtime allocations, leaving pinned high allocations leaked across sessions.

Firmware, games and saves are not included or deleted by this build.
