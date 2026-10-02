# NeoPlay Receiver for Windows — 0.1.0 preview

A standalone Windows window for the NeoPlay v1 sender integrated in NeoStation iOS build 397. This is **not** an AirPlay/Google Cast receiver and does not run the emulator on the PC.

## Use

Double-click **NeoPlay Receiver.exe**. Keep the iPhone and PC on the same trusted local network. Select this PC in **NeoStation → Tools → NeoPlay** and enter the six-digit code displayed in the window. Connect the game controller to the iPhone. F11 toggles fullscreen; Escape restores the window. Volume/mute and Disconnect affect only the PC receiver/stream, not the emulator.

The preview UI is in French. A self-contained .NET runtime and all application assets are bundled in the executable; Node.js, npm, a separately installed .NET runtime and a manual browser launch are not needed. It uses Microsoft's **Evergreen WebView2 Runtime** for the window's H.264/AAC playback. This shared Microsoft component must be present; if absent, the app offers to open Microsoft's official installation page. No FFmpeg DLL is shipped.

Windows may ask for network access: allow this application on **private networks only**. Never turn off Smart App Control or antivirus globally to run this preview. This is an **unsigned development executable**, not a reputation-established signed release. A different machine or an internet-downloaded copy may receive a security warning even when the locally built copy runs.

The receiver uses a random TCP port announced by `_neoplay._tcp.local` DNS-SD. IPv4 private/link-local senders are accepted; the UI is loopback-only with a random capability, and native senders must enter the expiring PIN. Grants are bound to the requesting IP and expire after 30 seconds; five pairing attempts per IP per minute are allowed. Only one sender/viewer session is accepted. Media queues are capped at 8 MiB, a message at 4 MiB, and slow peers are disconnected. The payload is **not encrypted**; pairing is not protection against observation on an untrusted Wi-Fi. No router port forwarding, account or cloud relay is used.

Close the window to stop receiving. There is no autostart entry, installed background service, firewall mutation or automatic network takeover. Network discovery binds the interfaces present at startup; relaunch after changing Wi-Fi/network adapter. An IPv6-only LAN is not supported by this first desktop build.

## Build and checks

Use .NET SDK **10.0.401** and run `dotnet publish NeoPlayReceiver.csproj -c Release -o publish`. NuGet dependencies are locked. The executable is Windows x64; ARM64 needs a separate native build or Windows x64 emulation (not tested here).

`node Tests/native-protocol.mjs "publish/NeoPlay Receiver.exe"` checks the compiled receiver's pairing, media relay, resize notifications, playback acknowledgement, disconnect and real local mDNS advertisement using the independent Bonjour implementation from the parent project. Test processes are loopback-only except the explicit DNS-SD test and are terminated afterward.

`"NeoPlay Receiver.exe" --self-test <windows.json> <output-directory>` opens the actual WinForms/WebView2 window, feeds a pinned fixture made by the **production iOS NPMuxer**, checks decoded video and nonzero decoded audio without playing sound aloud, tests fullscreen and writes screenshots plus JSON evidence. It does not prove iPhone Wi-Fi gameplay, physical controller input or end-to-end latency. Test flags are not used during normal launch.

Logs and the isolated WebView2 profile are stored under `%LOCALAPPDATA%\NeoPlay Receiver`. Log rotation is capped at 512 KiB per log. Request URLs, PINs and authentication tokens are not written to normal receiver logs. Diagnostics/test output is not sent anywhere.

Source: https://github.com/TarbleFR/neostation-ios/tree/feature/neoplay/tools/neoplay-receiver/windows
The project license is inherited from the repository. Microsoft WebView2 and .NET license/notice texts are embedded in the application and accessible from its help panel. The application icon is converted from the existing repository icon. No public GitHub Release is created by the build workflow.
