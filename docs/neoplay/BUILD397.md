# Build 397 — NeoSwap + NeoPlay private integration candidate

Owner-authorized integration into `experimental`, after the exact Build396 finishes successfully.
Preserved runtime baseline: `d3d5681cc8b10af1cd503ea72a4886c82faaa3ef`.
Imported NeoPlay candidate: `f4b65f09d5a71ad2e0c72ab347b3df285c98b0f7` (tested native implementation `9de76e5b662d7c915bff1485fe02dfc2b90c9961`).

## Included

NeoSwap and its storage-backed shader cache remain byte-identical to Build396. Outils retains NeoSwap at index 2 and adds NeoPlay at index 3. The current RPCS3, Dolphin, ARMSX2, DuskLight and KartPad cores and JIT helpers are not rebuilt or replaced by this integration.
NeoPlay adds a Windows receiver, a separate Google Cast path, an Apple TV system-mirroring guide, and controller battery information next to recognized native in-game menus. Battery display does not require streaming.
Apple TV selection remains in iOS Control Center → Screen Mirroring. An audio-only AirPlay connection is not reported as video mirroring. Windows requires the free Node.js-based NeoPlay Receiver from `tools/neoplay-receiver` plus Edge/Chrome.

## Build and evidence

Build397 uses a concurrency group separate from Build396 and checks run `37065639799` and its exact source/artifact before its own IPA packaging. Same-commit NeoSwap, storage, Dolphin/cheats and NeoPlay checks remain mandatory. The full host uses Xcode 26.3 for the Google Cast SDK, while the minimum NeoPlay deployment target remains iOS 18. The IPA validator requires the actual NeoPlay framework, its source identity, all twelve LAN permission translations, and dependency acknowledgements in the final payload.
No public release, tag update or main-branch promotion is part of this request.

## Device testing still required

This is a private test build, not verified end-to-end gameplay compatibility. Test iPhone → Windows, iPhone → Chromecast, iPhone → Apple TV and real controller battery reporting separately. Unknown battery levels remain unknown; the indicator does not claim to distinguish Bluetooth from USB when the API does not report the transport.
The current capture includes the application screen and its existing borders. Game-only capture, measured interactive latency, adaptive bitrate and complete emulator hardware regression coverage remain open. Chromecast HLS buffering may be unsuitable for fast games. Use the unencrypted prototype transport only on a trusted local network.
Keep JIT/NeoSwap helper extensions when signing or installing the IPA. Capture, stream or HUD failures must not be treated as permission to change game saves, firmware, pairing data or emulator settings.
