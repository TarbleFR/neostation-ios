# NeoPlay — first integration candidate

Branch: `feature/neoplay`. Base: release 0.0.2 / `f4583c6a3083b8aed358da28b2f8f849256e0e8b`.
This is not Apple's AirPlay protocol. It is NeoStation's opt-in local streaming feature.
No changes to `experimental`, NeoSwap, JIT, emulator cores, saves or libraries are required.

## Windows

A complementary **free NeoPlay Receiver** is required. The first candidate runs with Node.js 22+ and Edge/Chrome, using their built-in H.264/AAC media pipeline, not unsigned third-party FFmpeg DLLs.
In `tools/neoplay-receiver`: `npm ci`, then `npm start`. Open the localhost address, click Ready, then tap the **AirPlay icon in NeoStation’s main menu**, select the PC in the NeoPlay panel and enter the six-digit code.
The receiver announces `_neoplay._tcp` over Bonjour/mDNS. No account, external signalling service, internet relay or router port forwarding is used. A narrowly scoped Windows **private-network** firewall permission for the receiver may be needed; do not disable security protections globally.

## Chromecast

Tap the **AirPlay icon in the main menu** to open NeoPlay, then **Find screens**, allow iOS local-network access, and select the Chromecast before launching a game. The previous NeoPlay activation entry in **Settings → Tools** has been removed; the AirPlay action opens the same panel with Apple TV guidance, Chromecast and Windows receiver selection. Opening the panel or starting a game does not automatically search for a TV or start capture. The iPhone and Chromecast must be on the same local Wi-Fi network; guest/client isolation may prevent discovery. If access was denied, enable NeoStation's **Local Network** permission in iOS Settings, return to NeoPlay, and search again. A conventional Chromecast uses the Google default media receiver and does not need the Windows receiver application.

The discovery panel now retains a **Search again** action after the initial request and retries an explicitly requested search after a Settings/foreground round trip. Native diagnostics in `NeoPlay.jsonl` record Cast discovery requests, SDK-active state and total/eligible device counts; Bonjour errors and Cast-session errors retain their actual domain and code. These records distinguish a search request, a discovered video receiver and successful playback; an empty device list alone is not labelled permission denial. Real iPhone-to-Chromecast discovery/playback remains unvalidated.

