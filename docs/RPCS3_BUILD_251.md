# NeoStation iOS Build 251

Build 251 validates the embedded RPCS3 workflow before packaging the IPA.

- RPCS3 in-game menu exposes per-title resolution-scale presets: 75%, 100%, 125%, 150%, 175%, 200%, 250%, and 300%.
- The selected scale is written through the RPCS3 iOS per-game setting API and the active title is restarted cleanly.
- ISO imports retain the full ISO9660 extent-integrity validation introduced for Build 249/250.
- A truncated or corrupt ISO is rejected and NeoStation releases the old document scope before opening a fresh import picker for a complete image.
- Cancelling the replacement picker reports the rejected ISO without adding a partial game to the library.

The CI contract tests assert both the upscale path and the truncated-ISO re-import path before compiling the IPA.
