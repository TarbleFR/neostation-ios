NeoPlay Desktop 0.8.0 - Windows installer

This Windows-only update is based on the proven NeoPlay 0.5.3 receiver
(commit 26a5f1fe). It does not change NeoStation iOS, ReplayKit, NeoSwap,
RPCS3, or the NeoPlay network and audio protocol.

INSTALLATION
Run NeoPlay-Setup-0.8.0.exe. Install location (per user):
%LOCALAPPDATA%\Programs\NeoPlay

The installer creates Start Menu and desktop shortcuts and registers an
Uninstall NeoPlay entry in Windows Settings. The receiver and Chromium player are included in NeoPlay itself.
Edge, Chrome, Node.js and a separate receiver are not required.
No PowerShell window is shown by NeoPlay itself.

LANGUAGES
Interface language is automatically selected from the Windows/Chrome locale,
with a manual selector: English, French, German, Spanish, Italian,
Portuguese, Russian, Indonesian, Japanese, Korean, Simplified Chinese
and Traditional Chinese. The NSIS installer provides the same twelve languages.

IMAGE QUALITY AND LOW LATENCY
NeoStation iOS keeps the captured source at its native resolution while the
local network and PC can sustain it. Persistent receiver delay or decoder
backlog now feeds the existing sender control: it steps down native -> 1080p
-> 720p, then recovers after 20 seconds without congestion. Isolated Wi-Fi
spikes, paused games and hidden windows do not request a quality reduction.
This feedback works with Build412's existing keyframe/tier control.

Native 4K60 is accepted when the source actually supplies a 3840x2160,
60 fps capture. An iPhone screen capture below 4K remains that source size;
upscaling on a 4K monitor is identified separately in the interface.
A separate Render resolution selector now offers Automatic, Native,
QHD 2560x1440 and UHD 3840x2160. These are GPU output targets, NOT a
new iPhone capture size or increased H.264 bandwidth. On a 2K display,
UHD rendering is supersampling followed by panel downsampling.
If the local rendering becomes too costly, output steps UHD -> QHD ->
Native and recovers after 20 seconds of stable video.
Original, Enhanced and Extra sharp remain live, per-user rendering options.
The GPU shader uses full precision for 4K; a 1080p source can fill a 4K
presentation surface while keeping its aspect ratio. Resolution and measured
presentation frame rate are shown separately from the received source size.

Current iPhone captures retain their proven low-latency software decoder.
A guaranteed no-reorder native 4K stream tries hardware decoding first, with
an automatic software fallback if hardware stalls or fails. WebGL failures
fall back to Canvas 2D. PCM timing and playback acknowledgment are unchanged.
The provided NeoStation iOS logo is used in the UI, app, installer and shortcuts.

The selected language and quality persist under:
%LOCALAPPDATA%\NeoPlay\Profile

Closing the application stops the local server and releases port 17642.
NeoPlay is single instance. Uninstallation removes installed binaries,
shortcuts, registry keys and the application profile.

BUILD
From tools/neoplay-receiver on Windows with Node 22 or newer:
  npm ci --ignore-scripts
  npm test
  node node_modules/electron/install.js
  npm run build:windows

Build the standard Windows installer with:
  npm run build:installer
The script downloads a pinned, hash-verified NSIS compiler when needed.

The installer and embedded Windows application are unsigned.
Physical iPhone playback is separate from the automated Windows validation.