Google's [iOS permissions and discovery guide](https://developers.google.com/cast/docs/ios_sender/permissions_and_discovery) requires an explicit `startDiscovery` call for a custom picker, the `_googlecast._tcp` and receiver-ID Bonjour declarations, and local-network permission. These requirements were already present in the delivered Build399 IPA. Google's [local-network help](https://support.google.com/chromecast/answer/10063094) describes enabling an application's permission under **iOS Settings → Privacy & Security → Local Network**; its [discovery troubleshooting guide](https://developers.google.com/cast/docs/discovery) covers same-network and client-isolation checks. The supplied RPCS3/NeoSwap logs do not contain the separate `NeoPlay.jsonl` discovery record, so they cannot establish which network or permission condition caused the user's empty list.

The separately integrated Google Cast iOS SDK discovers video-capable Cast receivers and starts Google's default media receiver. No Windows PC and no extra app on a conventional Chromecast are required. The iPhone serves a token-scoped H.264/AAC fragmented-MP4 HLS stream from a bounded RAM ring with a fixed HLS target duration and separately retained recent payloads.
The media stays on the LAN, but Google's receiver/SDK initialization may need internet access. This is not a promise of fully offline Google Cast.
The default receiver does not expose the attached television's EDID or pixel dimensions to the sender. The compatibility profile is capped at 720p/60; the receiver scales to the destination with aspect preservation. Exact TV-resolution feedback and adaptive bitrate are **not implemented in this first candidate**.
The HLS path has a higher buffering delay than the Windows path. No claim of competitive-gaming latency is made. A future native Google TV receiver can use a lower-latency transport; that is not the same as a classic Chromecast.

## Capture and performance boundaries

ReplayKit captures the NeoStation application screen (including its menus), and app audio, **never microphone audio**. The user explicitly opens discovery, selects a receiver, and authorizes capture. Nothing is captured or encoded at app startup.
AVAssetWriter multiplexes H.264 and AAC using one source timestamp domain. Windows uses short fMP4 fragments over a bounded WebSocket; Chromecast uses an independently served HLS playlist. The first fragment targets are 250 ms (Windows) and 1 s (Cast), not measured end-to-end latencies.
Encoding dimensions fit inside the destination and codec budget without stretching; receiver display uses `object-fit: contain`. Native orientation changes create a new initialization segment; HLS marks discontinuities. Queues and encoded media retention are bounded. Congestion stops only NeoPlay rather than growing RAM without a bound.
The visible NeoPlay × overlay disconnects without becoming the key window. Network/capture errors and late callbacks cannot call emulator stop/reset APIs. Existing AVAudioSession configuration is not changed.
Transport data in this prototype is **not encrypted**. Pairing and per-session random URL capabilities restrict accidental access, but they do not protect against an observer on an untrusted Wi-Fi. Use only a trusted private LAN.

## Validation status

The integration is **not finished** until Windows, Chromecast and Apple TV have separate physical-device evidence, and controller battery behavior is checked during actual gameplay.
- Windows: automated protocol, authentication, geometry and lifecycle tests; real iPhone game/audio playback still pending.
- Chromecast: real SDK compilation and native HLS/lifecycle contract tests; actual Chromecast playback, TV scaling and latency still pending.
- Required: 4:3/16:9/ultrawide/portrait; audio-video synchronization; connect/disconnect/reconnect during each embedded emulator; receiver disappearance; local-network denial; 30-minute thermal/pressure run; confirm game and saves remain intact.
- CI success is not physical-device success. No public release, stable-baseline promotion or merge is authorized by this implementation.

Primary API references: Apple ReplayKit `RPScreenRecorder.startCapture`, AVFoundation segmented `AVAssetWriter`; Google Cast iOS integration, supported media and iOS local-network permissions; W3C Media Source Extensions.

## First-candidate boundaries and diagnostics

The current image source is the **application screen**, not an emulator's isolated framebuffer. Consequently, letterboxing already rendered on the phone is preserved inside the shared picture. Removing that extra border without cropping the game requires an explicit game-viewport/render integration; it is not yet implemented. Do not advertise perfect game-only screen filling from these tests.

The NeoPlay panel opened from the main menu’s AirPlay icon can connect before launching a game. Apple TV screen selection remains managed by iOS Control Center. The native pass-through overlay disconnects a running stream. Opening a first receiver-selection UI from every already-running embedded emulator is a separate integration task and has not been validated.

Windows viewport changes are reported back to iOS and debounced before restarting only the encoder when its output dimensions must change. This is not an emulator restart. There is no HEVC mode or network-adaptive bitrate controller in this candidate.

`Documents/NeoPlay.jsonl` records connection/stop events, encoder dimensions and underlying error domains/codes on a utility queue. It rotates at 512 KiB to `NeoPlay.jsonl.previous`. Pairing codes, receiver addresses, URL capabilities and game paths are not logged.

For Chromecast HLS, the advertised window contains up to six one-second segments while the encoded ring retains up to 24 segments / 24 MiB, including recently unlisted payloads. Target duration stays fixed; unusually long fragments are rejected rather than silently changing the stream contract. This does not establish a real TV playback or latency result.

A private manual IPA workflow is configured only on this branch. The isolated native harness compiles the native capture/Cast implementation, but it is **not a complete NeoStation IPA build**. Device acceptance additionally requires the full host/plugin build and manual tests on iPhone plus each destination.

External emulator applications are outside the scope of this app-screen capture. Moving NeoStation to the background ends its NeoPlay stream; it does not capture another application's screen.

Before any public binary distribution, review the Google Cast SDK terms, required notices and compatibility with the project's distribution obligations. Only the SDK dependency declaration is committed here; there is no public NeoPlay binary release or completed license review.

## Recorded software verification — 2026-10-02

`validation-2026-10-02.json` binds the tested code commit, GitHub Actions run, generated media hashes and local Windows measurements. All four jobs passed: frontend, native iOS simulator, Windows protocol and Windows playback. The same production-encoder fixture was also decoded successfully in Edge on the owner's Windows PC, with nonzero audio samples, video frames, aspect containment, playback acknowledgement and disconnection checks. Local Windows mDNS publication/discovery passed separately.

These are **software and simulator results**, not an iPhone-to-TV acceptance result. The passive Chromecast probe found no receiver visible from the PC at that time. Physical iPhone/Windows Wi-Fi gameplay, actual Chromecast playback, game-only viewport integration, full IPA compilation, sustained thermal/memory testing and measured interactive latency remain open.

## Apple TV and independent controller battery HUD

See `APPLE_TV_AND_CONTROLLER_BATTERY.md` for the native iOS screen-mirroring path, explicit audio/video status distinctions, and the independent GameController battery overlay beside existing native game menus. The iOS system, not an audio route picker or a private API, selects the Apple TV.

`companion-validation-2026-10-02.json` records the dedicated companion checks and their exact source commit separately from the initial prototype report. Physical Apple TV/Chromecast playback and controller readings remain unvalidated; no full IPA or stable release is claimed.
