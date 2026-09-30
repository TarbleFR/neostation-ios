# Wii phone shake: input routing and test scope

The existing phone-shake path had two confirmed exclusions: a connected iOS gamepad stopped the sensor and hid its input source; the physical Wii Remote profile read the gamepad shoulder binding instead of the touchscreen buttons produced by the phone. CoreMotion delivery and the release timer also ran on the UI queue. A UI stall longer than the 100 ms sample freshness window discarded a live gesture before it reached the emulator.

Phone motion now has a dedicated serial worker. Sensor activation runs asynchronously so a native launch waiting for main cannot deadlock against route setup waiting for the emulator runtime queue. Lifecycle changes invalidate the requested generation immediately; stopped, backgrounded and superseded sessions cannot emit a late press. Gesture releases run independently of the UI run loop.

The existing donor menu API augments the first emulated Wii Remote's `Shake/X`, `Shake/Y` and `Shake/Z` bindings with qualified `iOS/4/Touchscreen:Button 132`, `133` and `134` branches. Parenthesized OR preserves the existing binding expression. Repeated activation and hotplug preparation do not add duplicate branches. Only these three bindings are changed. They are saved using Dolphin's existing profile machinery, and disabled phone motion leaves the branches inactive. A connected gamepad can retain all of its controls while the phone supplies shake input.

The complete snapshot/three-binding transaction runs on NeoStation's existing serial Dolphin runtime queue; the donor C ABI then follows its existing host/CPU/input-lock protocol. No UIKit operation runs on the motion worker. The core source pin and donor binary remain unchanged.

Input preparation also runs after Dolphin's actual controller-refresh result for a changed controller generation, even when the layout remains Nunchuk. This handles an early controller notification followed by the donor's effective profile update. Ordinary 500 ms polls in the legacy pacing mode do not re-qualify or truncate a shake pulse. Re-qualification does not restart the sensor or reset gesture cooldown/rearming.

Menus and backgrounding disable phone input. GameCube and Classic Controller layouts do not accept it. Sensor or route preparation failure prevents sensor input and appears as a translated diagnostic in the Controls menu; toggling the option off and on retries preparation. Help, privacy and failure messages exist in all twelve supported languages.

## Verification

- `test/dolphin_phone_shake_test.py` compiles and executes the production Swift owner/policy with mocked CoreMotion. It covers all input gates, gamepad-hidden overlay, worker delivery/release during a deliberately blocked main thread, preparation cancellation, old callback generations, shutdown and error recovery. It requires `swiftc`.
- `test/dolphin_phone_shake_routing_test.py` executes the production C++ augmentation policy on portable hosts. On macOS it also compiles and executes the production Objective-C++ routing shim with controlled JSON donor C ABI responses: touch, physical/custom/cleared bindings, reconnect, idempotence, Classic, invalid snapshot, partial failure and retry. The macOS portion requires Foundation and is explicitly skipped on Linux.
- `test/dolphin_motion_localizations_test.py` checks every message in all twelve catalogs, the generated native header, Traditional Chinese handling and repeatable privacy-string staging.
- The motion workflow separately type-checks production touch controls against the iOS SDK.

Portable binding and localization checks have passed locally. Linux has neither Swift nor macOS Foundation, so production Swift execution, Objective-C++ execution and iOS type-checking must pass the candidate's macOS CI before IPA delivery. These tests establish host behavior, not physical sensor acceptance by Mario Kart Wii or Donkey Kong Country Returns. Those actions still require an iPhone test, both with touch controls and with a gamepad connected. Dolphin's donor save API reports runtime mapping success without exposing a disk-save result; successful persistent configuration after app restart remains part of device validation.
