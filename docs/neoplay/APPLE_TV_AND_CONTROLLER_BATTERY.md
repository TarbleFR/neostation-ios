# Apple TV and controller battery — NeoPlay companion integration

## Scope and isolation

This work lives only on `feature/neoplay`. The retained emulator cores, their bridges, JIT helpers and `lib/services` are not modified. `NeoPlayGameHUDHost` observes the existing `GameLaunchManager` from the application builder. It sends an optional UI-only message after an embedded game enters `playing`, and removes the HUD on close. A failed companion message cannot stop or block the game lifecycle.

## Apple TV: public native AirPlay path

NeoPlay now has an **Apple TV · AirPlay** entry with twelve-language instructions and system-observed status. The user chooses the actual Apple TV from iOS **Control Center → Screen Mirroring**. No additional receiver application is required on Apple TV. This entry is deliberately not presented as a discovered device, nor does it programmatically select a TV.

`NPAirPlayMonitor` reads `UIScreen.mirrored` and the audio route separately. AirPlay audio alone is labelled audio-only, not game-video playback. External mirroring does not establish the exact receiver model; generic capture/ReplayKit status is never used as evidence of Apple TV connection. No private settings links, audio-only route picker, external-display window takeover, display stretching, or audio-session setters are introduced.

If iOS reports an external mirror, NeoPlay refuses a second local encoder stream; if mirroring begins while a NeoPlay stream is active, it stops only its own capture and network session. System mirroring remains user-controlled. Control Center presentation may follow the emulator's existing pause/background behavior; uninterrupted frame delivery has not been demonstrated on hardware.

## Controller battery beside the game menu

The HUD is independent of streaming and works from the game lifecycle, not from opening NeoPlay. It displays a controller icon, the rounded level reported by GameController, a charging symbol when reported, and a low-battery visual indication. Missing, unknown, nonfinite and out-of-range battery levels remain unavailable (`—`), never fabricated as 0% or 100%. A genuinely reported empty discharging battery may display 0%.

Up to four connected standalone controllers are shown with numeric identifiers and accessible controller names. These identifiers identify the HUD's controllers, not emulator player ports. `isAttachedToDevice` is treated only as a form-fitting attachment flag, not proof of Bluetooth versus USB. A standalone wired controller can also appear; no transport type is invented.

The monitor reads battery state every 15 seconds while gameplay is foregrounded and refreshes on controller connection/disconnection. It does not replace controller input callbacks, start Bluetooth discovery, or change player assignments. No battery timer or view traversal runs in the library. The small anchor lookup is bounded and cached; labels are rebuilt only when their values, language or available width change.

Read-only adapters recognize the existing menus of **DolphiniOS, ARMSX2, RPCS3, DuskLight and KartPad**. The badge is attached to the menu's existing parent, using safe-area bounds and reserved control rectangles. It passes through touches, does not become a key window and disappears when the menu anchor is hidden or removed. If no safe placement exists, it is omitted rather than covering controls. Future upstream menu changes require updating the corresponding adapter.

## Tests and remaining acceptance

The independent workflow keeps Windows protocol/playback and native iOS/Chromecast encoding checks. New checks cover unknown battery values, charging and low states, multiple controller labels, safe-area placement and menu/control hit testing, all five menu adapters, repeated HUD attachment, app lifecycle messages without streaming, twelve translations and Traditional Chinese, and the distinction between AirPlay audio and external video mirroring. Native menu fixtures test the actual adapter code; they are not physical emulator gameplay sessions.

Physical acceptance is still required separately for iPhone → Windows, iPhone → Chromecast, iPhone → Apple TV, and actual controller battery reporting in each emulator. Also test connect/disconnect/reconnect, portrait/landscape changes, Control Center round trips, controller sleep/recharge, multiple controllers, and long gameplay sessions. The passive LAN probe is discovery only and cannot establish playback compatibility.

This change does not finish the earlier game-only viewport, adaptive bitrate, Chromecast latency optimization or full NeoStation IPA work. There is no claim of measured AirPlay latency or complete emulator regression coverage, and no public release is created.

## Primary API references

- Apple GameController battery: https://developer.apple.com/documentation/gamecontroller/gccontroller/battery
- Battery level and default value: https://developer.apple.com/documentation/gamecontroller/gcdevicebattery/batterylevel
- Attachment is not connection transport: https://developer.apple.com/documentation/gamecontroller/gccontroller/isattachedtodevice
- External-screen mirroring observation: https://developer.apple.com/documentation/uikit/uiscreen/mirrored
- Apple TV screen-mirroring user flow: https://support.apple.com/102661
