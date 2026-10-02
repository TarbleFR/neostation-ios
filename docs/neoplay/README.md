# NeoPlay — first integration candidate

Branch: `feature/neoplay`. Base: release 0.0.2 / `f4583c6a3083b8aed358da28b2f8f849256e0e8b`.
This is not Apple's AirPlay protocol. It is NeoStation's opt-in local streaming feature.
No changes to `experimental`, NeoSwap, JIT, emulator cores, saves or libraries are required.

## Windows

A complementary **free NeoPlay Receiver** is required. The first candidate runs with Node.js 22+ and Edge/Chrome, using their built-in H.264/AAC media pipeline, not unsigned third-party FFmpeg DLLs.
In `tools/neoplay-receiver`: `npm ci`, then `npm start`. Open the localhost address, click Ready, then select the PC in NeoStation / Tools / NeoPlay. Enter the six-digit code.
The receiver announces `_neoplay._tcp` over Bonjour/mDNS. No account, external signalling service, internet relay or router port forwarding is used. A narrowly scoped Windows **private-network** firewall permission for the receiver may be needed; do not disable security protections globally.

## Chromecast

The separately integrated Google Cast iOS SDK discovers video-capable Cast receivers and starts Google's default media receiver. No Windows PC and no extra app on a conventional Chromecast are required. The iPhone serves a token-scoped H.264/AAC fragmented-MP4 HLS stream from a bounded RAM ring.
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

The integration is **not finished** until the two routes have separate physical-device evidence.
- Windows: automated protocol, authentication, geometry and lifecycle tests; real iPhone game/audio playback still pending.
- Chromecast: real SDK compilation and native HLS/lifecycle contract tests; actual Chromecast playback, TV scaling and latency still pending.
- Required: 4:3/16:9/ultrawide/portrait; audio-video synchronization; connect/disconnect/reconnect during each embedded emulator; receiver disappearance; local-network denial; 30-minute thermal/pressure run; confirm game and saves remain intact.
- CI success is not physical-device success. No public release, stable-baseline promotion or merge is authorized by this implementation.

Primary API references: Apple ReplayKit `RPScreenRecorder.startCapture`, AVFoundation segmented `AVAssetWriter`; Google Cast iOS integration, supported media and iOS local-network permissions; W3C Media Source Extensions.
